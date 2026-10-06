#!/usr/bin/env bash
#
# Covenant, signing session 2: the Fab, the kernel factory, the flagship chip with its kernel, and the last
# transactions before the reference token is launched.
#
#   deploy/launch-kernel.sh               rehearse on a local fork of X Layer. Nothing is sent and no key is touched.
#   deploy/launch-kernel.sh --broadcast   rehearse, then SEND each step, signed by keystore 'covenant-deployer'.
#
#   3. DeployEvaluator  SealedVM, Fab                                                    2 transactions
#   4. DeployCore       KernelFactory (which creates the Kernel implementation), Lens     2 transactions
#   5. LaunchChip       the Flow Governor taped out through the Fab, its kernel created,
#                       the chip handed to the kernel                                    3 transactions
#   6. Prelaunch        the two hostile Glutton chips taped out through the Fab (they stay with the deployer;
#                       Lens.shadowChip runs them over the kernel's records), the keeper invited into the
#                       TeamRegistry                                                     3 transactions
#
# forge asks for the keystore password once per step. That prompt is the last point at which the step can be
# stopped (Ctrl-C). Before a step is sent, this script checks that:
#   - contracts/evaluator, contracts/core and the chip files are exactly HEAD, and HEAD is on origin/main
#     (the contracts are verified against that commit);
#   - no .env file and no FOUNDRY_* / DAPP_* variable can change the build, and OpenZeppelin is 5.7.0 in both
#     projects;
#   - the processor recorded in deployments/xlayer.json is a TapeOut processor on X Layer;
#   - the fork rehearsal (deploy/rehearse.sh) passed from the chain's current state;
#   - the deployer's nonce is the one the rehearsal started the step from, so every contract the step creates
#     lands at the address the rehearsal printed.
# After each step the created addresses are checked on chain, compared with the rehearsal's and written to
# deployments/xlayer.json. A step recorded there is skipped, so after an interruption the same command carries on
# where it stopped.

set -euo pipefail

DEPLOYER=0x84cE7bAe1b788C7aD985D57721cA428b401aE34D
ACCOUNT=covenant-deployer
TAPEOUT_FACTORY=0x1f09DAeFA827f02CBb40967cc91b259763760761
RPC_URL=${XLAYER_RPC_URL:-https://rpc.xlayer.tech}
USAGE="usage: deploy/launch-kernel.sh [--broadcast]"

refuse() {
  echo "launch-kernel.sh: REFUSED: $*" >&2
  exit 1
}
say() { echo "launch-kernel.sh: $*"; }

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
# The rehearsal's plan (its nonces and addresses) is this run's own file: nothing else can change it mid-run.
PLAN=$(mktemp "${TMPDIR:-/tmp}/covenant-plan.XXXXXX")
trap 'rm -f "$PLAN"' EXIT

# ---- 1. The working tree is the commit, and the commit is public.
SOURCES=(contracts/evaluator/src contracts/evaluator/script contracts/evaluator/foundry.toml
  contracts/core/src contracts/core/script contracts/core/foundry.toml
  chips/out/fg.hex chips/out/fg.pins.json chips/cells/glutton/glutton.hex chips/cells/glutton/glutton512.hex
  chips/cells/glutton/glutton.pins.json deploy)
changes=$(git status --porcelain -- "${SOURCES[@]}" | grep -v ' deploy/rehearsal.json$' || true)
[ -z "$changes" ] || refuse "the deployed sources differ from HEAD. Commit them first:"$'\n'"$changes"
for f in contracts/evaluator/src/Fab.sol contracts/evaluator/src/SealedVM.sol contracts/core/src/Kernel.sol \
  contracts/core/src/KernelFactory.sol contracts/core/src/Lens.sol chips/out/fg.hex chips/out/fg.pins.json; do
  git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || refuse "$f is not tracked by git"
done
untracked=$(git ls-files --others -- contracts/evaluator/src contracts/evaluator/script contracts/core/src \
  contracts/core/script | grep '\.sol$' || true)
[ -z "$untracked" ] || refuse "source files that git does not track (are they ignored?):"$'\n'"$untracked"
git fetch --quiet origin main || refuse "could not fetch origin/main"
git merge-base --is-ancestor HEAD origin/main || refuse "HEAD is not on origin/main. Push first"
COMMIT=$(git rev-parse HEAD)

# ---- 2. Nothing outside the commit changes the build.
for envfile in .env contracts/evaluator/.env contracts/core/.env; do
  [ ! -e "$envfile" ] || refuse "a .env file is present ($envfile): forge would read it. Move it away first"
done
if env | grep -qE '^(FOUNDRY_|DAPP_)'; then
  refuse "FOUNDRY_* or DAPP_* variables are set in this shell: $(env | grep -E '^(FOUNDRY_|DAPP_)' | cut -d= -f1 | tr '\n' ' ')"
fi
for p in evaluator core; do
  oz=$( (sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "contracts/$p/lib/openzeppelin-contracts/package.json" 2>/dev/null || true) | head -1)
  [ "$oz" = "5.7.0" ] || refuse "contracts/$p/lib/openzeppelin-contracts is '$oz', expected 5.7.0"
done
export REHEARSAL=false

# ---- 3. The processor is live.
[ -f "$LIVE" ] || refuse "$LIVE is missing"
[ "$(cast chain-id --rpc-url "$RPC_URL")" = "196" ] || refuse "$RPC_URL is not X Layer (chain 196)"
CIRCUITS=$(jq -r .issuance.circuits "$LIVE")
TRANSISTORS=$(jq -r .issuance.transistors "$LIVE")
TANK=$(jq -r .issuance.keeperTank "$LIVE")
REGISTRY=$(jq -r .issuance.teamRegistry "$LIVE")
KEEPER=$(jq -r '.keeper // empty' "$LIVE")
[ -n "$KEEPER" ] || refuse "$LIVE names no keeper wallet"
[ "$(cast call $TAPEOUT_FACTORY "isCPU(address)(bool)" "$CIRCUITS" --rpc-url "$RPC_URL")" = "true" ] \
  || refuse "$CIRCUITS is not a TapeOut processor"

lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
has_code() { [ -n "$1" ] && [ "$1" != "null" ] && [ "$(cast code "$1" --rpc-url "$RPC_URL")" != "0x" ]; }
live() { jq -r "$1 // empty" "$LIVE"; }
planned() { jq -r "$1 // empty" "$PLAN"; }
record_of() { echo "contracts/$1/broadcast/$2/196/run-latest.json"; }
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
# "name address" for every contract a broadcast record created, then "tx <hash>" for every transaction.
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
write_evaluator() {
  local rec sealed fab
  rec=$(read_record "$1")
  sealed=$(awk '$1=="SealedVM"{print $2}' <<<"$rec")
  fab=$(awk '$1=="Fab"{print $2}' <<<"$rec")
  has_code "$sealed" && has_code "$fab" || refuse "the SealedVM or Fab of $1 has no code on chain"
  [ "$(lower "$(cast call "$fab" "CIRCUITS()(address)" --rpc-url "$RPC_URL")")" = "$(lower "$CIRCUITS")" ] \
    || refuse "the Fab at $fab is not for the Covenant processor"
  set_live '.evaluator = $v' "$(jq -nc --arg c "$COMMIT" --arg s "$sealed" --arg f "$fab" --argjson t "$(txs_json "$rec")" \
    '{commit: $c, sealedVM: $s, fab: $f, txs: $t}')"
}
write_core() {
  local rec factory lens impl
  rec=$(read_record "$1")
  factory=$(awk '$1=="KernelFactory"{print $2}' <<<"$rec")
  lens=$(awk '$1=="Lens"{print $2}' <<<"$rec")
  has_code "$factory" && has_code "$lens" || refuse "the KernelFactory or Lens of $1 has no code on chain"
  impl=$(cast call "$factory" "kernelImpl()(address)" --rpc-url "$RPC_URL")
  [ "$(lower "$(cast call "$factory" "fab()(address)" --rpc-url "$RPC_URL")")" = "$(lower "$(live .evaluator.fab)")" ] \
    || refuse "the KernelFactory at $factory was built for another Fab"
  [ "$(lower "$(cast call "$lens" "FACTORY()(address)" --rpc-url "$RPC_URL")")" = "$(lower "$factory")" ] \
    || refuse "the Lens at $lens reads another factory"
  set_live '.core = $v' "$(jq -nc --arg c "$COMMIT" --arg f "$factory" --arg i "$impl" --arg l "$lens" \
    --argjson t "$(txs_json "$rec")" '{commit: $c, kernelFactory: $f, kernelImpl: $i, lens: $l, txs: $t}')"
}
write_flagship() {
  local rec kernel chip netlist_hash want_hash manifest
  rec=$(read_record "$1")
  read -r _ _ kernel chip <<<"$(awk '$1=="handover"' <<<"$rec")"
  [ -n "${chip:-}" ] || refuse "$1 holds no transfer of the chip to its kernel"
  [ "$(lower "$(cast call "$CIRCUITS" "ownerOf(uint256)(address)" "$chip" --rpc-url "$RPC_URL")")" = "$(lower "$kernel")" ] \
    || refuse "chip $chip is not held by $kernel"
  [ "$(cast call "$kernel" "chipId()(uint256)" --rpc-url "$RPC_URL")" = "$chip" ] || refuse "kernel $kernel is not bound to chip $chip"
  netlist_hash=$(cast keccak "$(cast call "$CIRCUITS" "netlist(uint256)(bytes)" "$chip" --rpc-url "$RPC_URL")")
  want_hash=$(cast keccak "$(cat chips/out/fg.hex)")
  [ "$netlist_hash" = "$want_hash" ] || refuse "chip $chip's netlist on chain is not chips/out/fg.hex"
  manifest=0x$(shasum -a 256 chips/out/fg.pins.json | awk '{print $1}')
  set_live '.flagship = $v' "$(jq -nc --arg c "$COMMIT" --argjson id "$chip" --arg k "$kernel" --arg n "$netlist_hash" \
    --arg m "$manifest" --arg p "$TANK" --argjson t "$(txs_json "$rec")" \
    '{commit: $c, chip: "Flow Governor", chipId: $id, kernel: $k, netlistKeccak256: $n, manifestHash: $m,
      allowancePayee: $p, envelope: "LaunchChip.referenceEnvelope (contracts/core/script/LaunchChip.s.sol)", txs: $t}')"
}
# The circuit NFT a tape-out transaction sent to the deployer (ERC-721 Transfer from the processor), as a decimal id.
chip_sent_by() {
  local id
  id=$(cast rpc eth_getTransactionReceipt "$1" --rpc-url "$RPC_URL" | jq -r --arg c "$(lower "$CIRCUITS")" \
    --arg to "0x000000000000000000000000$(lower "${DEPLOYER#0x}")" \
    '.logs[] | select((.address | ascii_downcase) == $c
      and .topics[0] == "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
      and (.topics[2] | ascii_downcase) == $to) | .topics[3]' | head -1)
  [ -n "$id" ] || refuse "transaction $1 sent no circuit to the deployer"
  cast to-dec "$id"
}
write_prelaunch() {
  local hashes id id512 h
  hashes=$(jq -r '.transactions[] | select((.function // "") | startswith("tapeoutChip")) | .hash' "$1")
  [ "$(wc -l <<<"$hashes" | tr -d ' ')" = "2" ] || refuse "$1 does not hold exactly two tape-outs"
  id=$(chip_sent_by "$(sed -n 1p <<<"$hashes")")
  id512=$(chip_sent_by "$(sed -n 2p <<<"$hashes")")
  for pair in "$id glutton" "$id512 glutton512"; do
    read -r h name <<<"$pair"
    [ "$(lower "$(cast call "$CIRCUITS" "ownerOf(uint256)(address)" "$h" --rpc-url "$RPC_URL")")" = "$(lower "$DEPLOYER")" ] \
      || refuse "chip $h is not held by the deployer"
    [ "$(cast keccak "$(cast call "$CIRCUITS" "netlist(uint256)(bytes)" "$h" --rpc-url "$RPC_URL")")" = \
      "$(cast keccak "$(cat "chips/cells/glutton/$name.hex")")" ] || refuse "chip $h's netlist is not chips/cells/glutton/$name.hex"
  done
  [ "$(cast call "$REGISTRY" "isInvited(address)(bool)" "$KEEPER" --rpc-url "$RPC_URL")" = "true" ] \
    || [ "$(cast call "$REGISTRY" "isTeam(address)(bool)" "$KEEPER" --rpc-url "$RPC_URL")" = "true" ] \
    || refuse "the keeper $KEEPER is not invited into the TeamRegistry"
  set_live '.prelaunch = $v' "$(jq -nc --arg c "$COMMIT" --argjson g "$id" --argjson g5 "$id512" \
    --arg m "0x$(shasum -a 256 chips/cells/glutton/glutton.pins.json | awk '{print $1}')" --arg k "$KEEPER" \
    --argjson t "$(txs_json "$(read_record "$1")")" \
    '{commit: $c, gluttonChipId: $g, glutton512ChipId: $g5, gluttonManifestHash: $m, keeperInvited: $k,
      holder: "deployer (never bound to a kernel; run with Lens.shadowChip)", txs: $t}')"
}

STEPS=(evaluator core flagship prelaunch)
step_project() { case $1 in evaluator) echo evaluator ;; *) echo core ;; esac; }
step_script() {
  case $1 in
    evaluator) echo DeployEvaluator.s.sol ;;
    core) echo DeployCore.s.sol ;;
    flagship) echo LaunchChip.s.sol ;;
    prelaunch) echo Prelaunch.s.sol ;;
  esac
}
step_done() {
  case $1 in
    evaluator) has_code "$(live .evaluator.fab)" ;;
    core) has_code "$(live .core.lens)" ;;
    flagship) has_code "$(live .flagship.kernel)" ;;
    prelaunch) [ -n "$(live .prelaunch.glutton512ChipId)" ] &&
      cast call "$CIRCUITS" "ownerOf(uint256)(address)" "$(live .prelaunch.glutton512ChipId)" --rpc-url "$RPC_URL" >/dev/null 2>&1 ;;
  esac
}
step_write() { "write_$1" "$2"; }

# ---- 4. An earlier run that stopped: a step that reached the chain but was not written down is written down now,
#      never resent; a record of a step that was never signed (stopped at the password prompt) is set aside.
for s in "${STEPS[@]}"; do
  step_done "$s" && continue
  rec=$(record_of "$(step_project "$s")" "$(step_script "$s")")
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

# ---- 5. The rehearsal, from the chain as it is now.
say "commit    $COMMIT"
say "deployer  $DEPLOYER"
say "RPC       $RPC_URL"
say "REHEARSAL on a local fork of X Layer. Nothing is sent."
REHEARSAL_OUT=$PLAN deploy/rehearse.sh
cp "$PLAN" deploy/rehearsal.json # kept for reading; this run uses $PLAN
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
  say "rehearsal only. To send the remaining steps: deploy/launch-kernel.sh --broadcast"
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
  rec=$(record_of "$(step_project "$s")" "$(step_script "$s")")
  if ! (cd "contracts/$(step_project "$s")" && forge script "script/$(step_script "$s")" "$@" --rpc-url "$RPC_URL" \
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

if ! step_done evaluator; then
  COVENANT_CIRCUITS=$CIRCUITS COVENANT_TRANSISTORS=$TRANSISTORS \
    send evaluator "step 3 of 6, SealedVM and Fab (2 transactions)" -s "run()"
  expect_same SealedVM "$(live .evaluator.sealedVM)" "$(planned .sealedVM)"
  expect_same Fab "$(live .evaluator.fab)" "$(planned .fab)"
fi
if ! step_done core; then
  COVENANT_CIRCUITS=$CIRCUITS COVENANT_FAB=$(live .evaluator.fab) COVENANT_SEALED_VM=$(live .evaluator.sealedVM) \
    send core "step 4 of 6, KernelFactory and Lens (2 transactions)" -s "run()"
  expect_same KernelFactory "$(live .core.kernelFactory)" "$(planned .kernelFactory)"
  expect_same Lens "$(live .core.lens)" "$(planned .lens)"
fi
if ! step_done flagship; then
  COVENANT_FAB=$(live .evaluator.fab) COVENANT_FACTORY=$(live .core.kernelFactory) COVENANT_LENS=$(live .core.lens) \
    NETLIST_HEX=$(cat chips/out/fg.hex) MANIFEST_HASH=0x$(shasum -a 256 chips/out/fg.pins.json | awk '{print $1}') \
    ALLOWANCE_PAYEE=$TANK \
    send flagship "step 5 of 6, the Flow Governor taped out, its kernel created, the chip handed over (3 transactions)" -s "run()"
  # Anyone may tape out on the processor, so the chip id (and with it the kernel address) can differ from the
  # rehearsal's without anything being wrong; write_flagship has checked the kernel holds the right chip.
  [ "$(live .flagship.chipId)" = "$(planned .chipId)" ] \
    || say "note: chip id $(live .flagship.chipId), the rehearsal had $(planned .chipId) (someone else taped out in between)"
fi
if ! step_done prelaunch; then
  COVENANT_FAB=$(live .evaluator.fab) COVENANT_REGISTRY=$REGISTRY KEEPER=$KEEPER \
    GLUTTON_HEX=$(cat chips/cells/glutton/glutton.hex) GLUTTON512_HEX=$(cat chips/cells/glutton/glutton512.hex) \
    GLUTTON_MANIFEST_HASH=0x$(shasum -a 256 chips/cells/glutton/glutton.pins.json | awk '{print $1}') \
    send prelaunch "step 6 of 6, the two Glutton chips taped out and the keeper invited (3 transactions)" -s "run()"
fi

echo
say "DONE. Everything is recorded in $LIVE:"
jq '{evaluator, core, flagship, prelaunch}' "$LIVE"
say "Tell Claude 'done': it checks every address on chain before the token launch."
