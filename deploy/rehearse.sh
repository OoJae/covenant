#!/usr/bin/env bash
# Rehearses the mainnet signing steps of Covenant on a local anvil fork of X Layer, from the real deployer address
# (impersonated: no key is used, nothing reaches the real chain).
#
#   deploy/rehearse.sh                      fork at the latest block
#   FORK_BLOCK=72500000 deploy/rehearse.sh  fork at a given block
#
# Steps, in the order the wallet holder signs them:
#   1. Ignite          contracts/issuance  Splitter -> processor, KeeperTank, TeamRegistry           1 transaction
#   2. TapeoutProbe    contracts/issuance  the 118-gate probe circuit                                3 transactions
#   3. DeployEvaluator contracts/evaluator SealedVM, Fab                                             2 transactions
#   4. DeployCore      contracts/core      KernelFactory (+ Kernel implementation), Lens             2 transactions
#   5. LaunchChip      contracts/core      Fab tape-out of the Flow Governor, kernel, chip -> kernel 3 transactions
#
# A step whose contracts deployments/xlayer.json records, and which exist on the fork, is not rehearsed: the
# recorded addresses are used instead. On today's chain the rehearsal therefore covers the steps still to be signed.
#
# Everything runs in a scratch copy of the contracts, so no broadcast record of a rehearsal can land in the
# repository, where the real ones are committed. The one file written in the repository is deploy/rehearsal.json
# (or the file REHEARSAL_OUT names).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOYER=0x84cE7bAe1b788C7aD985D57721cA428b401aE34D
UPSTREAM="${XLAYER_RPC_URL:-https://rpc.xlayer.tech}"
# A free port by default: a port another fork already holds would make this script drive that fork instead.
PORT="${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
RPC="http://127.0.0.1:$PORT"
OUT="${REHEARSAL_OUT:-$ROOT/deploy/rehearsal.json}"
LIVE="$ROOT/deployments/xlayer.json"
COMMIT="${COMMIT:-$(git -C "$ROOT" rev-parse HEAD)}"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/covenant-rehearsal.XXXXXX")
ANVIL=
cleanup() {
  [ -z "$ANVIL" ] || kill "$ANVIL" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# The scratch copy: the three Foundry projects with their libraries and build cache (no broadcast records), the
# vendored TapeOut sources their test trees compile, and the chip files the scripts and tests read.
mkdir -p "$WORK/contracts" "$WORK/chips"
for p in issuance evaluator core vendor; do
  rsync -a --exclude 'broadcast/' "$ROOT/contracts/$p" "$WORK/contracts/"
done
for d in out probe golden; do
  rsync -a "$ROOT/chips/$d" "$WORK/chips/"
done

fork_args=(--fork-url "$UPSTREAM" --port "$PORT" --auto-impersonate --silent)
[ -z "${FORK_BLOCK:-}" ] || fork_args+=(--fork-block-number "$FORK_BLOCK")
anvil "${fork_args[@]}" &
ANVIL=$!
for _ in $(seq 1 60); do
  kill -0 "$ANVIL" 2>/dev/null || { echo "rehearse.sh: anvil exited (is port $PORT taken?)" >&2; exit 1; }
  cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
  sleep 1
done
[ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" = "196" ] || { echo "rehearse.sh: the fork did not start" >&2; exit 1; }
kill -0 "$ANVIL" 2>/dev/null || { echo "rehearse.sh: anvil exited; something else answers on port $PORT" >&2; exit 1; }
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
    for a in t.get("additionalContracts") or []:
        print("(inner)", a["address"])
EOF
}
run() { # project script-args...
  local project="$1"; shift
  (cd "$WORK/contracts/$project" && forge script "$@" --rpc-url "$RPC" --sender "$DEPLOYER" --unlocked --broadcast --slow)
}
latest() { echo "$WORK/contracts/$1/broadcast/$2/196/run-latest.json"; }
recorded() { # jq path in deployments/xlayer.json -> value, or empty
  [ -f "$LIVE" ] || return 0
  jq -r "$1 // empty" "$LIVE"
}
has_code() { [ -n "$1" ] && [ "$(cast code "$1" --rpc-url "$RPC")" != "0x" ]; }
nonce() { cast nonce $DEPLOYER --rpc-url "$RPC"; }

REHEARSED=()
NONCES=()

echo "== 1. Ignite"
SPLITTER=$(recorded .issuance.splitter)
if has_code "$SPLITTER"; then
  echo "   on chain already (deployments/xlayer.json): splitter $SPLITTER"
else
  NONCES+=("ignite=$(nonce)")
  MAINTAINER=$DEPLOYER COMMIT=$COMMIT run issuance script/Ignite.s.sol:Ignite
  SPLITTER=$(created "$(latest issuance Ignite.s.sol)" | awk '$1=="Splitter"{print $2}')
  REHEARSED+=(ignite)
fi
CIRCUITS=$(cast call "$SPLITTER" "CIRCUITS()(address)" --rpc-url "$RPC")
TRANSISTORS=$(cast call "$SPLITTER" "TRANSISTORS()(address)" --rpc-url "$RPC")
TANK=$(cast call "$SPLITTER" "TANK()(address)" --rpc-url "$RPC")
REGISTRY=$(cast call "$SPLITTER" "REGISTRY()(address)" --rpc-url "$RPC")
echo "   splitter $SPLITTER circuits $CIRCUITS transistors $TRANSISTORS tank $TANK registry $REGISTRY"

echo "== 2. TapeoutProbe"
PROBE_ID=$(recorded .probe.circuitId)
if [ -n "$PROBE_ID" ] && cast call "$CIRCUITS" "ownerOf(uint256)(address)" "$PROBE_ID" --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "   on chain already (deployments/xlayer.json): probe circuit $PROBE_ID"
else
  NONCES+=("probe=$(nonce)")
  CIRCUITS=$CIRCUITS NETLIST_HEX=$(cat "$WORK/chips/probe/probe.hex") N_IN=2 N_OUT=10 \
    run issuance script/TapeoutProbe.s.sol:TapeoutProbe
  PROBE_ID=$(cast call "$CIRCUITS" "nextId()(uint256)" --rpc-url "$RPC")
  REHEARSED+=(probe)
fi
echo "   probe circuit id $PROBE_ID, owner $(cast call "$CIRCUITS" "ownerOf(uint256)(address)" "$PROBE_ID" --rpc-url "$RPC")"

echo "== 3. DeployEvaluator"
SEALED_VM=$(recorded .evaluator.sealedVM)
FAB=$(recorded .evaluator.fab)
if has_code "$SEALED_VM" && has_code "$FAB"; then
  echo "   on chain already (deployments/xlayer.json)"
else
  NONCES+=("evaluator=$(nonce)")
  COVENANT_CIRCUITS=$CIRCUITS COVENANT_TRANSISTORS=$TRANSISTORS run evaluator script/DeployEvaluator.s.sol
  SEALED_VM=$(created "$(latest evaluator DeployEvaluator.s.sol)" | awk '$1=="SealedVM"{print $2}')
  FAB=$(created "$(latest evaluator DeployEvaluator.s.sol)" | awk '$1=="Fab"{print $2}')
  REHEARSED+=(evaluator)
fi
echo "   SealedVM $SEALED_VM Fab $FAB"

echo "== 4. DeployCore"
FACTORY=$(recorded .core.kernelFactory)
LENS=$(recorded .core.lens)
if has_code "$FACTORY" && has_code "$LENS"; then
  echo "   on chain already (deployments/xlayer.json)"
else
  NONCES+=("core=$(nonce)")
  COVENANT_CIRCUITS=$CIRCUITS COVENANT_FAB=$FAB COVENANT_SEALED_VM=$SEALED_VM run core script/DeployCore.s.sol
  FACTORY=$(created "$(latest core DeployCore.s.sol)" | awk '$1=="KernelFactory"{print $2}')
  LENS=$(created "$(latest core DeployCore.s.sol)" | awk '$1=="Lens"{print $2}')
  REHEARSED+=(core)
fi
KERNEL_IMPL=$(cast call "$FACTORY" "kernelImpl()(address)" --rpc-url "$RPC")
echo "   KernelFactory $FACTORY (Kernel implementation $KERNEL_IMPL) Lens $LENS"

echo "== 5. LaunchChip"
MANIFEST_HASH=0x$(shasum -a 256 "$WORK/chips/out/fg.pins.json" | awk '{print $1}')
KERNEL=$(recorded .flagship.kernel)
CHIP_ID=$(recorded .flagship.chipId)
if has_code "$KERNEL"; then
  echo "   on chain already (deployments/xlayer.json)"
else
  NONCES+=("flagship=$(nonce)")
  COVENANT_FAB=$FAB COVENANT_FACTORY=$FACTORY COVENANT_LENS=$LENS NETLIST_HEX=$(cat "$WORK/chips/out/fg.hex") \
    MANIFEST_HASH=$MANIFEST_HASH ALLOWANCE_PAYEE=$TANK run core script/LaunchChip.s.sol
  CHIP_ID=$(cast call "$CIRCUITS" "nextId()(uint256)" --rpc-url "$RPC")
  KERNEL=$(cast call "$CIRCUITS" "ownerOf(uint256)(address)" "$CHIP_ID" --rpc-url "$RPC")
  REHEARSED+=(flagship)
fi
echo "   chip $CHIP_ID kernel $KERNEL (manifest $MANIFEST_HASH)"

FORK_BLOCK_OUT=$BLOCK DEPLOYER=$DEPLOYER COMMIT=$COMMIT SPLITTER=$SPLITTER CIRCUITS=$CIRCUITS TRANSISTORS=$TRANSISTORS \
  TANK=$TANK REGISTRY=$REGISTRY PROBE_ID=$PROBE_ID SEALED_VM=$SEALED_VM FAB=$FAB FACTORY=$FACTORY \
  KERNEL_IMPL=$KERNEL_IMPL LENS=$LENS CHIP_ID=$CHIP_ID KERNEL=$KERNEL MANIFEST_HASH=$MANIFEST_HASH \
  REHEARSED="${REHEARSED[*]:-}" NONCES="${NONCES[*]:-}" NONCE_AFTER=$(nonce) \
  BALANCE_AFTER=$(cast balance $DEPLOYER --rpc-url "$RPC" --ether) \
  python3 - "$OUT" <<'EOF'
import json, os, sys
e = os.environ
json.dump({
    "forkBlock": int(e["FORK_BLOCK_OUT"]), "deployer": e["DEPLOYER"], "commit": e["COMMIT"],
    "rehearsed": e["REHEARSED"].split(), "nonceBefore": {k: int(v) for k, v in (kv.split("=") for kv in e["NONCES"].split())},
    "splitter": e["SPLITTER"], "circuits": e["CIRCUITS"], "transistors": e["TRANSISTORS"],
    "keeperTank": e["TANK"], "teamRegistry": e["REGISTRY"], "probeCircuitId": int(e["PROBE_ID"]),
    "sealedVM": e["SEALED_VM"], "fab": e["FAB"], "kernelFactory": e["FACTORY"], "kernelImpl": e["KERNEL_IMPL"],
    "lens": e["LENS"], "chipId": int(e["CHIP_ID"]), "kernel": e["KERNEL"], "manifestHash": e["MANIFEST_HASH"],
    "deployerNonceAfter": int(e["NONCE_AFTER"]), "deployerBalanceAfter": e["BALANCE_AFTER"],
}, open(sys.argv[1], "w"), indent=1)
EOF
echo "== done: $OUT"
cat "$OUT"; echo
