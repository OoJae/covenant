#!/usr/bin/env bash
#
# Covenant, signing session 3: kernel v2 (IGNIX Directed tokens quoted in USD₮0, contracts/core-v2).
#
#   ALLOWANCE_PAYEE=0x... deploy/launch-kernel-v2.sh               rehearse on a local fork of X Layer. Nothing is
#                                                                  sent and no key is touched.
#   ALLOWANCE_PAYEE=0x... deploy/launch-kernel-v2.sh --broadcast   rehearse, then SEND each step, signed by keystore
#                                                                  'covenant-deployer'.
#
#   1. DeployCoreV2   KernelFactoryV2 (which creates the KernelV2 implementation), LensV2               2 transactions
#   2. LaunchChipV2   the Flow Governor (chips/out/fg.hex) taped out again through the live Fab as a NEW chip, its v2
#                     kernel created with the reference USD₮0 envelope (LaunchChipV2.referenceEnvelope), the chip
#                     handed to the kernel; the script then runs LensV2.preflight            3 transactions, about
#                                                                                            0.042 OKB of tape-out
#
# ALLOWANCE_PAYEE is the wallet that receives the kernel's allowance, in USD₮0. It is part of the kernel's envelope,
# fixed for ever. It must be able to move USD₮0: a wallet (no code, or an EIP-7702 delegation), never the KeeperTank,
# never an address USD₮0 has blocked.
#
# forge asks for the keystore password once per step. That prompt is the last point at which the step can be
# stopped (Ctrl-C). Before a step is sent, this script checks that:
#   - contracts/core-v2, the kernel v1 sources it compiles (contracts/core/src) and the chip files are exactly HEAD,
#     and HEAD is on origin/main (the contracts are verified against that commit);
#   - no .env file, no FOUNDRY_* / DAPP_* variable and no input variable of the two scripts can change the build or
#     the deployment (this script sets every input itself), and OpenZeppelin is 5.7.0;
#   - the processor, Fab and SealedVM recorded in deployments/xlayer.json are live on X Layer (kernel v2 reuses them);
#   - the fork rehearsal (deploy/rehearse-v2.sh) passed from the chain's current state;
#   - the deployer's nonce is the one the rehearsal started the step from, so every contract the step creates
#     lands at the address the rehearsal printed.
# After each step the created addresses are checked on chain, compared with the rehearsal's and written to
# deployments/xlayer.json (.coreV2, .flagshipV2). A step recorded there is skipped, so after an interruption the same
# command carries on where it stopped.
#
# What this does NOT do: launch the token, bind, or touch the Architect's PAY_TO. PAY_TO may point at the v2 kernel
# only when contracts/core-v2/NOTES.md section 9, step 6 allows it (IGNIX's written confirmation, OKX.AI agent
# 14683's review finished, bind succeeded, the fixed Architect deployed). No team wallet may ever pay the kernel.

set -euo pipefail

DEPLOYER=0x84cE7bAe1b788C7aD985D57721cA428b401aE34D
ACCOUNT=covenant-deployer
TAPEOUT_FACTORY=0x1f09DAeFA827f02CBb40967cc91b259763760761
MANAGER=0x96B51c57e5346D0C0198899243cf851D1E23C309
USDT0=0x779Ded0c9e1022225f8E0630b35a9b54bE713736
QUOTE_SHIFT=33
FG_NETLIST_KECCAK=0xe548768a1adafa7331faacfd029e1a829b00af3f7d769657f3b234ccdd7143b4
RPC_URL=${XLAYER_RPC_URL:-https://rpc.xlayer.tech}
USAGE="usage: ALLOWANCE_PAYEE=0x... deploy/launch-kernel-v2.sh [--broadcast]"

refuse() {
  echo "launch-kernel-v2.sh: REFUSED: $*" >&2
  exit 1
}
say() { echo "launch-kernel-v2.sh: $*"; }

broadcast=no
case $# in
  0) ;;
  1)
    [ "$1" = "--broadcast" ] || refuse "unknown argument '$1' ($USAGE)"
    broadcast=yes
    ;;
  *) refuse "too many arguments ($USAGE)" ;;
esac
case "$RPC_URL" in
  https://*) ;;
  *) refuse "the RPC must be an https one, not '$RPC_URL'" ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
[ "$(git rev-parse --show-toplevel)" = "$root" ] || refuse "this script belongs in deploy/ of the repository"
LIVE=deployments/xlayer.json
PROJECT=contracts/core-v2
# The rehearsal's plan (its nonces and addresses) is this run's own file: nothing else can change it mid-run.
PLAN=$(mktemp "${TMPDIR:-/tmp}/covenant-plan-v2.XXXXXX")
trap 'rm -f "$PLAN"' EXIT

# ---- 1. The working tree is the commit, and the commit is public.
SOURCES=(contracts/core-v2/src contracts/core-v2/script contracts/core-v2/foundry.toml contracts/core/src
  chips/out/fg.hex chips/out/fg.pins.json deploy)
changes=$(git status --porcelain -- "${SOURCES[@]}" | grep -vE ' deploy/rehearsal(-v2)?\.json$' || true)
[ -z "$changes" ] || refuse "the deployed sources differ from HEAD. Commit them first:"$'\n'"$changes"
for f in contracts/core-v2/src/KernelV2.sol contracts/core-v2/src/KernelFactoryV2.sol contracts/core-v2/src/LensV2.sol \
  contracts/core-v2/src/KernelMathV2.sol contracts/core-v2/src/interfaces/IKernelV2.sol \
  contracts/core-v2/src/interfaces/IQuote.sol contracts/core-v2/script/DeployCoreV2.s.sol \
  contracts/core-v2/script/LaunchChipV2.s.sol contracts/core-v2/foundry.toml chips/out/fg.hex chips/out/fg.pins.json \
  deploy/launch-kernel-v2.sh deploy/rehearse-v2.sh; do
  git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || refuse "$f is not tracked by git"
done
untracked=$(git ls-files --others -- contracts/core-v2/src contracts/core-v2/script contracts/core/src | grep '\.sol$' || true)
[ -z "$untracked" ] || refuse "source files that git does not track (are they ignored?):"$'\n'"$untracked"
git fetch --quiet origin main || refuse "could not fetch origin/main"
git merge-base --is-ancestor HEAD origin/main || refuse "HEAD is not on origin/main. Push first"
COMMIT=$(git rev-parse HEAD)
[ "$(cast keccak "$(tr -d '[:space:]' <chips/out/fg.hex)")" = "$FG_NETLIST_KECCAK" ] \
  || refuse "chips/out/fg.hex is not the Flow Governor netlist of chip 2 (keccak $FG_NETLIST_KECCAK)"

# ---- 2. Nothing outside the commit changes the build or the deployment.
for envfile in .env contracts/core-v2/.env contracts/core/.env; do
  [ ! -e "$envfile" ] || refuse "a .env file is present ($envfile): forge would read it. Move it away first"
done
if env | grep -qE '^(FOUNDRY_|DAPP_)'; then
  refuse "FOUNDRY_* or DAPP_* variables are set in this shell: $(env | grep -E '^(FOUNDRY_|DAPP_)' | cut -d= -f1 | tr '\n' ' ')"
fi
# Every input of DeployCoreV2 and LaunchChipV2 except ALLOWANCE_PAYEE is set by this script for each step; one left
# in the shell (from a rehearsal, say) would change what is deployed, so it is refused rather than overridden.
inputs=$(env | grep -E '^(COVENANT_[A-Z0-9_]+|NETLIST_HEX|MANIFEST_HASH|SALT|REHEARSAL)=' | cut -d= -f1 | tr '\n' ' ' || true)
[ -z "$inputs" ] || refuse "script inputs are set in this shell: $inputs(unset them; this script sets every input itself)"
oz=$( (sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' contracts/core/lib/openzeppelin-contracts/package.json 2>/dev/null || true) | head -1)
[ "$oz" = "5.7.0" ] || refuse "contracts/core/lib/openzeppelin-contracts (used by contracts/core-v2) is '$oz', expected 5.7.0"
export REHEARSAL=false

# ---- 3. What kernel v2 builds on is live.
[ -f "$LIVE" ] || refuse "$LIVE is missing"
[ "$(cast chain-id --rpc-url "$RPC_URL")" = "196" ] || refuse "$RPC_URL is not X Layer (chain 196)"
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
has_code() { [ -n "$1" ] && [ "$1" != "null" ] && [ "$(cast code "$1" --rpc-url "$RPC_URL")" != "0x" ]; }
live() { jq -r "$1 // empty" "$LIVE"; }
planned() { jq -r "$1 // empty" "$PLAN"; }
CIRCUITS=$(live .issuance.circuits)
TANK=$(live .issuance.keeperTank)
FAB=$(live .evaluator.fab)
SEALED_VM=$(live .evaluator.sealedVM)
FG_MANIFEST=$(live .flagship.manifestHash)
[ "$(cast call $TAPEOUT_FACTORY "isCPU(address)(bool)" "$CIRCUITS" --rpc-url "$RPC_URL")" = "true" ] \
  || refuse "$CIRCUITS is not a TapeOut processor"
has_code "$FAB" && has_code "$SEALED_VM" || refuse "$LIVE records no live Fab and SealedVM (kernel v2 reuses kernel v1's)"
[ "$(lower "$(cast call "$FAB" "CIRCUITS()(address)" --rpc-url "$RPC_URL")")" = "$(lower "$CIRCUITS")" ] \
  || refuse "the Fab at $FAB is not for the Covenant processor"
MANIFEST=0x$(shasum -a 256 chips/out/fg.pins.json | awk '{print $1}')
[ "$MANIFEST" = "$FG_MANIFEST" ] || refuse "chips/out/fg.pins.json hashes to $MANIFEST, not the flagship's manifest $FG_MANIFEST"

record_of() { echo "$PROJECT/broadcast/$1/196/run-latest.json"; }
set_live() { # jq filter with $v bound to a JSON value
  local tmp
  tmp=$(mktemp)
  jq --argjson v "$2" "$1" "$LIVE" >"$tmp" && mv "$tmp" "$LIVE"
}
# What reached the chain from a broadcast record, asked of the chain itself. forge writes the record BEFORE it asks
# for the keystore password, so the record alone proves nothing. Prints one word:
#   unsigned    no transaction in it has a hash: nothing was signed, so nothing can have been sent
#   complete    every transaction has a hash, and the chain holds a successful receipt for each
#   incomplete  anything else: part of the step was sent, a transaction failed, or one is still pending
record_state() {
  local n=0 signed=0 ok=0 h status
  for h in $(jq -r '.transactions[] | .hash // "none"' "$1"); do
    n=$((n + 1))
    [ "$h" = "none" ] && continue
    signed=$((signed + 1))
    status=$(cast rpc eth_getTransactionReceipt "$h" --rpc-url "$RPC_URL" | jq -r 'if . == null then "none" else .status end')
    [ "$status" = "0x1" ] && ok=$((ok + 1))
  done
  if [ "$n" -gt 0 ] && [ "$signed" -eq 0 ]; then
    echo unsigned
  elif [ "$n" -gt 0 ] && [ "$ok" -eq "$n" ]; then
    echo complete
  else
    echo incomplete
  fi
}
# Removes an unsigned record, and the timestamped copy forge wrote next to it (same bytes), so that the broadcast
# folders hold only transactions that were sent.
drop_unsigned() {
  local dir copy
  dir=$(dirname "$1")
  for copy in "$dir"/run-[0-9]*.json; do
    [ -f "$copy" ] && cmp -s "$copy" "$1" && rm -f "$copy"
  done
  rm -f "$1"
}
# "name address" for every contract a broadcast record created, then "tx <hash>" for every transaction, then the
# arguments of the chip handover.
read_record() {
  python3 - "$1" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d["transactions"]:
    if t.get("transactionType") == "CREATE" and t.get("contractAddress"):
        print(t.get("contractName") or "?", t["contractAddress"])
for t in d["transactions"]:
    print("tx", t["hash"])
for t in d["transactions"]:
    if (t.get("function") or "").startswith("safeTransferFrom"):
        print("handover", *t["arguments"])
EOF
}
txs_json() { awk '$1=="tx"{print $2}' <<<"$1" | jq -R . | jq -sc .; }

# ---- writing down what a real broadcast created, after checking it on chain
write_coreV2() {
  local rec factory lens impl
  rec=$(read_record "$1")
  factory=$(awk '$1=="KernelFactoryV2"{print $2}' <<<"$rec")
  lens=$(awk '$1=="LensV2"{print $2}' <<<"$rec")
  has_code "$factory" && has_code "$lens" || refuse "the KernelFactoryV2 or LensV2 of $1 has no code on chain"
  impl=$(cast call "$factory" "kernelImpl()(address)" --rpc-url "$RPC_URL")
  has_code "$impl" || refuse "the KernelFactoryV2 at $factory has no KernelV2 implementation"
  [ "$(lower "$(cast call "$factory" "fab()(address)" --rpc-url "$RPC_URL")")" = "$(lower "$FAB")" ] \
    || refuse "the KernelFactoryV2 at $factory was built for another Fab"
  [ "$(lower "$(cast call "$factory" "sealedVM()(address)" --rpc-url "$RPC_URL")")" = "$(lower "$SEALED_VM")" ] \
    || refuse "the KernelFactoryV2 at $factory was built for another SealedVM"
  [ "$(lower "$(cast call "$factory" "circuits()(address)" --rpc-url "$RPC_URL")")" = "$(lower "$CIRCUITS")" ] \
    || refuse "the KernelFactoryV2 at $factory was built for another processor"
  [ "$(lower "$(cast call "$factory" "manager()(address)" --rpc-url "$RPC_URL")")" = "$(lower "$MANAGER")" ] \
    || refuse "the KernelFactoryV2 at $factory is wired to another IgnixManager"
  [ "$(lower "$(cast call "$factory" "quote()(address)" --rpc-url "$RPC_URL")")" = "$(lower "$USDT0")" ] \
    || refuse "the KernelFactoryV2 at $factory does not quote in USD₮0"
  [ "$(cast call "$factory" "quoteShift()(uint256)" --rpc-url "$RPC_URL")" = "$QUOTE_SHIFT" ] \
    || refuse "the KernelFactoryV2 at $factory does not have the $QUOTE_SHIFT-bit code shift"
  [ "$(lower "$(cast call "$lens" "FACTORY()(address)" --rpc-url "$RPC_URL")")" = "$(lower "$factory")" ] \
    || refuse "the LensV2 at $lens reads another factory"
  set_live '.coreV2 = $v' "$(jq -nc --arg c "$COMMIT" --arg f "$factory" --arg i "$impl" --arg l "$lens" --arg q "$USDT0" \
    --argjson s "$QUOTE_SHIFT" --argjson t "$(txs_json "$rec")" \
    '{commit: $c, kernelFactory: $f, kernelImpl: $i, lens: $l, quote: $q, quoteShift: $s, txs: $t}')"
}
write_flagshipV2() {
  local rec kernel chip netlist_hash envelope env_payee env_launcher
  rec=$(read_record "$1")
  read -r _ _ kernel chip <<<"$(awk '$1=="handover"' <<<"$rec")"
  [ -n "${chip:-}" ] || refuse "$1 holds no transfer of the chip to its kernel"
  [ "$(lower "$(cast call "$CIRCUITS" "ownerOf(uint256)(address)" "$chip" --rpc-url "$RPC_URL")")" = "$(lower "$kernel")" ] \
    || refuse "chip $chip is not held by $kernel"
  [ "$(cast call "$kernel" "chipId()(uint256)" --rpc-url "$RPC_URL")" = "$chip" ] || refuse "kernel $kernel is not bound to chip $chip"
  [ "$(cast call "$(live .coreV2.kernelFactory)" "isKernel(address)(bool)" "$kernel" --rpc-url "$RPC_URL")" = "true" ] \
    || refuse "$kernel was not created by the KernelFactoryV2 $(live .coreV2.kernelFactory)"
  [ "$(lower "$(cast call "$kernel" "quote()(address)" --rpc-url "$RPC_URL")")" = "$(lower "$USDT0")" ] \
    || refuse "kernel $kernel does not quote in USD₮0"
  [ "$(cast call "$kernel" "quoteShift()(uint256)" --rpc-url "$RPC_URL")" = "$QUOTE_SHIFT" ] \
    || refuse "kernel $kernel does not have the $QUOTE_SHIFT-bit code shift"
  netlist_hash=$(cast keccak "$(cast call "$CIRCUITS" "netlist(uint256)(bytes)" "$chip" --rpc-url "$RPC_URL")")
  [ "$netlist_hash" = "$FG_NETLIST_KECCAK" ] || refuse "chip $chip's netlist on chain is not chips/out/fg.hex"
  # envelope(): field 1 is the launcher, field 3 the allowance payee
  envelope=$(cast call "$kernel" "envelope()((address,uint32,address,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,bool,address))" \
    --rpc-url "$RPC_URL" | tr -d '() ')
  env_launcher=$(cut -d, -f1 <<<"$envelope")
  env_payee=$(cut -d, -f3 <<<"$envelope")
  [ "$(lower "$env_launcher")" = "$(lower "$DEPLOYER")" ] || refuse "kernel $kernel's launcher is $env_launcher, not the deployer"
  set_live '.flagshipV2 = $v' "$(jq -nc --arg c "$COMMIT" --argjson id "$chip" --arg k "$kernel" --arg n "$netlist_hash" \
    --arg m "$MANIFEST" --arg p "$env_payee" --arg l "$env_launcher" --arg q "$USDT0" --argjson s "$QUOTE_SHIFT" \
    --argjson t "$(txs_json "$rec")" \
    '{commit: $c, chip: "Flow Governor", chipId: $id, kernel: $k, netlistKeccak256: $n, manifestHash: $m, launcher: $l,
      allowancePayee: $p, quote: $q, quoteShift: $s,
      envelope: "LaunchChipV2.referenceEnvelope (contracts/core-v2/script/LaunchChipV2.s.sol)", txs: $t}')"
}

STEPS=(coreV2 flagshipV2)
step_script() {
  case $1 in
    coreV2) echo DeployCoreV2.s.sol ;;
    flagshipV2) echo LaunchChipV2.s.sol ;;
  esac
}
step_done() {
  case $1 in
    coreV2) has_code "$(live .coreV2.lens)" ;;
    flagshipV2) has_code "$(live .flagshipV2.kernel)" ;;
  esac
}
step_write() { "write_$1" "$2"; }

# ---- 4. An earlier run that stopped: a step that reached the chain but was not written down is written down now,
#      never resent; a record of a step that was never signed (stopped at the password prompt) is set aside.
for s in "${STEPS[@]}"; do
  step_done "$s" && continue
  rec=$(record_of "$(step_script "$s")")
  [ -f "$rec" ] || continue
  case $(record_state "$rec") in
    complete)
      say "step '$s' reached the chain in an earlier run; recording it from $rec"
      step_write "$s" "$rec"
      ;;
    unsigned)
      say "step '$s': the earlier run stopped before signing (for example a mistyped password). Nothing of it was sent."
      say "removing forge's unsigned record $rec"
      drop_unsigned "$rec"
      ;;
    *)
      refuse "$rec: only part of step '$s' reached the chain, or one of its transactions failed or is still pending. Nothing more is sent; ask Claude to look at it"
      ;;
  esac
done

# ---- the allowance payee: a wallet that can move USD₮0 (after the recovery above, which may have recorded step 2)
PAYEE_DONE=$(live .flagshipV2.allowancePayee)
PAYEE=${ALLOWANCE_PAYEE:-}
if ! has_code "$(live .flagshipV2.kernel)"; then
  [ -n "$PAYEE" ] || refuse "ALLOWANCE_PAYEE is required ($USAGE): the wallet that receives the v2 kernel's allowance in USD₮0"
  [[ "$PAYEE" =~ ^0x[0-9a-fA-F]{40}$ ]] || refuse "ALLOWANCE_PAYEE '$PAYEE' is not an address"
  [ "$(lower "$PAYEE")" != "0x0000000000000000000000000000000000000000" ] || refuse "ALLOWANCE_PAYEE is the zero address"
  [ "$(lower "$PAYEE")" != "$(lower "$TANK")" ] || refuse "ALLOWANCE_PAYEE is the KeeperTank: it cannot move USD₮0, so the allowance would stay there for ever"
  code=$(cast code "$PAYEE" --rpc-url "$RPC_URL")
  [ "$code" = "0x" ] || [[ "$(lower "$code")" =~ ^0xef0100[0-9a-f]{40}$ ]] \
    || refuse "ALLOWANCE_PAYEE $PAYEE is a contract: choose a wallet (no code, or an EIP-7702 delegation) that can move USD₮0"
  [ "$(cast call $USDT0 "isBlocked(address)(bool)" "$PAYEE" --rpc-url "$RPC_URL")" = "false" ] \
    || refuse "USD₮0 reports ALLOWANCE_PAYEE $PAYEE as blocked"
elif [ -n "$PAYEE" ] && [ "$(lower "$PAYEE")" != "$(lower "$PAYEE_DONE")" ]; then
  refuse "the v2 kernel is already created with allowance payee $PAYEE_DONE; ALLOWANCE_PAYEE $PAYEE would change nothing"
fi

# ---- 5. The rehearsal, from the chain as it is now.
say "commit    $COMMIT"
say "deployer  $DEPLOYER"
say "RPC       $RPC_URL"
step_done flagshipV2 || say "allowance payee (USD₮0) $PAYEE"
say "REHEARSAL on a local fork of X Layer. Nothing is sent."
REHEARSAL_OUT=$PLAN ALLOWANCE_PAYEE=$PAYEE deploy/rehearse-v2.sh
cp "$PLAN" deploy/rehearsal-v2.json # kept for reading; this run uses $PLAN
for s in "${STEPS[@]}"; do
  if step_done "$s"; then
    say "step '$s': on chain already"
  else
    [ -n "$(planned ".nonceBefore.$s")" ] || refuse "the rehearsal did not run step '$s'"
  fi
done
balance=$(cast balance $DEPLOYER --rpc-url "$RPC_URL" --ether)
say "the rehearsal spent $(python3 -c "print(f'{$balance - $(planned .deployerBalanceAfter):.6f}')") OKB of the deployer's $balance"

if [ "$broadcast" = no ]; then
  say "rehearsal only. To send the remaining steps: ALLOWANCE_PAYEE=... deploy/launch-kernel-v2.sh --broadcast"
  exit 0
fi

# ---- 6. The real steps.
expect_same() { # what, real, rehearsed
  [ "$(lower "$2")" = "$(lower "$3")" ] || refuse "$1 is $2 but the rehearsal predicted $3. The step was sent and is recorded in $LIVE; stop and check before anything else"
}
send() { # step, human description, forge script arguments...
  local s=$1 what=$2 want now rec
  shift 2
  want=$(planned ".nonceBefore.$s")
  now=$(cast nonce $DEPLOYER --rpc-url "$RPC_URL")
  [ "$now" = "$want" ] || refuse "the deployer's nonce is $now, the rehearsal started step '$s' from $want. Nothing was sent; run this command again"
  echo
  say "BROADCAST: $what"
  say "forge asks for the keystore password next. Ctrl-C at that prompt stops this step; once entered, it is sent."
  rec=$(record_of "$(step_script "$s")")
  if ! (cd "$PROJECT" && forge script "script/$(step_script "$s")" "$@" --rpc-url "$RPC_URL" \
    --account "$ACCOUNT" --sender "$DEPLOYER" --broadcast --slow); then
    if [ ! -f "$rec" ] || [ "$(record_state "$rec")" = "unsigned" ]; then
      refuse "forge stopped before signing step '$s' (a mistyped password does this). Nothing of it was sent. Run the same command again"
    fi
    refuse "forge stopped during step '$s' after signing. Run the same command again: it first checks what reached the chain and never resends it"
  fi
  [ -f "$rec" ] || refuse "forge wrote no broadcast record for step '$s' ($rec)"
  [ "$(record_state "$rec")" = "complete" ] \
    || refuse "$rec: a transaction of step '$s' did not succeed or is not on chain yet. Nothing more is sent; ask Claude to look at it"
  step_write "$s" "$rec"
}

if ! step_done coreV2; then
  COVENANT_CIRCUITS=$CIRCUITS COVENANT_FAB=$FAB COVENANT_SEALED_VM=$SEALED_VM \
    send coreV2 "step 1 of 2, KernelFactoryV2 and LensV2 (2 transactions)" -s "run()"
  expect_same KernelFactoryV2 "$(live .coreV2.kernelFactory)" "$(planned .kernelFactoryV2)"
  expect_same LensV2 "$(live .coreV2.lens)" "$(planned .lensV2)"
fi
if ! step_done flagshipV2; then
  COVENANT_FAB=$FAB COVENANT_FACTORY_V2=$(live .coreV2.kernelFactory) COVENANT_LENS_V2=$(live .coreV2.lens) \
    ALLOWANCE_PAYEE=$PAYEE MANIFEST_HASH=$MANIFEST \
    send flagshipV2 "step 2 of 2, the Flow Governor taped out as a new chip, its v2 kernel created, the chip handed over (3 transactions)" -s "run()"
  # Anyone may tape out on the processor, so the chip id (and with it the kernel address) can differ from the
  # rehearsal's without anything being wrong; write_flagshipV2 has checked the kernel holds the right chip.
  [ "$(live .flagshipV2.chipId)" = "$(planned .chipIdV2)" ] \
    || say "note: chip id $(live .flagshipV2.chipId), the rehearsal had $(planned .chipIdV2) (someone else taped out in between)"
  expect_same "the allowance payee" "$(live .flagshipV2.allowancePayee)" "$PAYEE"
fi

echo
say "DONE. Everything is recorded in $LIVE:"
jq '{coreV2, flagshipV2}' "$LIVE"
say "Next, in this order (contracts/core-v2/NOTES.md section 9): launch the token at ignix.bot from the deployer (Directed,"
say "quote USD₮0, recipient = flagshipV2.kernel) only after tools/launch-check passes on the exact transaction; then bind."
say "Keep the Architect's PAY_TO on the agent wallet until every condition of NOTES.md section 9, step 6 holds."
say "No team wallet may ever pay the kernel, call the paid endpoint or trade the token."
