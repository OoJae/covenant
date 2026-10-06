#!/usr/bin/env bash
# Rehearses every mainnet signing step of Covenant, in order, on a local anvil fork of X Layer, from the real
# deployer address (impersonated: no key is used, nothing reaches the real chain).
#
#   deploy/rehearse.sh              fork at the latest block
#   FORK_BLOCK=72400000 deploy/rehearse.sh
#
# Steps (the same ones the wallet holder signs later, in this order):
#   1. Ignite          contracts/issuance  Splitter -> processor, KeeperTank, TeamRegistry   (1 transaction)
#   2. TapeoutProbe    contracts/issuance  the 118-gate probe circuit                        (3 transactions)
#   3. DeployEvaluator contracts/evaluator SealedVM, Fab                                      (2 transactions)
#   4. DeployCore      contracts/core      KernelFactory (+ Kernel implementation), Lens      (2 transactions)
#   5. LaunchChip      contracts/core      Fab tape-out of the Flow Governor, kernel, chip -> kernel (3 transactions)
# Every address is read back from the broadcast records and written to deploy/rehearsal.json.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOYER=0x84cE7bAe1b788C7aD985D57721cA428b401aE34D
UPSTREAM="${XLAYER_RPC_URL:-https://rpc.xlayer.tech}"
PORT="${PORT:-48600}"
RPC="http://127.0.0.1:$PORT"
OUT="$ROOT/deploy/rehearsal.json"
COMMIT="${COMMIT:-$(git -C "$ROOT" rev-parse HEAD)}"

fork_args=(--fork-url "$UPSTREAM" --port "$PORT" --auto-impersonate --silent)
[ -n "${FORK_BLOCK:-}" ] && fork_args+=(--fork-block-number "$FORK_BLOCK")
anvil "${fork_args[@]}" &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
[ "$(cast chain-id --rpc-url "$RPC")" = "196" ] || { echo "fork did not start"; exit 1; }
echo "fork of X Layer at block $(cast block-number --rpc-url "$RPC"); deployer nonce $(cast nonce $DEPLOYER --rpc-url "$RPC"), balance $(cast balance $DEPLOYER --rpc-url "$RPC" --ether) OKB"

# Last broadcast record of a script: prints "name address" for every contract it created.
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
  (cd "$ROOT/contracts/$project" && forge script "$@" --rpc-url "$RPC" --sender "$DEPLOYER" --unlocked --broadcast --slow -q)
}
latest() { echo "$ROOT/contracts/$1/broadcast/$2/196/run-latest.json"; }
cleanup_records() { rm -rf "$ROOT"/contracts/{issuance,evaluator,core}/broadcast/*/196; }
trap 'cleanup_records; kill $ANVIL 2>/dev/null || true' EXIT

echo "== 1. Ignite (commit $COMMIT)"
MAINTAINER=$DEPLOYER COMMIT=$COMMIT run issuance script/Ignite.s.sol:Ignite
SPLITTER=$(created "$(latest issuance Ignite.s.sol)" | awk '$1=="Splitter"{print $2}')
CIRCUITS=$(cast call "$SPLITTER" "CIRCUITS()(address)" --rpc-url "$RPC")
TRANSISTORS=$(cast call "$SPLITTER" "TRANSISTORS()(address)" --rpc-url "$RPC")
TANK=$(cast call "$SPLITTER" "TANK()(address)" --rpc-url "$RPC")
REGISTRY=$(cast call "$SPLITTER" "REGISTRY()(address)" --rpc-url "$RPC")
echo "   splitter $SPLITTER circuits $CIRCUITS transistors $TRANSISTORS tank $TANK registry $REGISTRY"

echo "== 2. TapeoutProbe"
CIRCUITS=$CIRCUITS NETLIST_HEX=$(cat "$ROOT/chips/probe/probe.hex") N_IN=2 N_OUT=10 run issuance script/TapeoutProbe.s.sol:TapeoutProbe
PROBE_ID=$(cast call "$CIRCUITS" "nextId()(uint256)" --rpc-url "$RPC")
echo "   probe circuit id $PROBE_ID, owner $(cast call "$CIRCUITS" "ownerOf(uint256)(address)" "$PROBE_ID" --rpc-url "$RPC")"

echo "== 3. DeployEvaluator"
COVENANT_CIRCUITS=$CIRCUITS COVENANT_TRANSISTORS=$TRANSISTORS run evaluator script/DeployEvaluator.s.sol
SEALED_VM=$(created "$(latest evaluator DeployEvaluator.s.sol)" | awk '$1=="SealedVM"{print $2}')
FAB=$(created "$(latest evaluator DeployEvaluator.s.sol)" | awk '$1=="Fab"{print $2}')
echo "   SealedVM $SEALED_VM Fab $FAB"

echo "== 4. DeployCore"
COVENANT_CIRCUITS=$CIRCUITS COVENANT_FAB=$FAB COVENANT_SEALED_VM=$SEALED_VM run core script/DeployCore.s.sol
FACTORY=$(created "$(latest core DeployCore.s.sol)" | awk '$1=="KernelFactory"{print $2}')
LENS=$(created "$(latest core DeployCore.s.sol)" | awk '$1=="Lens"{print $2}')
echo "   KernelFactory $FACTORY Lens $LENS"

echo "== 5. LaunchChip"
MANIFEST_HASH=$(python3 -c "import hashlib;print('0x'+hashlib.sha256(open('$ROOT/chips/out/fg.pins.json','rb').read()).hexdigest())")
COVENANT_FAB=$FAB COVENANT_FACTORY=$FACTORY COVENANT_LENS=$LENS NETLIST_HEX=$(cat "$ROOT/chips/out/fg.hex") \
  MANIFEST_HASH=$MANIFEST_HASH ALLOWANCE_PAYEE=$TANK run core script/LaunchChip.s.sol
CHIP_ID=$(cast call "$CIRCUITS" "nextId()(uint256)" --rpc-url "$RPC")
KERNEL=$(cast call "$CIRCUITS" "ownerOf(uint256)(address)" "$CHIP_ID" --rpc-url "$RPC")
echo "   chip $CHIP_ID kernel $KERNEL (manifest $MANIFEST_HASH)"

python3 - "$OUT" <<EOF
import json, sys
json.dump({"forkBlock": None, "deployer": "$DEPLOYER", "commit": "$COMMIT", "splitter": "$SPLITTER", "circuits": "$CIRCUITS",
           "transistors": "$TRANSISTORS", "keeperTank": "$TANK", "teamRegistry": "$REGISTRY", "probeCircuitId": $PROBE_ID,
           "sealedVM": "$SEALED_VM", "fab": "$FAB", "kernelFactory": "$FACTORY", "lens": "$LENS", "chipId": $CHIP_ID,
           "kernel": "$KERNEL", "manifestHash": "$MANIFEST_HASH",
           "deployerNonceAfter": $(cast nonce $DEPLOYER --rpc-url "$RPC"),
           "deployerBalanceAfter": "$(cast balance $DEPLOYER --rpc-url "$RPC" --ether)"}, open(sys.argv[1], "w"), indent=1)
EOF
echo "== done: $OUT"
cat "$OUT"
