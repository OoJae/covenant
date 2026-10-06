#!/usr/bin/env bash
# A local X Layer fork with a Covenant kernel that has settle records, for developing the kernel pages.
#
#   web/scripts/fork-fixture.sh          build the fixture; anvil keeps running afterwards
#   web/scripts/fork-fixture.sh stop     stop that anvil
#
#   then: COVENANT_FORK=web/.fork/deployment.json pnpm --filter web dev
#
# What it does, all on an anvil fork (nothing reaches X Layer; no key of any kind is used or held):
#   1. forks X Layer at the latest block (FORK_BLOCK=... to pin one);
#   2. runs the signing steps that deployments/xlayer.json does not record yet (SealedVM + Fab, KernelFactory +
#      Lens, the Flow Governor taped out with its kernel) from the real deployer address, impersonated, in a scratch
#      copy of contracts/ (the same approach as deploy/rehearse.sh; nothing under contracts/ or deploy/ is written);
#   3. tapes out the Glutton (chips/cells/glutton) through the Fab from an unrelated address, for the hostile page;
#   4. a Directed launch whose vault recipient is the kernel, sent from the deployer (the envelope's launcher), first
#      buy 0, tax 3% / 3%. IGNIX's platform signature is checked with ECDSA.recover against IgnixManager.signer
#      (storage slot 5); the fixture uses a fixed signature, asks the ecrecover precompile which address it recovers
#      to for this launch, and writes that address into the slot on the fork (nobody holds a key for it);
#   5. binds the kernel from an unrelated address, then for EPOCHS epochs: unrelated test accounts buy and sell, time
#      moves 900 s (one epoch; once two), and an unrelated account calls settle();
#   6. kernel v2 (USD₮0 quote, contracts/core-v2; skip with V2=0): KernelFactoryV2 + LensV2 by the DeployCoreV2
#      script and the Flow Governor taped out again with a v2 kernel by LaunchChipV2 (both from the deployer,
#      impersonated, in the scratch copy) unless deployments/xlayer.json records them; a Directed launch quoted in
#      USD₮0 with the v2 kernel as recipient; bind; EPOCHS_V2 curve epochs of USD₮0 trades by unrelated accounts plus
#      revenue paid to the kernel by an unrelated address (plain USD₮0 transfers: what an x402 settlement to
#      payTo = the kernel amounts to on chain; contracts/core-v2's fork tests run the EIP-3009 path itself); then an
#      unrelated whale buys the rest of the curve, the token graduates to its USD₮0 pair, and GRAD_EPOCHS_V2 more
#      epochs of pair trades and revenue are settled;
#   7. writes web/.fork/deployment.json (same shape as deployments/xlayer.json minus .site, plus the fork's RPC, its
#      tokens and record counts, and the v2 keys coreV2 / flagshipV2 the deployment file will gain).
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
V2="${V2:-1}"
EPOCHS_V2="${EPOCHS_V2:-12}"
GRAD_EPOCHS_V2="${GRAD_EPOCHS_V2:-3}"
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
USDT0=0x779Ded0c9e1022225f8E0630b35a9b54bE713736
V2_ROUTER=0x182a927119D56008d921126764bF884221b10f59
# anvil's well-known test accounts (funded on a fork too), driven unlocked: none of them is a team wallet.
TRADERS=(0x70997970C51812dc3A010C7d01b50e0d17dc79C8 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 0x90F79bf6EB2c4f870365E785982E1f101E93b906 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc)
OUTSIDER=0x976EA74026E726554dB657fA54763abd0C3a0aa9 # binds, settles, tapes out the Glutton
PAYER=0x14dC79964da2C08b23698B3D3cc7Ca32193d9955    # pays revenue into the v2 kernel (an x402 buyer, unrelated to the team)
PAYEE_V2=0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f # the v2 kernel's allowance payee on the fork (USD₮0 needs a payee that can move it)
WHALE=0xa0Ee7A142d267C1f36714E4a8F75612F20a79720    # buys the rest of the v2 token's curve
# A fixed signature for the fork's platform signer: r = the x coordinate of secp256k1's generator, s = 1, v = 27.
SIG_R=79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798
SIG_S=0000000000000000000000000000000000000000000000000000000000000001
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
[ "$V2" != "1" ] || rsync -a --exclude 'broadcast/' "$ROOT/contracts/core-v2" "$WORK/contracts/"
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

# ---- 4. a Directed launch with the kernel as recipient
REGISTRY=$(c "$MANAGER" "REGISTRY()(address)")
VAULT_FACTORY=$(c "$REGISTRY" "factoryOf(uint16)(address)" 3)
POOL_FEE=$(c "$MANAGER" "POOL_FEE()(uint256)" | first)
LAUNCH_FACTORY=$(c "$MANAGER" "LAUNCH_FACTORY()(address)")
PARAMS_T="(string,string,string,bytes32,address,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint256,uint256,uint16,uint32,bytes32)"
CREATE_SIG="createToken($PARAMS_T,uint16,bytes,uint64,address,uint8,uint64,bytes)"
# launch NAME SYMBOL QUOTE GRADUATION RECIPIENT: a Directed launch (template 3) sent from the deployer, the
# envelope's launcher; sets LAUNCHED (the token) and LAUNCHED_VAULT. The Manager checks
# ECDSA.recover(digest, sig) == signer(); the fixed signature above recovers to some address for this digest (the
# ecrecover precompile says which), and that address is written into the signer slot on the fork.
launch() {
  local now deadline salt params vault_data inner digest recovered sig
  now=$(cast block latest --field timestamp --rpc-url "$RPC")
  deadline=$((now + 3600))
  salt=0x$(printf '%064x' "$now")
  params="($1,$2,fork://simulation,$salt,$3,$4,100,100,300,300,0,0,0,0,0,0,0x$(printf '%064d' 0))"
  vault_data=$(cast abi-encode "f(address)" "$5")
  inner=$(cast keccak "$(cast abi-encode "f(uint256,address,address,$PARAMS_T,uint16,bytes,uint64,address,uint8,uint64,uint256,address)" \
    196 "$MANAGER" "$DEPLOYER" "$params" 3 "$vault_data" "$deadline" "$VAULT_FACTORY" 1 8640000 "$POOL_FEE" "$LAUNCH_FACTORY")")
  digest=$(cast keccak "0x$(printf '\x19Ethereum Signed Message:\n32' | xxd -p | tr -d '\n')${inner:2}")
  recovered=$(cast call 0x0000000000000000000000000000000000000001 "${digest}$(printf '%064x' 27)${SIG_R}${SIG_S}" --rpc-url "$RPC")
  [ "${#recovered}" -eq 66 ] && [ "$recovered" != "0x$(printf '%064d' 0)" ] || { say "ecrecover gave no address for the launch digest"; exit 1; }
  cast rpc anvil_setStorageAt "$MANAGER" 0x5 "$recovered" --rpc-url "$RPC" >/dev/null
  [ "$(c "$MANAGER" "signer()(address)" | tr '[:upper:]' '[:lower:]')" = "0x${recovered:26}" ] || { say "could not replace the platform signer"; exit 1; }
  sig="0x${SIG_R}${SIG_S}1b"
  LAUNCHED=$(c "$MANAGER" "$CREATE_SIG(address)" "$params" 3 "$vault_data" "$deadline" "$VAULT_FACTORY" 1 8640000 "$sig" --from "$DEPLOYER")
  s "$MANAGER" "$CREATE_SIG" "$params" 3 "$vault_data" "$deadline" "$VAULT_FACTORY" 1 8640000 "$sig" --from "$DEPLOYER" "${GAS[@]}"
  LAUNCHED_VAULT=$(c "$MANAGER" "vaultOf(address)(address)" "$LAUNCHED")
  [ "$(c "$LAUNCHED_VAULT" "RECIPIENT()(address)")" = "$5" ] || { say "the vault's recipient is not the kernel"; exit 1; }
}
launch "Covenant Fork Fixture" CVFORK "$ZERO" 85000000000000000000 "$KERNEL"
TOKEN=$LAUNCHED; VAULT=$LAUNCHED_VAULT
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

# ---- 6. kernel v2 (USD₮0 quote)
V2JSON=null
if [ "$V2" = "1" ]; then
  # USD₮0 for an unrelated account: anvil's dealERC20 on the fork, or else a transfer from the canonical V3 USD₮0/WOKB
  # pool (impersonated; it holds over a million USD₮0)
  USDT0_HOLDER=0xe3BE6A0137f1b0602Fc1a4841686f43B340a5082
  usdt_bal() { c "$USDT0" "balanceOf(address)(uint256)" "$1" | first; }
  fund_usdt() {
    cast rpc anvil_dealERC20 "$USDT0" "$1" "$(python3 -c "print(hex($(usdt_bal "$1") + $2))")" --rpc-url "$RPC" >/dev/null 2>&1 && return 0
    cast rpc anvil_setBalance "$USDT0_HOLDER" 0x8ac7230489e80000 --rpc-url "$RPC" >/dev/null
    s "$USDT0" "transfer(address,uint256)" "$1" "$2" --from "$USDT0_HOLDER" "${GAS[@]}"
  }
  U() { python3 -c "print(int($1 * 10**6))"; } # USD₮0 base units

  F2=$(live .coreV2.kernelFactory); L2=$(live .coreV2.lens)
  if has_code "$F2" && has_code "$L2"; then
    say "KernelFactoryV2 and LensV2: on chain already"
  else
    run core-v2 script/DeployCoreV2.s.sol
    REC="$WORK/contracts/core-v2/broadcast/DeployCoreV2.s.sol/196/run-latest.json"
    F2=$(created "$REC" KernelFactoryV2); L2=$(created "$REC" LensV2)
  fi
  IMPL2=$(c "$F2" "kernelImpl()(address)")
  say "KernelFactoryV2 $F2 (implementation $IMPL2, shift $(c "$F2" "quoteShift()(uint256)") bits), LensV2 $L2"

  K2=$(live .flagshipV2.kernel); CHIP2=$(live .flagshipV2.chipId)
  if has_code "$K2"; then
    say "v2 flagship kernel: on chain already"
  else
    cast rpc anvil_setBalance "$DEPLOYER" 0x8ac7230489e80000 --rpc-url "$RPC" >/dev/null # 10 OKB on the fork, for the tape-out
    COVENANT_FAB=$FAB COVENANT_FACTORY_V2=$F2 COVENANT_LENS_V2=$L2 ALLOWANCE_PAYEE=$PAYEE_V2 run core-v2 script/LaunchChipV2.s.sol
    CHIP2=$(c "$CIRCUITS" "nextId()(uint256)" | first)
    K2=$(c "$CIRCUITS" "ownerOf(uint256)(address)" "$CHIP2")
  fi
  [ "$(c "$F2" "isKernel(address)(bool)" "$K2")" = "true" ] || { say "KernelFactoryV2 did not create $K2"; exit 1; }
  say "chip $CHIP2 held by kernel v2 $K2"

  launch "Covenant Fork Fixture v2" CVFORK2 "$USDT0" 8000000000 "$K2"
  TOKEN2=$LAUNCHED; VAULT2=$LAUNCHED_VAULT
  [ "$(c "$VAULT2" "QUOTE()(address)")" = "$USDT0" ] || { say "the v2 vault is not quoted in USD₮0"; exit 1; }
  say "v2 token $TOKEN2, vault $VAULT2 (quote USD₮0, recipient: the v2 kernel)"
  s "$K2" "bind(address)" "$TOKEN2" --from "$OUTSIDER" "${GAS[@]}"
  say "v2 bound by an unrelated address; kernelOf(token) = $(c "$F2" "kernelOf(address)(address)" "$TOKEN2")"

  buy2() { fund_usdt "$1" "$2"; s "$USDT0" "approve(address,uint256)" "$MANAGER" "$2" --from "$1" "${GAS[@]}"; s "$MANAGER" "buy(address,uint256,uint256)" "$TOKEN2" "$2" 0 --from "$1" "${GAS[@]}"; }
  sell2_half() {
    local bal; bal=$(c "$TOKEN2" "balanceOf(address)(uint256)" "$1" | first)
    [ "$bal" != "0" ] || return 0
    local amt; amt=$(python3 -c "print($bal // 2)")
    s "$TOKEN2" "approve(address,uint256)" "$MANAGER" "$amt" --from "$1" "${GAS[@]}"
    s "$MANAGER" "sell(address,uint256,uint256)" "$TOKEN2" "$amt" 0 --from "$1" "${GAS[@]}" || say "  (a sell was refused; continuing)"
  }
  pay() { fund_usdt "$PAYER" "$1"; s "$USDT0" "transfer(address,uint256)" "$K2" "$1" --from "$PAYER" "${GAS[@]}"; } # revenue
  SWAP_SIG="swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)"
  pair_buy() {
    fund_usdt "$1" "$2"; s "$USDT0" "approve(address,uint256)" "$V2_ROUTER" "$2" --from "$1" "${GAS[@]}"
    s "$V2_ROUTER" "$SWAP_SIG" "$2" 0 "[$USDT0,$TOKEN2]" "$1" "$(( $(cast block latest --field timestamp --rpc-url "$RPC") + 600 ))" --from "$1" "${GAS[@]}"
  }
  pair_sell_half() {
    local bal; bal=$(c "$TOKEN2" "balanceOf(address)(uint256)" "$1" | first)
    [ "$bal" != "0" ] || return 0
    local amt; amt=$(python3 -c "print($bal // 2)")
    s "$TOKEN2" "approve(address,uint256)" "$V2_ROUTER" "$amt" --from "$1" "${GAS[@]}"
    s "$V2_ROUTER" "$SWAP_SIG" "$amt" 0 "[$TOKEN2,$USDT0]" "$1" "$(( $(cast block latest --field timestamp --rpc-url "$RPC") + 600 ))" --from "$1" "${GAS[@]}" || say "  (a pair sell was refused; continuing)"
  }

  # Per epoch: USD₮0 bought on the curve by outsiders, and $0.50 revenue payments (x402 calls) paid to the kernel.
  PLAN2=(30 25 35 30 400 350 20 0 0 5 2 30 25 40)
  CALLS2=(2 1 3 0 4 8 1 0 2 0 1 2 1 3)
  n2=0
  for e in $(seq 1 "$EPOCHS_V2"); do
    i=$(( (e - 1) % ${#PLAN2[@]} ))
    amt=${PLAN2[$i]}; calls=${CALLS2[$i]}
    if [ "$amt" != "0" ]; then
      t=${TRADERS[$(( e % ${#TRADERS[@]} ))]}
      buy2 "$t" "$(U "$amt / 2")"
      buy2 "${TRADERS[$(( (e + 2) % ${#TRADERS[@]} ))]}" "$(U "$amt / 2")"
      [ $((e % 3)) -ne 0 ] || sell2_half "$t"
    fi
    for _ in $(seq 1 "$calls"); do pay 500000; done
    if [ "$e" -eq 9 ]; then advance 1800; else advance 900; fi
    s "$K2" "settle()" --from "$OUTSIDER" "${GAS[@]}"
    n2=$(c "$K2" "count()(uint32)")
    say "v2 epoch $e: bought $amt USD₮0 on the curve, $calls revenue payment(s) of 0.50 USD₮0, settled record $n2"
  done

  # graduation: an unrelated whale buys the rest of the curve (the excess is refunded)
  GRAD_AT=null
  if [ "$GRAD_EPOCHS_V2" -gt 0 ]; then
    COST=$(python3 - "$(c "$MANAGER" "tokens(address)" "$TOKEN2")" <<'PY'
import sys
h = sys.argv[1][2:]
w = [int(h[64 * i:64 * i + 64], 16) for i in range(len(h) // 64)]
buy_fee, tax_buy, vq, vt, sold, sellable = w[1], w[3], w[9], w[10], w[11], w[13]
left = sellable - sold
net = -(-vq * left // (vt - left))
print(-(-net * 10000 // (10000 - (buy_fee + tax_buy))) + 25_000_000)
PY
)
    buy2 "$WHALE" "$COST"
    PAIR2=$(c "$TOKEN2" "pair()(address)")
    [ "$PAIR2" != "$ZERO" ] || { say "the v2 token did not graduate"; exit 1; }
    say "v2 token graduated: pair $PAIR2 (the whale paid at most $(python3 -c "print($COST / 1e6)") USD₮0)"
    for e in $(seq 1 "$GRAD_EPOCHS_V2"); do
      t=${TRADERS[$(( e % ${#TRADERS[@]} ))]}
      pair_buy "$t" "$(U 40)"
      [ $((e % 2)) -ne 0 ] || pair_sell_half "$t"
      for _ in $(seq 1 $((e + 1))); do pay 500000; done
      advance 900
      s "$K2" "settle()" --from "$OUTSIDER" "${GAS[@]}"
      n2=$(c "$K2" "count()(uint32)")
      [ "$GRAD_AT" != "null" ] || [ "$(c "$K2" "graduated()(bool)")" != "true" ] || GRAD_AT=$n2
      say "v2 graduated epoch $e: pair trades and $((e + 1)) revenue payment(s), settled record $n2 (graduated: $(c "$K2" "graduated()(bool)"))"
    done
  fi
  [ "$(c "$USDT0" "allowance(address,address)(uint256)" "$K2" "$MANAGER" | first)" = "0" ] || { say "the v2 kernel left an allowance to the Manager"; exit 1; }
  [ "$(c "$USDT0" "allowance(address,address)(uint256)" "$K2" "$V2_ROUTER" | first)" = "0" ] || { say "the v2 kernel left an allowance to the router"; exit 1; }
  V2JSON=$(jq -n --arg f "$F2" --arg i "$IMPL2" --arg l "$L2" --argjson chip "$CHIP2" --arg k "$K2" --arg t "$TOKEN2" --argjson n "$n2" --argjson g "$GRAD_AT" \
    '{coreV2: {kernelFactory: $f, kernelImpl: $i, lens: $l}, flagshipV2: {chipId: $chip, kernel: $k}, v2: {token: $t, records: $n, graduatedAt: $g}}')
fi

# ---- 7. the deployment file the site reads with COVENANT_FORK
jq -n --arg rpc "$RPC" --argjson block "$BLOCK" --argjson live "$(jq 'del(.site)' "$LIVE")" \
  --arg sealed "$SEALED_VM" --arg fab "$FAB" --arg factory "$FACTORY" --arg impl "$KERNEL_IMPL" --arg lens "$LENS" \
  --argjson chip "$CHIP_ID" --arg kernel "$KERNEL" --argjson glutton "$GLUTTON_ID" --arg token "$TOKEN" --argjson count "$n" --argjson v2 "$V2JSON" '
  $live + {
    note: "LOCAL ANVIL FORK of X Layer, built by web/scripts/fork-fixture.sh. Simulation: none of this happened on X Layer.",
    fork: ({rpc: $rpc, block: $block, token: $token, records: $count} + (if $v2 then {v2: $v2.v2} else {} end)),
    evaluator: {sealedVM: $sealed, fab: $fab},
    core: {kernelFactory: $factory, kernelImpl: $impl, lens: $lens},
    flagship: {chipId: $chip, kernel: $kernel},
    glutton: {chipId: $glutton}
  } + (if $v2 then {coreV2: $v2.coreV2, flagshipV2: $v2.flagshipV2} else {} end)' >"$OUTDIR/deployment.json"
say "wrote $OUTDIR/deployment.json ($n records$([ "$V2" != "1" ] || echo "; kernel v2: $n2 records, first graduated record $GRAD_AT")). anvil keeps running on $RPC; stop it with: web/scripts/fork-fixture.sh stop"
say "site against the fork: COVENANT_FORK=web/.fork/deployment.json pnpm --filter web dev"
