#!/usr/bin/env bash
# Rehearses the kernel v2 signing steps (kernel v2, USD₮0 quote: contracts/core-v2) on a local anvil fork of X Layer,
# from the real deployer address (impersonated: no key is used, nothing reaches the real chain).
#
#   ALLOWANCE_PAYEE=0x... deploy/rehearse-v2.sh                      fork at the latest block
#   ALLOWANCE_PAYEE=0x... FORK_BLOCK=72540000 deploy/rehearse-v2.sh  fork at a given block
#
# Steps, in the order the wallet holder signs them (deploy/launch-kernel-v2.sh):
#   1. DeployCoreV2  contracts/core-v2  KernelFactoryV2 (+ KernelV2 implementation), LensV2               2 transactions
#   2. LaunchChipV2  contracts/core-v2  the Flow Governor (chips/out/fg.hex) taped out through the live Fab as a NEW
#                                       chip, its v2 kernel created with the reference USD₮0 envelope, the chip
#                                       handed to the kernel, Lens preflight                                3 transactions
#
# Kernel v2 reuses the live processor, Fab and SealedVM of kernel v1, so deployments/xlayer.json must record
# `issuance` and `evaluator`. A step whose contracts deployments/xlayer.json records (.coreV2, .flagshipV2) and that
# exist on the fork is not rehearsed: the recorded addresses are used instead.
#
# ALLOWANCE_PAYEE receives the kernel's allowance in USD₮0 and is part of the kernel's envelope (and so of its
# address). It is required while step 2 is still to be rehearsed. LaunchChipV2 refuses the KeeperTank: it cannot
# move an ERC-20.
#
# Everything runs in a scratch copy of the contracts, so no broadcast record of a rehearsal can land in the
# repository. The one file written in the repository is deploy/rehearsal-v2.json (or the file REHEARSAL_OUT names).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOYER=0x84cE7bAe1b788C7aD985D57721cA428b401aE34D
UPSTREAM="${XLAYER_RPC_URL:-https://rpc.xlayer.tech}"
# A free port by default: a port another fork already holds would make this script drive that fork instead.
PORT="${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
RPC="http://127.0.0.1:$PORT"
OUT="${REHEARSAL_OUT:-$ROOT/deploy/rehearsal-v2.json}"
LIVE="$ROOT/deployments/xlayer.json"
COMMIT="${COMMIT:-$(git -C "$ROOT" rev-parse HEAD)}"

die() {
  echo "rehearse-v2.sh: $*" >&2
  exit 1
}
[ -f "$LIVE" ] || die "$LIVE is missing"
recorded() { jq -r "$1 // empty" "$LIVE"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/covenant-rehearsal-v2.XXXXXX")
ANVIL=
cleanup() {
  [ -z "$ANVIL" ] || kill "$ANVIL" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# The scratch copy: kernel v2's Foundry project with its build cache (no broadcast records), the kernel v1 sources,
# libraries and test doubles it compiles through its remappings, the evaluator and the vendored TapeOut sources the
# test trees compile, and the chip files the scripts read.
mkdir -p "$WORK/contracts" "$WORK/chips"
for p in core-v2 core evaluator vendor; do
  rsync -a --exclude 'broadcast/' "$ROOT/contracts/$p" "$WORK/contracts/"
done
for d in out golden; do
  rsync -a "$ROOT/chips/$d" "$WORK/chips/"
done

fork_args=(--fork-url "$UPSTREAM" --port "$PORT" --auto-impersonate --silent)
[ -z "${FORK_BLOCK:-}" ] || fork_args+=(--fork-block-number "$FORK_BLOCK")
anvil "${fork_args[@]}" &
ANVIL=$!
for _ in $(seq 1 60); do
  kill -0 "$ANVIL" 2>/dev/null || die "anvil exited (is port $PORT taken?)"
  cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
  sleep 1
done
[ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" = "196" ] || die "the fork did not start"
kill -0 "$ANVIL" 2>/dev/null || die "anvil exited; something else answers on port $PORT"
BLOCK=$(cast block-number --rpc-url "$RPC")
echo "fork of X Layer at block $BLOCK; deployer nonce $(cast nonce $DEPLOYER --rpc-url "$RPC"), balance $(cast balance $DEPLOYER --rpc-url "$RPC" --ether) OKB"

# Contracts a script created, from its last broadcast record: "name address" per line.
created() {
  python3 - "$1" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d["transactions"]:
    if t.get("transactionType") == "CREATE" and t.get("contractAddress"):
        print(t.get("contractName") or "?", t["contractAddress"])
EOF
}
run() { # script-args...
  (cd "$WORK/contracts/core-v2" && forge script "$@" --rpc-url "$RPC" --sender "$DEPLOYER" --unlocked --broadcast --slow)
}
latest() { echo "$WORK/contracts/core-v2/broadcast/$1/196/run-latest.json"; }
has_code() { [ -n "$1" ] && [ "$(cast code "$1" --rpc-url "$RPC")" != "0x" ]; }
nonce() { cast nonce $DEPLOYER --rpc-url "$RPC"; }

# ---- what kernel v2 builds on: the live processor, Fab and SealedVM of kernel v1
CIRCUITS=$(recorded .issuance.circuits)
TRANSISTORS=$(recorded .issuance.transistors)
TANK=$(recorded .issuance.keeperTank)
REGISTRY=$(recorded .issuance.teamRegistry)
SEALED_VM=$(recorded .evaluator.sealedVM)
FAB=$(recorded .evaluator.fab)
FG_MANIFEST=$(recorded .flagship.manifestHash)
for pair in "circuits $CIRCUITS" "transistors $TRANSISTORS" "keeperTank $TANK" "teamRegistry $REGISTRY" "sealedVM $SEALED_VM" "fab $FAB"; do
  read -r name a <<<"$pair"
  has_code "$a" || die "deployments/xlayer.json records no live $name; kernel v2 needs kernel v1's processor, Fab and SealedVM"
done
[ "$(cast call "$FAB" "CIRCUITS()(address)" --rpc-url "$RPC" | tr '[:upper:]' '[:lower:]')" = "$(tr '[:upper:]' '[:lower:]' <<<"$CIRCUITS")" ] \
  || die "the recorded Fab is not for the recorded processor"
MANIFEST_HASH=0x$(shasum -a 256 "$WORK/chips/out/fg.pins.json" | awk '{print $1}')
[ "$MANIFEST_HASH" = "$FG_MANIFEST" ] || die "chips/out/fg.pins.json ($MANIFEST_HASH) is not the Flow Governor manifest of deployments/xlayer.json ($FG_MANIFEST)"

REHEARSED=()
NONCES=()

echo "== 1. DeployCoreV2"
FACTORY_V2=$(recorded .coreV2.kernelFactory)
LENS_V2=$(recorded .coreV2.lens)
if has_code "$FACTORY_V2" && has_code "$LENS_V2"; then
  echo "   on chain already (deployments/xlayer.json)"
else
  NONCES+=("coreV2=$(nonce)")
  COVENANT_CIRCUITS=$CIRCUITS COVENANT_FAB=$FAB COVENANT_SEALED_VM=$SEALED_VM run script/DeployCoreV2.s.sol -s "run()"
  FACTORY_V2=$(created "$(latest DeployCoreV2.s.sol)" | awk '$1=="KernelFactoryV2"{print $2}')
  LENS_V2=$(created "$(latest DeployCoreV2.s.sol)" | awk '$1=="LensV2"{print $2}')
  REHEARSED+=(coreV2)
fi
KERNEL_IMPL_V2=$(cast call "$FACTORY_V2" "kernelImpl()(address)" --rpc-url "$RPC")
QUOTE=$(cast call "$FACTORY_V2" "quote()(address)" --rpc-url "$RPC")
QUOTE_SHIFT=$(cast call "$FACTORY_V2" "quoteShift()(uint256)" --rpc-url "$RPC")
echo "   KernelFactoryV2 $FACTORY_V2 (KernelV2 implementation $KERNEL_IMPL_V2) LensV2 $LENS_V2; quote $QUOTE, shift $QUOTE_SHIFT bits"

echo "== 2. LaunchChipV2"
KERNEL_V2=$(recorded .flagshipV2.kernel)
CHIP_ID_V2=$(recorded .flagshipV2.chipId)
PAYEE=$(recorded .flagshipV2.allowancePayee)
if has_code "$KERNEL_V2"; then
  echo "   on chain already (deployments/xlayer.json)"
else
  PAYEE=${ALLOWANCE_PAYEE:-}
  [ -n "$PAYEE" ] || die "ALLOWANCE_PAYEE is required: the wallet that receives the kernel's allowance in USD₮0 (not the KeeperTank)"
  NONCES+=("flagshipV2=$(nonce)")
  COVENANT_FAB=$FAB COVENANT_FACTORY_V2=$FACTORY_V2 COVENANT_LENS_V2=$LENS_V2 ALLOWANCE_PAYEE=$PAYEE \
    MANIFEST_HASH=$MANIFEST_HASH run script/LaunchChipV2.s.sol -s "run()"
  CHIP_ID_V2=$(cast call "$CIRCUITS" "nextId()(uint256)" --rpc-url "$RPC")
  KERNEL_V2=$(cast call "$CIRCUITS" "ownerOf(uint256)(address)" "$CHIP_ID_V2" --rpc-url "$RPC")
  REHEARSED+=(flagshipV2)
fi
[ "$(cast call "$KERNEL_V2" "chipId()(uint256)" --rpc-url "$RPC")" = "$CHIP_ID_V2" ] || die "kernel $KERNEL_V2 does not hold chip $CHIP_ID_V2"
echo "   chip $CHIP_ID_V2 kernel $KERNEL_V2 (manifest $MANIFEST_HASH); allowance payee $PAYEE"
echo "   minSettleGas $(cast call "$KERNEL_V2" "minSettleGas()(uint256)" --rpc-url "$RPC"); token $(cast call "$KERNEL_V2" "token()(address)" --rpc-url "$RPC")"

# The plan, in the flat format tools/launch-check reads (deploy/rehearsal.json's keys for the live kernel v1
# contracts, plus the v2 keys).
FORK_BLOCK_OUT=$BLOCK DEPLOYER=$DEPLOYER COMMIT=$COMMIT CIRCUITS=$CIRCUITS TRANSISTORS=$TRANSISTORS TANK=$TANK \
  REGISTRY=$REGISTRY SEALED_VM=$SEALED_VM FAB=$FAB FACTORY_V1="$(recorded .core.kernelFactory)" \
  LENS_V1="$(recorded .core.lens)" KERNEL_V1="$(recorded .flagship.kernel)" CHIP_ID_V1="$(recorded .flagship.chipId)" \
  KEEPER="$(recorded .keeper)" FACTORY_V2=$FACTORY_V2 KERNEL_IMPL_V2=$KERNEL_IMPL_V2 LENS_V2=$LENS_V2 QUOTE=$QUOTE \
  QUOTE_SHIFT=$QUOTE_SHIFT CHIP_ID_V2=$CHIP_ID_V2 KERNEL_V2=$KERNEL_V2 MANIFEST_HASH=$MANIFEST_HASH PAYEE=$PAYEE \
  REHEARSED="${REHEARSED[*]:-}" NONCES="${NONCES[*]:-}" NONCE_AFTER=$(nonce) \
  BALANCE_AFTER=$(cast balance $DEPLOYER --rpc-url "$RPC" --ether) \
  python3 - "$OUT" <<'EOF'
import json, os, sys
e = os.environ
opt = lambda k: e[k] or None
json.dump({
    "forkBlock": int(e["FORK_BLOCK_OUT"]), "deployer": e["DEPLOYER"], "commit": e["COMMIT"],
    "rehearsed": e["REHEARSED"].split(), "nonceBefore": {k: int(v) for k, v in (kv.split("=") for kv in e["NONCES"].split())},
    "circuits": e["CIRCUITS"], "transistors": e["TRANSISTORS"], "keeperTank": e["TANK"], "teamRegistry": e["REGISTRY"],
    "keeper": opt("KEEPER"), "sealedVM": e["SEALED_VM"], "fab": e["FAB"],
    "kernelFactory": opt("FACTORY_V1"), "lens": opt("LENS_V1"), "kernel": opt("KERNEL_V1"),
    "chipId": int(e["CHIP_ID_V1"]) if e["CHIP_ID_V1"] else None,
    "kernelFactoryV2": e["FACTORY_V2"], "kernelImplV2": e["KERNEL_IMPL_V2"], "lensV2": e["LENS_V2"],
    "quoteV2": e["QUOTE"], "quoteShiftV2": int(e["QUOTE_SHIFT"]), "chipIdV2": int(e["CHIP_ID_V2"]),
    "kernelV2": e["KERNEL_V2"], "manifestHashV2": e["MANIFEST_HASH"], "allowancePayeeV2": e["PAYEE"],
    "deployerNonceAfter": int(e["NONCE_AFTER"]), "deployerBalanceAfter": e["BALANCE_AFTER"],
}, open(sys.argv[1], "w"), indent=1)
EOF
echo "== done: $OUT"
cat "$OUT"; echo
