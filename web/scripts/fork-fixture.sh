#!/usr/bin/env bash
# A local X Layer fork with a Covenant kernel that has settle records, for developing the kernel pages.
#
#   web/scripts/fork-fixture.sh          build the fixture; anvil keeps running afterwards
#   web/scripts/fork-fixture.sh stop     stop that anvil
#
#   then: COVENANT_FORK=web/.fork/deployment.json pnpm --filter web dev
#
# What it does, all on an anvil fork (nothing reaches X Layer, no real key is used):
#   1. forks X Layer at the latest block (FORK_BLOCK=... to pin one);
#   2. runs the signing steps that deployments/xlayer.json does not record yet (SealedVM + Fab, KernelFactory +
#      Lens, the Flow Governor taped out with its kernel) from the real deployer address, impersonated, in a scratch
#      copy of contracts/ (the same approach as deploy/rehearse.sh; nothing under contracts/ or deploy/ is written);
#   3. tapes out the Glutton (chips/cells/glutton) through the Fab from an unrelated address, for the hostile page;
#   4. replaces IGNIX's platform signer (IgnixManager storage slot 5) with anvil's first test key, signs a Directed
#      launch whose vault recipient is the kernel, and sends it from the deployer (the envelope's launcher), first
#      buy 0, tax 3% / 3%;
#   5. binds the kernel from an unrelated address, then for EPOCHS epochs: unrelated test accounts buy and sell, time
#      moves 900 s (one epoch; once two), and an unrelated account calls settle();
#   6. writes web/.fork/deployment.json (same shape as deployments/xlayer.json, plus the fork's RPC and token).
#
# Everything the site shows from this fixture is a simulation; the site labels it so whenever COVENANT_FORK is set.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTDIR="$ROOT/web/.fork"
PIDFILE="$OUTDIR/anvil.pid"
# A free port unless PORT is given; never a port something else already answers on (another fork would be driven).
PORT="${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
RPC="http://127.0.0.1:$PORT"
UPSTREAM="${XLAYER_RPC_URL:-https://rpc.xlayer.tech}"
EPOCHS="${EPOCHS:-12}"
LIVE="$ROOT/deployments/xlayer.json"

if [ "${1:-}" = "stop" ]; then
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null && echo "stopped anvil $(cat "$PIDFILE")" || echo "no fixture anvil running"
  rm -f "$PIDFILE"
  exit 0
fi
[ -z "${1:-}" ] || { echo "usage: web/scripts/fork-fixture.sh [stop]" >&2; exit 2; }

DEPLOYER=0x84cE7bAe1b788C7aD985D57721cA428b401aE34D
MANAGER=0x96B51c57e5346D0C0198899243cf851D1E23C309
ZERO=0x0000000000000000000000000000000000000000
# anvil's well-known test accounts (funded on a fork too). Key 0 signs as the fork's platform signer; it is public and
# worthless, and it only ever signs on this fork.
TEST_KEY0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
TEST_SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
TRADERS=(0x70997970C51812dc3A010C7d01b50e0d17dc79C8 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 0x90F79bf6EB2c4f870365E785982E1f101E93b906 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc)
OUTSIDER=0x976EA74026E726554dB657fA54763abd0C3a0aa9 # binds, settles, tapes out the Glutton
GAS=(--gas-limit 16000000)

mkdir -p "$OUTDIR"
[ ! -f "$PIDFILE" ] || { kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/covenant-fork-fixture.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

say() { echo "fork-fixture: $*"; }
c() { cast call "$@" --rpc-url "$RPC"; }
s() { cast send "$@" --rpc-url "$RPC" --unlocked >/dev/null; }
has_code() { [ -n "$1" ] && [ "$1" != "null" ] && [ "$(cast code "$1" --rpc-url "$RPC")" != "0x" ]; }
live() { jq -r "$1 // empty" "$LIVE"; }
first() { awk '{print $1}'; }

# ---- 1. the fork
! cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 || { say "something already answers on $RPC; refusing to use it"; exit 1; }
fork_args=(--fork-url "$UPSTREAM" --port "$PORT" --auto-impersonate --silent)
[ -z "${FORK_BLOCK:-}" ] || fork_args+=(--fork-block-number "$FORK_BLOCK")
nohup anvil "${fork_args[@]}" >"$OUTDIR/anvil.log" 2>&1 &
ANVIL=$!
echo $ANVIL >"$PIDFILE"
for _ in $(seq 1 60); do
  kill -0 "$ANVIL" 2>/dev/null || { say "anvil exited at startup (see $OUTDIR/anvil.log)"; rm -f "$PIDFILE"; exit 1; }
  cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
  sleep 1
done
kill -0 "$ANVIL" 2>/dev/null || { say "anvil is not running (see $OUTDIR/anvil.log)"; rm -f "$PIDFILE"; exit 1; }
[ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" = "196" ] || { say "the fork did not start (see $OUTDIR/anvil.log)"; exit 1; }
BLOCK=$(cast block-number --rpc-url "$RPC")
say "anvil fork of X Layer at block $BLOCK on $RPC (pid $(cat "$PIDFILE"))"

CIRCUITS=$(live .issuance.circuits)
TRANSISTORS=$(live .issuance.transistors)
TANK=$(live .issuance.keeperTank)
has_code "$CIRCUITS" || { say "the processor of deployments/xlayer.json has no code on the fork"; exit 1; }

# ---- 2. the signing steps not recorded yet, in a scratch copy
mkdir -p "$WORK/contracts" "$WORK/chips"
for p in evaluator core vendor; do rsync -a --exclude 'broadcast/' "$ROOT/contracts/$p" "$WORK/contracts/"; done
for d in out probe golden; do rsync -a "$ROOT/chips/$d" "$WORK/chips/"; done
run() { # project script
  local project="$1"; shift
  (cd "$WORK/contracts/$project" && forge script "$@" --rpc-url "$RPC" --sender "$DEPLOYER" --unlocked --broadcast --slow >"$OUTDIR/forge-$project.log" 2>&1) \
    || { say "forge script failed, see $OUTDIR/forge-$project.log"; exit 1; }
}
created() { # broadcast record, contract name
  python3 - "$1" "$2" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d["transactions"]:
    if t.get("transactionType") == "CREATE" and t.get("contractName") == sys.argv[2]:
        print(t["contractAddress"]); break
EOF
}

SEALED_VM=$(live .evaluator.sealedVM); FAB=$(live .evaluator.fab)
if has_code "$FAB" && has_code "$SEALED_VM"; then
  say "SealedVM and Fab: on chain already"
else
  COVENANT_CIRCUITS=$CIRCUITS COVENANT_TRANSISTORS=$TRANSISTORS run evaluator script/DeployEvaluator.s.sol
  REC="$WORK/contracts/evaluator/broadcast/DeployEvaluator.s.sol/196/run-latest.json"
  SEALED_VM=$(created "$REC" SealedVM); FAB=$(created "$REC" Fab)
fi
say "SealedVM $SEALED_VM, Fab $FAB"

FACTORY=$(live .core.kernelFactory); LENS=$(live .core.lens)
if has_code "$FACTORY" && has_code "$LENS"; then
  say "KernelFactory and Lens: on chain already"
else
  COVENANT_CIRCUITS=$CIRCUITS COVENANT_FAB=$FAB COVENANT_SEALED_VM=$SEALED_VM run core script/DeployCore.s.sol
  REC="$WORK/contracts/core/broadcast/DeployCore.s.sol/196/run-latest.json"
  FACTORY=$(created "$REC" KernelFactory); LENS=$(created "$REC" Lens)
fi
KERNEL_IMPL=$(c "$FACTORY" "kernelImpl()(address)")
say "KernelFactory $FACTORY (implementation $KERNEL_IMPL), Lens $LENS"

KERNEL=$(live .flagship.kernel); CHIP_ID=$(live .flagship.chipId)
if has_code "$KERNEL"; then
  say "flagship kernel: on chain already"
else
  COVENANT_FAB=$FAB COVENANT_FACTORY=$FACTORY COVENANT_LENS=$LENS NETLIST_HEX=$(cat "$ROOT/chips/out/fg.hex") \
    MANIFEST_HASH=0x$(shasum -a 256 "$ROOT/chips/out/fg.pins.json" | first) ALLOWANCE_PAYEE=$TANK run core script/LaunchChip.s.sol
  CHIP_ID=$(c "$CIRCUITS" "nextId()(uint256)" | first)
  KERNEL=$(c "$CIRCUITS" "ownerOf(uint256)(address)" "$CHIP_ID")
fi
say "chip $CHIP_ID held by kernel $KERNEL"

# ---- 3. the Glutton, taped out by an outsider
GL_HEX=$(cat "$ROOT/chips/cells/glutton/glutton.hex")
GL_COST=$(c "$FAB" "quote(bytes)(uint256,uint256,uint256)" "$GL_HEX" | sed -n 3p | first)
s "$FAB" "tapeoutChip(bytes,bytes32)" "$GL_HEX" 0x$(shasum -a 256 "$ROOT/chips/cells/glutton/glutton.pins.json" | first) --value "$GL_COST" --from "$OUTSIDER" "${GAS[@]}"
GLUTTON_ID=$(c "$CIRCUITS" "nextId()(uint256)" | first)
say "Glutton taped out as chip $GLUTTON_ID (cost $GL_COST wei)"

# ---- 4. a Directed launch with the kernel as recipient, signed by the fork's throwaway platform signer
cast rpc anvil_setStorageAt "$MANAGER" 0x5 "0x000000000000000000000000${TEST_SIGNER:2}" --rpc-url "$RPC" >/dev/null
[ "$(c "$MANAGER" "signer()(address)")" = "$TEST_SIGNER" ] || { say "could not replace the platform signer"; exit 1; }
REGISTRY=$(c "$MANAGER" "REGISTRY()(address)")
VAULT_FACTORY=$(c "$REGISTRY" "factoryOf(uint16)(address)" 3)
POOL_FEE=$(c "$MANAGER" "POOL_FEE()(uint256)" | first)
LAUNCH_FACTORY=$(c "$MANAGER" "LAUNCH_FACTORY()(address)")
NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
DEADLINE=$((NOW + 3600))
SALT=0x$(printf '%064x' "$NOW")
PARAMS_T="(string,string,string,bytes32,address,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint256,uint256,uint16,uint32,bytes32)"
PARAMS="(Covenant Fork Fixture,CVFORK,fork://simulation,$SALT,$ZERO,85000000000000000000,100,100,300,300,0,0,0,0,0,0,0x$(printf '%064d' 0))"
VAULT_DATA=$(cast abi-encode "f(address)" "$KERNEL")
INNER=$(cast keccak "$(cast abi-encode "f(uint256,address,address,$PARAMS_T,uint16,bytes,uint64,address,uint8,uint64,uint256,address)" \
  196 "$MANAGER" "$DEPLOYER" "$PARAMS" 3 "$VAULT_DATA" "$DEADLINE" "$VAULT_FACTORY" 1 8640000 "$POOL_FEE" "$LAUNCH_FACTORY")")
DIGEST=$(cast keccak "0x$(printf '\x19Ethereum Signed Message:\n32' | xxd -p | tr -d '\n')${INNER:2}")
SIG=$(cast wallet sign --no-hash --private-key "$TEST_KEY0" "$DIGEST")
CREATE_SIG="createToken($PARAMS_T,uint16,bytes,uint64,address,uint8,uint64,bytes)"
TOKEN=$(c "$MANAGER" "$CREATE_SIG(address)" "$PARAMS" 3 "$VAULT_DATA" "$DEADLINE" "$VAULT_FACTORY" 1 8640000 "$SIG" --from "$DEPLOYER")
s "$MANAGER" "$CREATE_SIG" "$PARAMS" 3 "$VAULT_DATA" "$DEADLINE" "$VAULT_FACTORY" 1 8640000 "$SIG" --from "$DEPLOYER" "${GAS[@]}"
VAULT=$(c "$MANAGER" "vaultOf(address)(address)" "$TOKEN")
[ "$(c "$VAULT" "RECIPIENT()(address)")" = "$KERNEL" ] || { say "the vault's recipient is not the kernel"; exit 1; }
say "token $TOKEN, vault $VAULT (recipient: the kernel)"

s "$KERNEL" "bind(address)" "$TOKEN" --from "$OUTSIDER" "${GAS[@]}"
say "bound by an unrelated address; kernelOf(token) = $(c "$FACTORY" "kernelOf(address)(address)" "$TOKEN")"

# ---- 5. trading and settles
buy() { s "$MANAGER" "buy(address,uint256,uint256)" "$TOKEN" "$2" 0 --value "$2" --from "$1" "${GAS[@]}"; }
sell_half() {
  local bal; bal=$(c "$TOKEN" "balanceOf(address)(uint256)" "$1" | first)
  [ "$bal" != "0" ] || return 0
  local amt; amt=$(python3 -c "print($bal // 2)")
  s "$TOKEN" "approve(address,uint256)" "$MANAGER" "$amt" --from "$1" "${GAS[@]}"
  s "$MANAGER" "sell(address,uint256,uint256)" "$TOKEN" "$amt" 0 --from "$1" "${GAS[@]}" || say "  (a sell was refused; continuing)"
}
advance() { cast rpc evm_increaseTime "$1" --rpc-url "$RPC" >/dev/null; cast rpc evm_mine --rpc-url "$RPC" >/dev/null; }
OKB() { python3 -c "print(int($1 * 10**18))"; }

# Per epoch: OKB bought by outsiders (spread over the traders), and whether one of them sells half afterwards.
# Steady trade, a two-epoch surge, a quiet spell (one epoch skipped without a settle), then a trickle.
PLAN=(0.3 0.25 0.35 0.3 4 3.5 0.2 0 0 0.05 0.02 0.3 0.25 0.4 0.3 0.2)
n=0
for e in $(seq 1 "$EPOCHS"); do
  amt=${PLAN[$(( (e - 1) % ${#PLAN[@]} ))]}
  if [ "$amt" != "0" ]; then
    t=${TRADERS[$(( e % ${#TRADERS[@]} ))]}
    buy "$t" "$(OKB "$amt / 2")"
    buy "${TRADERS[$(( (e + 2) % ${#TRADERS[@]} ))]}" "$(OKB "$amt / 2")"
    [ $((e % 3)) -ne 0 ] || sell_half "$t"
  fi
  if [ "$e" -eq 9 ]; then advance 1800; else advance 900; fi # epoch 9 skips one settle: DT = 2 in the next record
  s "$KERNEL" "settle()" --from "$OUTSIDER" "${GAS[@]}"
  n=$(c "$KERNEL" "count()(uint32)")
  say "epoch plan $e: bought $amt OKB, settled record $n"
done

# ---- 6. the deployment file the site reads with COVENANT_FORK
jq -n --arg rpc "$RPC" --argjson block "$BLOCK" --argjson live "$(cat "$LIVE")" \
  --arg sealed "$SEALED_VM" --arg fab "$FAB" --arg factory "$FACTORY" --arg impl "$KERNEL_IMPL" --arg lens "$LENS" \
  --argjson chip "$CHIP_ID" --arg kernel "$KERNEL" --argjson glutton "$GLUTTON_ID" --arg token "$TOKEN" --argjson count "$n" '
  $live + {
    note: "LOCAL ANVIL FORK of X Layer, built by web/scripts/fork-fixture.sh. Simulation: none of this happened on X Layer.",
    fork: {rpc: $rpc, block: $block, token: $token, records: $count},
    evaluator: {sealedVM: $sealed, fab: $fab},
    core: {kernelFactory: $factory, kernelImpl: $impl, lens: $lens},
    flagship: {chipId: $chip, kernel: $kernel},
    glutton: {chipId: $glutton}
  }' >"$OUTDIR/deployment.json"
say "wrote $OUTDIR/deployment.json ($n records). anvil keeps running on $RPC; stop it with: web/scripts/fork-fixture.sh stop"
say "site against the fork: COVENANT_FORK=web/.fork/deployment.json pnpm --filter web dev"
