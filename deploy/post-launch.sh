#!/usr/bin/env bash
#
# Covenant, signing session 4: the deployer's transactions after the two IGNIX launches.
#
#   CVREF_TOKEN=0x... ARCH_TOKEN=0x... deploy/post-launch.sh               check on chain, then rehearse on a local
#                                                                         fork of X Layer. Nothing is sent and no key
#                                                                         is touched.
#   CVREF_TOKEN=0x... ARCH_TOKEN=0x... deploy/post-launch.sh --broadcast   the same, then SEND each remaining step,
#                                                                         signed by keystore 'covenant-deployer'.
#
#   1. bindV1   kernel v1 (flagship.kernel).bind(CVREF_TOKEN): the reference token, Directed, OKB quote    1 transaction
#   2. bindV2   kernel v2 (flagshipV2.kernel).bind(ARCH_TOKEN): the Architect token, Directed, USD₮0 quote  1 transaction
#   3. pull     Splitter.pull(): the processor's mint proceeds, 85% to the KeeperTank (which refunds the
#               keeper's settle gas from it) and 15% to the maintainer. Anyone may call it                1 transaction
#   4. invite   TeamRegistry.invite(architect.agentWallet), so the Architect's agent wallet can declare
#               itself                                                                                    1 transaction
#
# CVREF_TOKEN and ARCH_TOKEN are each optional: a bind whose token is not given is skipped, and so is every step
# that is done already (a bound kernel, nothing to split, a wallet invited or listed). Steps 3 and 4 need no token.
#
# forge asks for the keystore password once per step. That prompt is the last point at which the step can be
# stopped (Ctrl-C). Before anything is sent, this script checks that:
#   - this script and contracts/core/script/PostLaunch.s.sol are exactly HEAD, and HEAD is on origin/main;
#   - no .env file and no FOUNDRY_* / DAPP_* / ETH_* / CAST_* / TEMPO_* variable can change what forge runs or sends
#     (gas price included; ETH_RPC_URL is ignored, every command names its RPC);
#   - for each bind, on chain: IgnixManager.vaultOf(token) is a vault whose RECIPIENT() is the kernel, whose TOKEN()
#     is the token and whose QUOTE() is native OKB (v1) or USD₮0 (v2); IGNIX's curve record names the same quote,
#     the kernel's envelope launcher (the deployer) as the token's creator, and a non-zero tax; the kernel was
#     created by the KernelFactory recorded in deployments/xlayer.json, holds its chip and is not bound yet;
#   - every call succeeds as an eth_call from the deployer on the chain as it is now;
#   - the same steps, run by this script on a local fork from the deployer (impersonated, in a scratch copy of
#     contracts/core), succeed and leave the expected state; on that fork the keeper and the Architect wallet
#     also declare themselves and the KeeperTank refunds a settle of each bound kernel;
#   - the deployer's nonce is the one the rehearsal started from (one more after each step sent).
# After each step its result is read back from the chain and written to deployments/xlayer.json: .reference and
# .architectToken {token, vault, kernel, bindTx, ...}, .splitterPulls [...], .registryInvites [...].
# After an interruption, run the same command again: a step that reached the chain is recorded from the chain and
# never sent again; forge's record of a step that was never signed (stopped at the password prompt) is removed; a
# step that was signed but did not succeed, or is not on chain yet, stops everything.
#
# At the end it prints what only other wallets can do: the keeper's and the Architect wallet's declarations, and
# the keeper service's settings.

set -euo pipefail

DEPLOYER=0x84cE7bAe1b788C7aD985D57721cA428b401aE34D
ACCOUNT=covenant-deployer
MANAGER=0x96B51c57e5346D0C0198899243cf851D1E23C309
USDT0=0x779Ded0c9e1022225f8E0630b35a9b54bE713736
ZERO=0x0000000000000000000000000000000000000000
KEEPER_ROLE="keeper"
ARCHITECT_ROLE="architect (OKX.AI agent 14683)"
RPC_URL=${XLAYER_RPC_URL:-https://rpc.xlayer.tech}
USAGE="usage: [CVREF_TOKEN=0x...] [ARCH_TOKEN=0x...] deploy/post-launch.sh [--broadcast]"
# forge sets each transaction's gas limit to its simulated gas times this percentage. Splitter.pull() needs more than
# it uses: it reverts unless 90,000 gas are left before the maintainer's share is pushed (eth_estimateGas: about
# 156,000 for a simulated use of 96,000). Gas that is not used is not paid.
FORGE_GAS=(--gas-estimate-multiplier 300)

refuse() {
  echo "post-launch.sh: REFUSED: $*" >&2
  exit 1
}
say() { echo "post-launch.sh: $*"; }

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
PROJECT=contracts/core
SCRIPT=script/PostLaunch.s.sol
WORK=$(mktemp -d "${TMPDIR:-/tmp}/covenant-post-launch.XXXXXX")
ANVIL=
cleanup() {
  [ -z "$ANVIL" ] || kill "$ANVIL" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- 1. What runs is the commit, and the commit is public.
SOURCES=(deploy/post-launch.sh "$PROJECT/$SCRIPT" "$PROJECT/foundry.toml")
for f in "${SOURCES[@]}"; do
  git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || refuse "$f is not tracked by git. Commit it first"
done
changes=$(git status --porcelain -- "${SOURCES[@]}")
[ -z "$changes" ] || refuse "these files differ from HEAD. Commit them first:"$'\n'"$changes"
git fetch --quiet origin main || refuse "could not fetch origin/main"
git merge-base --is-ancestor HEAD origin/main || refuse "HEAD is not on origin/main. Push first"
COMMIT=$(git rev-parse HEAD)

# ---- 2. Nothing outside the commit changes what forge runs.
for envfile in .env "$PROJECT/.env"; do
  [ ! -e "$envfile" ] || refuse "a .env file is present ($envfile): forge would read it. Move it away first"
done
if env | grep -qE '^(FOUNDRY_|DAPP_)'; then
  refuse "FOUNDRY_* or DAPP_* variables are set in this shell: $(env | grep -E '^(FOUNDRY_|DAPP_)' | cut -d= -f1 | tr '\n' ' ')"
fi
# forge and cast also read ETH_* / CAST_* / TEMPO_* variables: gas price and priority fee (ETH_GAS_PRICE reaches the
# real transactions), gas limit, keystore and password file, sender, timeouts, async sends. Every command here names
# its RPC, so ETH_RPC_URL and ETH_RPC_TIMEOUT change nothing; any other one is refused.
wallet_env=$(env | grep -E '^(ETH_|CAST_|TEMPO_)' | cut -d= -f1 | grep -vxE 'ETH_RPC_URL|ETH_RPC_TIMEOUT' | tr '\n' ' ' || true)
[ -z "$wallet_env" ] || refuse "variables that forge or cast read are set in this shell: ${wallet_env}(unset them first)"
[ -f "$PROJECT/lib/forge-std/src/Script.sol" ] || refuse "$PROJECT/lib/forge-std is missing"

# ---- 3. The deployment, and the inputs.
[ -f "$LIVE" ] || refuse "$LIVE is missing"
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
same() { [ "$(lower "$1")" = "$(lower "$2")" ]; }
live() { jq -r "$1 // empty" "$LIVE"; }
is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
SPLITTER=$(live .issuance.splitter)
CIRCUITS=$(live .issuance.circuits)
TRANSISTORS=$(live .issuance.transistors)
TANK=$(live .issuance.keeperTank)
REGISTRY=$(live .issuance.teamRegistry)
KEEPER=$(live .keeper)
AGENT=$(live .architect.agentWallet)
K1=$(live .flagship.kernel)
CHIP1=$(live .flagship.chipId)
F1=$(live .core.kernelFactory)
K2=$(live .flagshipV2.kernel)
CHIP2=$(live .flagshipV2.chipId)
F2=$(live .coreV2.kernelFactory)
for v in SPLITTER CIRCUITS TRANSISTORS TANK REGISTRY KEEPER AGENT K1 F1 K2 F2; do
  is_address "${!v}" || refuse "$LIVE has no address for $v ('${!v}')"
done
[[ "$CHIP1" =~ ^[0-9]+$ && "$CHIP2" =~ ^[0-9]+$ ]] || refuse "$LIVE has no chip id for flagship or flagshipV2"
same "$(live .coreV2.quote)" "$USDT0" || refuse "$LIVE: coreV2.quote is not USD₮0"
same "$(live .deployer)" "$DEPLOYER" || refuse "$LIVE names another deployer"

CVREF=${CVREF_TOKEN:-}
ARCH=${ARCH_TOKEN:-}
[ -z "$CVREF" ] || is_address "$CVREF" || refuse "CVREF_TOKEN '$CVREF' is not an address"
[ -z "$ARCH" ] || is_address "$ARCH" || refuse "ARCH_TOKEN '$ARCH' is not an address"
[ -z "$CVREF" ] || [ -z "$ARCH" ] || ! same "$CVREF" "$ARCH" || refuse "CVREF_TOKEN and ARCH_TOKEN are the same token"
[ -z "$CVREF" ] || [ -z "$(live .reference.token)" ] || same "$CVREF" "$(live .reference.token)" \
  || refuse "$LIVE records the reference token $(live .reference.token), not CVREF_TOKEN $CVREF"
[ -z "$ARCH" ] || [ -z "$(live .architectToken.token)" ] || same "$ARCH" "$(live .architectToken.token)" \
  || refuse "$LIVE records the Architect token $(live .architectToken.token), not ARCH_TOKEN $ARCH"
role_len=$(printf '%s' "$ARCHITECT_ROLE" | wc -c | tr -d ' ')
[ "$role_len" -le 64 ] || refuse "ARCHITECT_ROLE is $role_len bytes; TeamRegistry accepts at most 64"

# ---- chain reads. R is the node every helper below talks to: the chain, or the rehearsal's fork.
R=$RPC_URL
c() { cast call "$@" --rpc-url "$R"; }
first() { awk '{print $1}'; }
has_code() { [ -n "$1" ] && [ "$(cast code "$1" --rpc-url "$R")" != "0x" ]; }
nonce() { cast nonce "$DEPLOYER" --rpc-url "$R"; }
receipt() { cast rpc eth_getTransactionReceipt "$1" --rpc-url "$R"; }
okb() { python3 -c "print(f'{$1 / 10**18:.6f}')"; }
[ "$(cast chain-id --rpc-url "$RPC_URL")" = "196" ] || refuse "$RPC_URL is not X Layer (chain 196)"

TOPIC_BOUND=$(cast keccak "Bound(address,address,uint40)")
TOPIC_PULLED=$(cast keccak "Pulled(uint256,uint256)")
TOPIC_CREDITED=$(cast keccak "MaintainerCredited(uint256)")
TOPIC_INVITED=$(cast keccak "Invited(address,address)")
TOPIC_REFUNDED=$(cast keccak "Refunded(uint256,address,address,uint256,uint256)")
ENVELOPE_T="(address,uint32,address,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,bool,address)"
word() { printf '0x%064s' "$(lower "${1#0x}")" | tr ' ' 0; } # an address as a 32-byte log topic

STEPS=(bindV1 bindV2 pull invite)
kernel_of() { case $1 in bindV1) echo "$K1" ;; bindV2) echo "$K2" ;; esac; }
token_of() { case $1 in bindV1) echo "$CVREF" ;; bindV2) echo "$ARCH" ;; esac; }
key_of() { case $1 in bindV1) echo .reference ;; bindV2) echo .architectToken ;; esac; }
input_of() { case $1 in bindV1) echo CVREF_TOKEN ;; bindV2) echo ARCH_TOKEN ;; esac; }
what_of() {
  case $1 in
    bindV1) echo "bind kernel v1 $K1 to the reference token $CVREF" ;;
    bindV2) echo "bind kernel v2 $K2 to the Architect token $ARCH" ;;
    pull) echo "Splitter.pull(): $(okb "$(pull_amount)") OKB of mint proceeds, 85% to the KeeperTank, 15% to the maintainer" ;;
    invite) echo "TeamRegistry.invite($AGENT), the Architect's agent wallet" ;;
  esac
}
factory_of() { case $1 in bindV1) echo "$F1" ;; bindV2) echo "$F2" ;; esac; }
target_of() { case $1 in bindV1 | bindV2) kernel_of "$1" ;; pull) echo "$SPLITTER" ;; invite) echo "$REGISTRY" ;; esac; }
function_of() { case $1 in bindV1 | bindV2) echo "bind(address)" ;; pull) echo "pull()" ;; invite) echo "invite(address)" ;; esac; }
calldata_of() {
  case $1 in
    bindV1 | bindV2) cast calldata "bind(address)" "$(token_of "$1")" ;;
    pull) cast calldata "pull()" ;;
    invite) cast calldata "invite(address)" "$AGENT" ;;
  esac
}
sig_of() {
  case $1 in
    bindV1 | bindV2) echo "$1(address,address)" ;;
    pull) echo "pull(address)" ;;
    invite) echo "invite(address,address)" ;;
  esac
}
args_of() {
  case $1 in
    bindV1 | bindV2) echo "$(kernel_of "$1") $(token_of "$1")" ;;
    pull) echo "$SPLITTER" ;;
    invite) echo "$REGISTRY $AGENT" ;;
  esac
}
record_of() { echo "$1/broadcast/PostLaunch.s.sol/196/$2-latest.json"; } # project dir, step

bound_to() { c "$1" "token()(address)"; }
# OKB that pull() would split now: what TapeOut owes the Splitter plus what it holds, less the maintainer's credit.
pull_amount() {
  python3 -c "print(max(0, $(c "$TRANSISTORS" "owed(address)(uint256)" "$SPLITTER" | first) + $(cast balance "$SPLITTER" --rpc-url "$R") - $(c "$SPLITTER" "maintainerOwed()(uint256)" | first)))"
}
listed_or_invited() { [ "$(c "$REGISTRY" "isInvited(address)(bool)" "$1")" = "true" ] || [ "$(c "$REGISTRY" "isTeam(address)(bool)" "$1")" = "true" ]; }

# The explicit preconditions of bind (Kernel.bind's BindCheck codes in brackets), stricter where it matters: the
# token's creator must be the launcher itself, although the launcher may also bind a token another wallet created.
check_bind() { # step
  local s=$1 k t f chip quote_want quote_name vault env launcher words creator taxb taxs curve_quote name symbol
  k=$(kernel_of "$s")
  t=$(token_of "$s")
  case $s in
    bindV1) f=$F1 chip=$CHIP1 quote_want=$ZERO quote_name="native OKB" ;;
    bindV2) f=$F2 chip=$CHIP2 quote_want=$USDT0 quote_name="USD₮0" ;;
  esac
  has_code "$k" || refuse "$s: kernel $k has no code"
  has_code "$t" || refuse "$s: token $t has no code"
  [ "$(c "$f" "isKernel(address)(bool)" "$k")" = "true" ] || refuse "$s: $k was not created by the KernelFactory $f"
  same "$(c "$f" "manager()(address)")" "$MANAGER" || refuse "$s: the KernelFactory $f is wired to another IgnixManager"
  [ "$(c "$k" "chipId()(uint256)" | first)" = "$chip" ] || refuse "$s: kernel $k is not for chip $chip"
  same "$(c "$CIRCUITS" "ownerOf(uint256)(address)" "$chip")" "$k" || refuse "$s: kernel $k does not hold its chip $chip [7]"
  [ "$s" = bindV1 ] || same "$(c "$k" "quote()(address)")" "$USDT0" || refuse "$s: kernel $k does not quote in USD₮0"
  same "$(bound_to "$k")" "$ZERO" || refuse "$s: kernel $k is bound already, to $(bound_to "$k")"
  vault=$(c "$MANAGER" "vaultOf(address)(address)" "$t")
  ! same "$vault" "$ZERO" || refuse "$s: IGNIX has no vault for $t: it is not an IGNIX token [1]"
  same "$(c "$vault" "RECIPIENT()(address)")" "$k" \
    || refuse "$s: the vault $vault of $t pays its tax to $(c "$vault" "RECIPIENT()(address)"), not to kernel $k [2]"
  same "$(c "$vault" "TOKEN()(address)")" "$t" || refuse "$s: the vault $vault is for $(c "$vault" "TOKEN()(address)"), not $t [3]"
  same "$(c "$vault" "QUOTE()(address)")" "$quote_want" \
    || refuse "$s: the vault $vault is quoted in $(c "$vault" "QUOTE()(address)"), not $quote_name [4]"
  env=$(c "$k" "envelope()($ENVELOPE_T)" | tr -d '() ')
  launcher=$(cut -d, -f1 <<<"$env")
  same "$launcher" "$DEPLOYER" || refuse "$s: kernel $k's envelope launcher is $launcher, not the deployer"
  words=$(c "$MANAGER" "tokens(address)" "$t")
  [ "${#words}" -ge $((2 + 1024)) ] || refuse "$s: IGNIX's curve record of $t is shorter than 512 bytes [5]"
  read -r creator taxb taxs curve_quote < <(python3 - "$words" <<'EOF'
import sys
h = sys.argv[1][2:]
w = [int(h[64 * i:64 * i + 64], 16) for i in range(16)]
print("0x%040x" % w[0], w[3], w[4], "0x%040x" % w[5])
EOF
)
  same "$creator" "$launcher" || refuse "$s: $t was created by $creator, not by the kernel's envelope launcher $launcher [5]"
  same "$curve_quote" "$quote_want" || refuse "$s: IGNIX's curve of $t trades in $curve_quote, not $quote_name [4]"
  [ "$taxb" != "0" ] || [ "$taxs" != "0" ] || refuse "$s: $t has no tax [6]"
  name=$(c "$t" "name()(string)" 2>/dev/null || echo '"?"')
  symbol=$(c "$t" "symbol()(string)" 2>/dev/null || echo '"?"')
  say "$s: token $t $name ($symbol), created by the launcher; vault $vault pays kernel $k in $quote_name; tax $taxb / $taxs bps; kernel holds chip $chip, not bound"
}
# Every call of the step as an eth_call from the deployer, on the node R.
simulate() { # step
  local out
  out=$(cast call --from "$DEPLOYER" "$(target_of "$1")" --data "$(calldata_of "$1")" --rpc-url "$R" 2>&1) \
    || refuse "$1: the call reverts as an eth_call from the deployer: $out"
}
# Which steps are still to do on node R, in order. Writes nothing; refuses on a kernel bound to another token.
todo() {
  local s k t b steps=()
  for s in "${STEPS[@]}"; do
    case $s in
      bindV1 | bindV2)
        k=$(kernel_of "$s")
        t=$(token_of "$s")
        b=$(bound_to "$k")
        if [ -z "$t" ]; then
          continue
        elif same "$b" "$t"; then
          continue
        elif ! same "$b" "$ZERO"; then
          refuse "$s: kernel $k is bound to $b, not to $t"
        fi
        ;;
      pull) [ "$(pull_amount)" != "0" ] || continue ;;
      invite) ! listed_or_invited "$AGENT" || continue ;;
    esac
    steps+=("$s")
  done
  echo "${steps[*]:-}"
}

# ---- forge's records and what reached the chain
# What reached the chain from a broadcast record, asked of the node itself. forge writes the record BEFORE it asks
# for the keystore password, so the record alone proves nothing. Prints one word:
#   unsigned    no transaction in it has a hash: nothing was signed, so nothing can have been sent
#   complete    every transaction has a hash, and the node holds a successful receipt for each
#   incomplete  anything else: a transaction failed, or one is signed but not on chain (pending or dropped)
record_state() {
  local n=0 signed=0 ok=0 h status
  for h in $(jq -r '.transactions[] | .hash // "none"' "$1"); do
    n=$((n + 1))
    [ "$h" = "none" ] && continue
    signed=$((signed + 1))
    status=$(receipt "$h" | jq -r 'if . == null then "none" else .status end')
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
# Removes an unsigned record, and the timestamped copy forge wrote next to it (same bytes).
drop_unsigned() {
  local dir copy
  dir=$(dirname "$1")
  for copy in "$dir"/run-[0-9]*.json "$dir/$2"-[0-9]*.json; do
    [ -f "$copy" ] && cmp -s "$copy" "$1" && rm -f "$copy"
  done
  rm -f "$1"
}
# A record of step $2 holds one transaction, from the deployer to the step's contract, calling the step's function.
record_is_step() { # record, step
  local want_to sel
  want_to=$(target_of "$2")
  sel=$(cast sig "$(function_of "$2")")
  python3 - "$1" "$DEPLOYER" "$want_to" "$sel" <<'EOF' || refuse "$1 is not a record of step '$2' (one transaction from the deployer to $want_to); look at it before anything else"
import json, sys
d = json.load(open(sys.argv[1]))
t = d["transactions"]
ok = len(t) == 1 and t[0]["transaction"]["from"].lower() == sys.argv[2].lower() \
    and (t[0]["transaction"].get("to") or "").lower() == sys.argv[3].lower() \
    and (t[0]["transaction"].get("input") or "").lower().startswith(sys.argv[4].lower())
sys.exit(0 if ok else 1)
EOF
}
recorded_tx() { # step, hash: is the transaction written down already?
  case $1 in
    bindV1 | bindV2) same "$(live "$(key_of "$1").bindTx")" "$2" ;;
    pull) jq -e --arg h "$(lower "$2")" '(.splitterPulls // []) | any(.tx | ascii_downcase == $h)' "$LIVE" >/dev/null ;;
    invite) jq -e --arg h "$(lower "$2")" '(.registryInvites // []) | any(.tx | ascii_downcase == $h)' "$LIVE" >/dev/null ;;
  esac
}
set_live() { # jq filter with $v bound to a JSON value
  local tmp
  tmp=$(mktemp)
  jq --argjson v "$2" "$1" "$LIVE" >"$tmp" && mv "$tmp" "$LIVE"
}
# The transaction that bound kernel $1, found from its bindTime: the first block at or after that time, then the
# kernel's Bound log within the next 100 blocks (the public RPC's eth_getLogs limit).
locate_bind_tx() {
  local k=$1 t lo hi mid ts h latest to
  t=$(c "$k" "bindTime()(uint40)" | first)
  latest=$(cast block-number --rpc-url "$R")
  lo=1
  hi=$latest
  while [ "$lo" -lt "$hi" ]; do
    mid=$(((lo + hi) / 2))
    ts=$(cast block "$mid" --field timestamp --rpc-url "$R")
    if [ "$ts" -lt "$t" ]; then lo=$((mid + 1)); else hi=$mid; fi
  done
  to=$((lo + 99))
  [ "$to" -le "$latest" ] || to=$latest
  h=$(cast rpc eth_getLogs "{\"address\":\"$k\",\"topics\":[\"$TOPIC_BOUND\"],\"fromBlock\":\"$(cast to-hex "$lo")\",\"toBlock\":\"$(cast to-hex "$to")\"}" \
    --rpc-url "$R" | jq -r '.[0].transactionHash // empty')
  [ -n "$h" ] || refuse "kernel $k is bound (bindTime $t) but its Bound log was not found from block $lo on; ask Claude to look at it"
  echo "$h"
}

# ---- writing down what reached the chain, after reading it back
write_bind() { # step, transaction hash
  local s=$1 h=$2 k key token vault rc blk from bt name symbol creator chip quote
  k=$(kernel_of "$s")
  key=$(key_of "$s")
  ! recorded_tx "$s" "$h" || return 0
  token=$(bound_to "$k")
  ! same "$token" "$ZERO" || refuse "$s: transaction $h reached the chain but kernel $k is not bound"
  vault=$(c "$k" "vault()(address)")
  rc=$(receipt "$h")
  [ "$(jq -r .status <<<"$rc")" = "0x1" ] || refuse "$s: transaction $h did not succeed"
  jq -e --arg k "$(lower "$k")" --arg tb "$TOPIC_BOUND" --arg tt "$(word "$token")" \
    '.logs | any((.address | ascii_downcase) == $k and .topics[0] == $tb and (.topics[1] | ascii_downcase) == $tt)' <<<"$rc" >/dev/null \
    || refuse "$s: transaction $h holds no Bound log of kernel $k for $token"
  same "$(c "$(factory_of "$s")" "kernelOf(address)(address)" "$token")" "$k" \
    || refuse "$s: the KernelFactory does not report kernel $k for $token"
  blk=$(cast to-dec "$(jq -r .blockNumber <<<"$rc")")
  from=$(jq -r .from <<<"$rc")
  bt=$(c "$k" "bindTime()(uint40)" | first)
  name=$(c "$token" "name()(string)" 2>/dev/null | sed 's/^"//; s/"$//' || true)
  symbol=$(c "$token" "symbol()(string)" 2>/dev/null | sed 's/^"//; s/"$//' || true)
  creator=$(python3 -c "import sys; print('0x' + sys.argv[1][2 + 24:2 + 64])" "$(c "$MANAGER" "tokens(address)" "$token")")
  chip=$(c "$k" "chipId()(uint256)" | first)
  quote=$(c "$vault" "QUOTE()(address)")
  set_live "$key = \$v" "$(jq -nc --arg t "$token" --arg n "$name" --arg sy "$symbol" --arg v "$vault" --arg k "$k" \
    --argjson chip "$chip" --arg q "$quote" --arg cr "$(cast to-check-sum-address "$creator")" --arg h "$h" \
    --argjson b "$blk" --argjson bt "$bt" --arg from "$(cast to-check-sum-address "$from")" --arg c "$COMMIT" \
    '{token: $t, name: $n, symbol: $sy, vault: $v, kernel: $k, chipId: $chip, quote: $q, creator: $cr,
      bindTx: $h, bindBlock: $b, bindTime: $bt, boundBy: $from, commit: $c}')"
  say "$s: recorded in $LIVE as $key (bound in block $blk by $from)"
}
write_pull() { # transaction hash
  local h=$1 rc blk to_tank to_maint credited
  ! recorded_tx pull "$h" || return 0
  rc=$(receipt "$h")
  [ "$(jq -r .status <<<"$rc")" = "0x1" ] || refuse "pull: transaction $h did not succeed"
  same "$(jq -r .to <<<"$rc")" "$SPLITTER" || refuse "pull: transaction $h is not a call to the Splitter"
  # Pulled(toTank, toMaintainer); a pull that found nothing to split emits nothing
  read -r to_tank to_maint < <(jq -r --arg s "$(lower "$SPLITTER")" --arg tp "$TOPIC_PULLED" \
    '[.logs[] | select((.address | ascii_downcase) == $s and .topics[0] == $tp) | .data][0] // ""' <<<"$rc" \
    | python3 -c "import sys; d = sys.stdin.read().strip()[2:]; print(int(d[:64], 16), int(d[64:128], 16)) if len(d) >= 128 else print(0, 0)")
  credited=$(jq -r --arg s "$(lower "$SPLITTER")" --arg tc "$TOPIC_CREDITED" \
    '.logs | any((.address | ascii_downcase) == $s and .topics[0] == $tc)' <<<"$rc")
  blk=$(cast to-dec "$(jq -r .blockNumber <<<"$rc")")
  set_live '.splitterPulls = ((.splitterPulls // []) + [$v])' "$(jq -nc --arg h "$h" --argjson b "$blk" \
    --arg t "$to_tank" --arg m "$to_maint" --argjson cr "$credited" --arg c "$COMMIT" \
    '{tx: $h, block: $b, toTankWei: $t, toMaintainerWei: $m, maintainerCredited: $cr, commit: $c}')"
  say "pull: recorded in $LIVE under .splitterPulls ($(okb "$to_tank") OKB to the KeeperTank, $(okb "$to_maint") OKB to the maintainer)"
}
write_invite() { # transaction hash
  local h=$1 rc blk
  ! recorded_tx invite "$h" || return 0
  rc=$(receipt "$h")
  [ "$(jq -r .status <<<"$rc")" = "0x1" ] || refuse "invite: transaction $h did not succeed"
  jq -e --arg r "$(lower "$REGISTRY")" --arg ti "$TOPIC_INVITED" --arg w "$(word "$AGENT")" --arg by "$(word "$DEPLOYER")" \
    '.logs | any((.address | ascii_downcase) == $r and .topics[0] == $ti and (.topics[1] | ascii_downcase) == $w
      and (.topics[2] | ascii_downcase) == $by)' <<<"$rc" >/dev/null || refuse "invite: transaction $h holds no Invited log for $AGENT"
  blk=$(cast to-dec "$(jq -r .blockNumber <<<"$rc")")
  set_live '.registryInvites = ((.registryInvites // []) + [$v])' "$(jq -nc --arg w "$(cast to-check-sum-address "$AGENT")" --arg by "$DEPLOYER" \
    --arg h "$h" --argjson b "$blk" --arg c "$COMMIT" '{wallet: $w, by: $by, tx: $h, block: $b, commit: $c}')"
  say "invite: recorded in $LIVE under .registryInvites"
}
write_step() { # step, transaction hash
  case $1 in
    bindV1 | bindV2) write_bind "$1" "$2" ;;
    pull) write_pull "$2" ;;
    invite) write_invite "$2" ;;
  esac
}
# The state a step leaves, on node R.
verify_step() { # step
  case $1 in
    bindV1 | bindV2) same "$(bound_to "$(kernel_of "$1")")" "$(token_of "$1")" || refuse "$1: the kernel is not bound to the token afterwards" ;;
    pull) [ "$(pull_amount)" = "0" ] || refuse "pull: OKB is still left to split afterwards" ;;
    invite) listed_or_invited "$AGENT" || refuse "invite: $AGENT is not invited afterwards" ;;
  esac
}

# ---- 4. An earlier run that stopped. A step that reached the chain but was not written down is written down now
#      and never resent; a record of a step that was never signed is removed; anything else stops here.
for s in "${STEPS[@]}"; do
  rec=$(record_of "$PROJECT" "$s")
  [ -f "$rec" ] || continue
  case $(record_state "$rec") in
    unsigned)
      say "step '$s': an earlier run stopped before signing (for example a mistyped password). Nothing of it was sent."
      say "removing forge's unsigned record $rec"
      drop_unsigned "$rec" "$s"
      ;;
    complete)
      record_is_step "$rec" "$s"
      h=$(jq -r '.transactions[0].hash' "$rec")
      if ! recorded_tx "$s" "$h"; then
        say "step '$s' reached the chain in an earlier run ($h); recording it from the chain"
        write_step "$s" "$h"
      fi
      ;;
    *)
      refuse "$rec: step '$s' was signed but did not succeed, or is not on chain yet (pending or dropped). Nothing is sent; ask Claude to look at it"
      ;;
  esac
done
# A kernel bound without a record of this script (anyone may bind a token its launcher created): written down from
# the chain.
for s in bindV1 bindV2; do
  k=$(kernel_of "$s")
  if ! same "$(bound_to "$k")" "$ZERO" && [ -z "$(live "$(key_of "$s").bindTx")" ]; then
    say "step '$s': kernel $k is bound to $(bound_to "$k") on chain; finding the transaction"
    h=$(locate_bind_tx "$k")
    write_step "$s" "$h"
  fi
done

# ---- 5. What is left, checked on the chain as it is now.
say "commit    $COMMIT"
say "deployer  $DEPLOYER (nonce $(nonce), $(cast balance $DEPLOYER --rpc-url "$R" --ether) OKB)"
say "RPC       $RPC_URL"
# (assigned first: a refusal inside a command substitution must stop this script)
todo_now=$(todo)
read -r -a TODO <<<"$todo_now"
for s in "${STEPS[@]}"; do
  [[ " ${TODO[*]:-} " != *" $s "* ]] || continue
  case $s in
    bindV1 | bindV2)
      if [ -z "$(token_of "$s")" ] && same "$(bound_to "$(kernel_of "$s")")" "$ZERO"; then
        say "$s: skipped, $(input_of "$s") is not given"
      else
        say "$s: done, kernel $(kernel_of "$s") is bound to $(bound_to "$(kernel_of "$s")")"
      fi
      ;;
    pull) say "pull: done, the Splitter has nothing to split" ;;
    invite) say "invite: done, $AGENT is invited or listed" ;;
  esac
done
for s in "${TODO[@]:+${TODO[@]}}"; do
  case $s in bindV1 | bindV2) check_bind "$s" ;; esac
  simulate "$s"
  say "$s: to send: $(what_of "$s")"
done

# ---- follow-ups that only other wallets can do, printed at the end of every run that has nothing left to send
followups() {
  local kernels=() decl_agent bal_agent bal_keeper
  echo
  say "Next, from wallets this script does not use. You type every password and key yourself; never paste a key into a chat."
  if [ "$(c "$REGISTRY" "isTeam(address)(bool)" "$KEEPER")" != "true" ]; then
    bal_keeper=$(okb "$(cast balance "$KEEPER" --rpc-url "$R")")
    echo
    echo "  1. The keeper declares itself in the TeamRegistry (it is invited; role \"$KEEPER_ROLE\"). In your own terminal:"
    echo "       cast wallet import covenant-keeper --interactive     # once: paste the keeper's private key, choose a password"
    echo "       cast wallet address --account covenant-keeper        # must print $KEEPER"
    echo "       cast send $REGISTRY \"declare(string)\" $KEEPER_ROLE --rpc-url https://rpc.xlayer.tech --account covenant-keeper"
    echo "     The keeper holds $bal_keeper OKB; the declaration is about 100,000 gas (about 0.000002 OKB at 0.02 gwei)."
    echo "     Do it before the keeper service sends its first settle (docs/WALLETS.md)."
  else
    say "the keeper $KEEPER is declared already"
  fi
  if [ "$(c "$REGISTRY" "isTeam(address)(bool)" "$AGENT")" != "true" ]; then
    decl_agent=$(cast calldata "declare(string)" "$ARCHITECT_ROLE")
    bal_agent=$(okb "$(cast balance "$AGENT" --rpc-url "$R")")
    echo
    echo "  2. The Architect's agent wallet declares itself (role \"$ARCHITECT_ROLE\"). It is an OKX Agentic Wallet, so"
    echo "     through onchainos, logged in to that wallet:"
    echo "       onchainos wallet contract-call --chain 196 --from $AGENT \\"
    echo "         --to $REGISTRY \\"
    echo "         --input-data $decl_agent"
    echo "     That calldata is TeamRegistry.declare(\"$ARCHITECT_ROLE\"). The wallet pays the gas in OKB and holds"
    echo "     $bal_agent OKB: send it about 0.0001 OKB first (the call is about 100,000 gas, 0.000002 OKB at 0.02 gwei;"
    echo "     more through the wallet's smart-account path). If onchainos asks for a confirmation, read it, and add"
    echo "     --force only if it describes this call."
    [ "$(c "$REGISTRY" "isInvited(address)(bool)" "$AGENT")" = "true" ] \
      || echo "     (It is not invited yet: the invite step above must succeed first.)"
    echo "     Check: cast call $REGISTRY \"isTeam(address)(bool)\" $AGENT --rpc-url https://rpc.xlayer.tech"
  else
    say "the Architect wallet $AGENT is declared already"
  fi
  same "$(bound_to "$K1")" "$ZERO" || kernels+=("$K1")
  same "$(bound_to "$K2")" "$ZERO" || kernels+=("$K2")
  echo
  if [ "${#kernels[@]}" -gt 0 ]; then
    echo "  3. The keeper service (Railway, service covenant-keeper; services/keeper/README.md, section 3):"
    echo "       KERNELS=$(IFS=,; echo "${kernels[*]}")"
    echo "       TANK=$TANK"
    echo "       KEEPER_ADDRESS=$KEEPER"
    echo "       RAILWAY_DOCKERFILE_PATH=services/keeper/Dockerfile"
    echo "     KEEPER_PRIVATE_KEY: you paste it yourself, and seal it:"
    echo "       railway variable set --service covenant-keeper --skip-deploys --stdin KEEPER_PRIVATE_KEY"
    echo "     Dry run first: (cd services/keeper && KERNELS=$(IFS=,; echo "${kernels[*]}") TANK=$TANK KEEPER_ADDRESS=$KEEPER node src/index.ts --once --dry-run)"
    [ "${#kernels[@]}" -eq 2 ] || echo "     Only the bound kernel is listed: add the other one when it is bound (a settle of an unbound kernel reverts)."
    echo "     KeeperTank: $(cast balance "$TANK" --rpc-url "$R" --ether) OKB."
  else
    echo "  3. The keeper service: no kernel is bound yet, so there is nothing for it to settle."
  fi
  if ! same "$(bound_to "$K2")" "$ZERO"; then
    echo
    echo "  Keep the Architect's PAY_TO on the agent wallet until every condition of contracts/core-v2/NOTES.md section 9,"
    echo "  step 6 holds (node tools/launch-check/payto-check.ts --deployment $LIVE --pay-to $K2)."
  fi
}

if [ "${#TODO[@]}" -eq 0 ] || [ -z "${TODO[0]:-}" ]; then
  say "nothing to send."
  followups
  exit 0
fi

# ---- 6. The rehearsal: the same steps, run by this script on a local fork of the chain as it is now, from the
#      deployer (impersonated), in a scratch copy of contracts/core (no broadcast record can land in the repository).
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
FORK=http://127.0.0.1:$PORT
! cast chain-id --rpc-url "$FORK" >/dev/null 2>&1 || refuse "something already answers on $FORK"
mkdir -p "$WORK/contracts"
for p in core evaluator vendor; do # core's test tree imports the other two; forge resolves the whole project
  rsync -a --exclude 'broadcast/' "contracts/$p" "$WORK/contracts/"
done
anvil --fork-url "$RPC_URL" --port "$PORT" --auto-impersonate --silent >"$WORK/anvil.log" 2>&1 &
ANVIL=$!
for _ in $(seq 1 60); do
  kill -0 "$ANVIL" 2>/dev/null || refuse "the rehearsal's anvil exited: $(tail -5 "$WORK/anvil.log")"
  cast chain-id --rpc-url "$FORK" >/dev/null 2>&1 && break
  sleep 1
done
kill -0 "$ANVIL" 2>/dev/null || refuse "the rehearsal's anvil is not running"
[ "$(cast chain-id --rpc-url "$FORK" 2>/dev/null)" = "196" ] || refuse "the rehearsal fork did not start"
cast rpc anvil_nodeInfo --rpc-url "$FORK" >/dev/null 2>&1 || refuse "$FORK is not an anvil node"
R=$FORK
echo
say "REHEARSAL on a local fork of X Layer at block $(cast block-number --rpc-url "$R"). Nothing is sent to X Layer."
FORK_FEES=0
todo_fork=$(todo)
read -r -a FORK_TODO <<<"$todo_fork"
[ "${FORK_TODO[*]:-}" = "${TODO[*]}" ] || refuse "the fork has other steps to do (${FORK_TODO[*]:-none}) than the chain (${TODO[*]})"
PLAN_NONCE=$(nonce)
for s in "${TODO[@]}"; do
  case $s in bindV1 | bindV2) check_bind "$s" >/dev/null ;; esac
  simulate "$s"
  # shellcheck disable=SC2046 # the arguments are addresses
  (cd "$WORK/contracts/core" && forge script "$SCRIPT:PostLaunch" -s "$(sig_of "$s")" $(args_of "$s") "${FORGE_GAS[@]}" --rpc-url "$R" \
    --sender "$DEPLOYER" --unlocked --broadcast --slow >"$WORK/forge-$s.log" 2>&1) \
    || { tail -30 "$WORK/forge-$s.log" >&2; refuse "the rehearsal of step '$s' failed (forge output above)"; }
  rec=$(record_of "$WORK/contracts/core" "$s")
  [ "$(record_state "$rec")" = "complete" ] || refuse "the rehearsal of step '$s' left no successful transaction"
  record_is_step "$rec" "$s"
  verify_step "$s"
  h=$(jq -r '.transactions[0].hash' "$rec")
  fee=$(receipt "$h" | jq -r '[.gasUsed, .effectiveGasPrice] | join(" ")' | python3 -c "import sys; g, p = sys.stdin.read().split(); print(int(g, 16) * int(p, 16))")
  FORK_FEES=$((FORK_FEES + fee))
  say "rehearsed $s: $h ok ($(okb "$fee") OKB of gas)"
done
[ "$(nonce)" = "$((PLAN_NONCE + ${#TODO[@]}))" ] || refuse "the rehearsal sent another number of transactions than ${#TODO[@]}"
# What comes after, on the fork only (anvil: impersonated wallets, time moved forward): the declarations this script
# prints for the keeper and the Architect wallet, and one settle of each bound kernel through the KeeperTank, as the
# keeper service will send it.
fork_send() { cast send "$@" --rpc-url "$R" --unlocked --json; }
if [ "$(c "$REGISTRY" "isTeam(address)(bool)" "$KEEPER")" != "true" ]; then
  fork_send "$REGISTRY" "declare(string)" "$KEEPER_ROLE" --from "$KEEPER" >/dev/null
  [ "$(c "$REGISTRY" "isTeam(address)(bool)" "$KEEPER")" = "true" ] || refuse "rehearsal: the keeper's declaration did not list it"
  say "rehearsed the keeper's declaration: listed"
fi
if [ "$(c "$REGISTRY" "isTeam(address)(bool)" "$AGENT")" != "true" ]; then
  cast rpc anvil_setBalance "$AGENT" 0x38d7ea4c68000 --rpc-url "$R" >/dev/null # 0.001 OKB, on the fork only
  decl=$(cast calldata "declare(string)" "$ARCHITECT_ROLE")
  cast call --from "$AGENT" "$REGISTRY" --data "$decl" --rpc-url "$R" >/dev/null || refuse "rehearsal: the Architect wallet's declaration reverts"
  fork_send "$REGISTRY" --data "$decl" --from "$AGENT" >/dev/null
  [ "$(c "$REGISTRY" "isTeam(address)(bool)" "$AGENT")" = "true" ] || refuse "rehearsal: the Architect wallet's declaration did not list it"
  say "rehearsed the Architect wallet's declaration (the printed calldata): listed"
fi
bound_kernels=()
same "$(bound_to "$K1")" "$ZERO" || bound_kernels+=("$K1")
same "$(bound_to "$K2")" "$ZERO" || bound_kernels+=("$K2")
if [ "${#bound_kernels[@]}" -gt 0 ]; then
  cast rpc evm_increaseTime 901 --rpc-url "$R" >/dev/null
  cast rpc evm_mine --rpc-url "$R" >/dev/null
  for k in "${bound_kernels[@]}"; do
    if [ "$(c "$k" "epochNow()(uint32)" | first)" -le "$(c "$k" "lastEpoch()(uint32)" | first)" ]; then
      say "rehearsal: kernel $k has settled this epoch already; no settle rehearsed"
      continue
    fi
    settled=$(fork_send "$TANK" "settleAndRefund(address)" "$k" --from "$KEEPER" --gas-limit 16000000)
    [ "$(jq -r .status <<<"$settled")" = "0x1" ] || refuse "rehearsal: KeeperTank.settleAndRefund($k) failed"
    paid=$(jq -r --arg tr "$TOPIC_REFUNDED" '[.logs[] | select(.topics[0] == $tr) | .data][0] // "0x"' <<<"$settled" \
      | python3 -c "import sys; d = sys.stdin.read().strip()[2:]; print(int(d[64:128], 16) if len(d) >= 128 else 0)")
    say "rehearsed the keeper's settle of $k through the KeeperTank: record $(c "$k" "count()(uint32)"), refund $(okb "$paid") OKB"
  done
fi
kill "$ANVIL" 2>/dev/null || true
ANVIL=
R=$RPC_URL
say "the rehearsal's ${#TODO[@]} transaction(s) cost $(okb "$FORK_FEES") OKB of gas; the deployer holds $(cast balance $DEPLOYER --rpc-url "$R" --ether) OKB"
[[ " ${TODO[*]} " != *" pull "* ]] || ! same "$(c "$SPLITTER" "MAINTAINER()(address)")" "$DEPLOYER" \
  || say "(the deployer is also the Splitter's maintainer: pull pays it 15% of what it splits)"

if [ "$broadcast" = no ]; then
  say "rehearsal only. To send ${TODO[*]}: the same command with --broadcast"
  exit 0
fi

# ---- 7. The real steps. The deployer's nonce must be the one the rehearsal started from, plus one per step sent.
EXPECT=$PLAN_NONCE
for s in "${TODO[@]}"; do
  todo_still=$(todo)
  if [[ " $todo_still " != *" $s "* ]]; then
    say "step '$s' is done on chain already (someone else did it since the check); not sending it"
    case $s in
      bindV1 | bindV2)
        h=$(locate_bind_tx "$(kernel_of "$s")")
        write_step "$s" "$h"
        ;;
    esac
    continue
  fi
  case $s in bindV1 | bindV2) check_bind "$s" >/dev/null ;; esac
  simulate "$s"
  now=$(nonce)
  [ "$now" = "$EXPECT" ] || refuse "the deployer's nonce is $now, the rehearsal expected $EXPECT for step '$s'. Nothing of it was sent; run this command again"
  echo
  say "BROADCAST: $(what_of "$s")"
  say "forge asks for the keystore password next. Ctrl-C at that prompt stops this step; once entered, it is sent."
  rec=$(record_of "$PROJECT" "$s")
  rm -f "$WORK/previous.json"
  [ ! -f "$rec" ] || cp "$rec" "$WORK/previous.json" # the record of an earlier run of this step, if any
  # shellcheck disable=SC2046 # the arguments are addresses
  if ! (cd "$PROJECT" && forge script "$SCRIPT:PostLaunch" -s "$(sig_of "$s")" $(args_of "$s") "${FORGE_GAS[@]}" --rpc-url "$RPC_URL" \
    --account "$ACCOUNT" --sender "$DEPLOYER" --broadcast --slow); then
    if [ ! -f "$rec" ] || cmp -s "$rec" "$WORK/previous.json" || [ "$(record_state "$rec")" = "unsigned" ]; then
      refuse "forge stopped before signing step '$s' (a mistyped password does this). Nothing of it was sent. Run the same command again"
    fi
    refuse "forge stopped during step '$s' after signing. Run the same command again: it first checks what reached the chain and never resends it"
  fi
  [ -f "$rec" ] || refuse "forge wrote no broadcast record for step '$s' ($rec)"
  [ "$(record_state "$rec")" = "complete" ] \
    || refuse "$rec: the transaction of step '$s' did not succeed or is not on chain yet. Nothing more is sent; ask Claude to look at it"
  record_is_step "$rec" "$s"
  write_step "$s" "$(jq -r '.transactions[0].hash' "$rec")"
  verify_step "$s"
  EXPECT=$((EXPECT + 1))
done

echo
say "DONE. Recorded in $LIVE:"
jq '{reference, architectToken, splitterPulls, registryInvites}' "$LIVE"
followups
