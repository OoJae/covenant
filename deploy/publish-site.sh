#!/usr/bin/env bash
#
# Covenant, the site on DeWEB: publishes web/ (built to web/dist) into the DeWEB container of the probe circuit
# (deployments/xlayer.json .probe.circuitId) on Covenant's processor, so that the official gateway serves it at
# https://<id>-2-<processor number>.tapekit.org/ (circuit 1 of processor 283: https://1-2-283.tapekit.org/).
#
#   deploy/publish-site.sh               build the site of HEAD, rehearse the whole publication on a local fork of X Layer
#                                        and print the plan and its cost. Nothing is sent and no key is touched.
#   deploy/publish-site.sh --broadcast   the same, then SEND it, signed by keystore 'covenant-deployer'.
#   MONTHS=3 deploy/publish-site.sh ...  months (30 days each) of name activation to pay for if the name is not
#                                        active yet (default 1; 0.026 OKB per month when written)
#   PRUNE=0 deploy/publish-site.sh ...   keep files that are on chain but not in this build. By default they are removed
#                                        (the plan lists each one before anything is sent), so the container holds exactly
#                                        this build and verify.ts finds chain = build with no exceptions.
#
# What is sent (tools/deweb/sim/script/Publish.s.sol, one forge run, one password): open the container (0.08 OKB,
# once), one putFile per file and one appendChunk per further 24,000 bytes (HTML last), and bind the on-chain name
# for MONTHS (MONTHS x 0.026 OKB). The plan is computed from the chain: a file already on chain byte for byte is not
# sent again, an opened container is not opened again, an active name is not paid again.
#
# Before anything is sent, this script checks that:
#   - web/, packages/, the chip files the site embeds, the lockfile, tools/deweb and deploy/ are exactly HEAD, and
#     HEAD is on origin/main;
#   - no .env file, FOUNDRY_* / DAPP_* variable or COVENANT_FORK can change the build;
#   - the circuit is the one deployments/xlayer.json records, on a TapeOut processor, held by the deployer;
#   - the publication was rehearsed from the chain's current state on a local fork (from a scratch copy of
#     tools/deweb/sim: nothing of the rehearsal is written in the repository), and read back byte for byte there;
#   - the deployer's nonce is the one the rehearsal started from, and web/dist is the build that was rehearsed.
# forge writes its broadcast record (tools/deweb/sim/broadcast/, git-ignored) before it asks for the password. A run
# that stopped is recovered from the chain on the next run: a record nothing of which was signed is set aside, what
# reached the chain is never sent again (the plan is recomputed from the chain), and a signed transaction that is not
# on chain (pending, or failed) stops everything. After the send: the site is read back from the chain and compared
# with the build, recorded in deployments/xlayer.json under .site, and checked through the live gateway.

set -euo pipefail

DEPLOYER=0x84cE7bAe1b788C7aD985D57721cA428b401aE34D
ACCOUNT=covenant-deployer
TAPEOUT_FACTORY=0x1f09DAeFA827f02CBb40967cc91b259763760761
RPC_URL=${XLAYER_RPC_URL:-https://rpc.xlayer.tech}
MONTHS=${MONTHS:-1}
PRUNE=${PRUNE:-1}
USAGE="usage: [MONTHS=n] [PRUNE=0] deploy/publish-site.sh [--broadcast]"
# verify.ts: the live checks after the send. (The end-to-end test of this script, on a fork, replaces these two:
# a fork has no second node operator and the official gateway cannot see it.)
LIVE_VERIFY_OPTS=()
GATEWAY_CHECK=yes

refuse() {
  echo "publish-site.sh: REFUSED: $*" >&2
  exit 1
}
say() { echo "publish-site.sh: $*"; }

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
[[ "$MONTHS" =~ ^[0-9]+$ ]] && [ "$MONTHS" -ge 1 ] && [ "$MONTHS" -le 120 ] || refuse "MONTHS must be a whole number from 1 to 120, not '$MONTHS'"
case "$PRUNE" in
  1) PLAN_PRUNE=(--prune); PUBLISH_PRUNE=true; VERIFY_EXTRA=() ;;
  0) PLAN_PRUNE=(); PUBLISH_PRUNE=false; VERIFY_EXTRA=(--allow-extra) ;;
  *) refuse "PRUNE must be 1 (default: remove files this build no longer has) or 0 (keep them), not '$PRUNE'" ;;
esac
for tool in forge cast anvil jq node python3 rsync; do
  command -v "$tool" >/dev/null || refuse "$tool is not installed"
done

root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
[ "$(git rev-parse --show-toplevel)" = "$root" ] || refuse "this script belongs in deploy/ of the repository"
LIVE=deployments/xlayer.json
SIM=tools/deweb/sim
RECORDS=$SIM/broadcast/Publish.s.sol/196
WORK=$(mktemp -d "${TMPDIR:-/tmp}/covenant-site.XXXXXX")
ANVIL=
cleanup() {
  [ -z "$ANVIL" ] || kill "$ANVIL" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- 1. The working tree is the commit, and the commit is public.
SOURCES=(web packages chips/out chips/cells package.json pnpm-lock.yaml pnpm-workspace.yaml tools/deweb deploy)
changes=$(git status --porcelain -- "${SOURCES[@]}" | grep -v ' deploy/rehearsal.json$' || true)
[ -z "$changes" ] || refuse "the site or the publishing tool differ from HEAD. Commit them first:"$'\n'"$changes"
for f in $SIM/src/SitePublisher.sol $SIM/src/DeWeb.sol $SIM/script/Publish.s.sol $SIM/foundry.toml tools/deweb/verify.ts \
  web/index.html web/vite.config.ts; do
  git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || refuse "$f is not tracked by git"
done
git fetch --quiet origin main || refuse "could not fetch origin/main"
git merge-base --is-ancestor HEAD origin/main || refuse "HEAD is not on origin/main. Push first"
COMMIT=$(git rev-parse HEAD)

# ---- 2. Nothing outside the commit changes the build or the plan.
for envfile in .env web/.env $SIM/.env; do
  [ ! -e "$envfile" ] || refuse "a .env file is present ($envfile). Move it away first"
done
if env | grep -qE '^(FOUNDRY_|DAPP_)'; then
  refuse "FOUNDRY_* or DAPP_* variables are set in this shell: $(env | grep -E '^(FOUNDRY_|DAPP_)' | cut -d= -f1 | tr '\n' ' ')"
fi
[ -z "${COVENANT_FORK:-}" ] || refuse "COVENANT_FORK is set: that build points the site at a local fork"
[ -f $SIM/lib/forge-std/src/Script.sol ] \
  || refuse "forge-std is missing: (cd $SIM && forge install foundry-rs/forge-std --no-git --root \"\$PWD\")"

# ---- 3. The circuit.
[ -f "$LIVE" ] || refuse "$LIVE is missing"
[ "$(cast chain-id --rpc-url "$RPC_URL")" = "196" ] || refuse "$RPC_URL is not X Layer (chain 196)"
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
live() { jq -r "$1 // empty" "$LIVE"; }
CIRCUITS=$(live .issuance.circuits)
CIRCUIT_ID=$(live .probe.circuitId)
[ -n "$CIRCUITS" ] && [ -n "$CIRCUIT_ID" ] || refuse "$LIVE names no processor (.issuance.circuits) or probe circuit (.probe.circuitId)"
[ "$(lower "$(live .deployer)")" = "$(lower "$DEPLOYER")" ] || refuse "$LIVE names another deployer"
[ "$(cast call $TAPEOUT_FACTORY "isCPU(address)(bool)" "$CIRCUITS" --rpc-url "$RPC_URL")" = "true" ] \
  || refuse "$CIRCUITS is not a TapeOut processor"
holder=$(cast call "$CIRCUITS" "ownerOf(uint256)(address)" "$CIRCUIT_ID" --rpc-url "$RPC_URL")
[ "$(lower "$holder")" = "$(lower "$DEPLOYER")" ] || refuse "circuit $CIRCUIT_ID is held by $holder, not by the deployer"

# ---- 4. An earlier run that stopped. forge writes a record (and a timestamped copy) BEFORE the password prompt, so a
#      record proves nothing by itself: the chain is asked about every transaction in it. Prints one word:
#        unsigned   nothing in it was signed, so nothing can have been sent
#        sent       every signed transaction is on chain and succeeded (the rest, if any, was never signed)
#        pending    a signed transaction has no receipt: it may still be mined
#        failed     a signed transaction reverted
record_state() {
  local signed=0 h status
  for h in $(jq -r '.transactions[] | .hash // "none"' "$1"); do
    [ "$h" = "none" ] && continue
    signed=$((signed + 1))
    status=$(cast rpc eth_getTransactionReceipt "$h" --rpc-url "$RPC_URL" | jq -r 'if . == null then "none" else .status end')
    [ "$status" = "none" ] && { echo pending; return; }
    [ "$status" = "0x1" ] || { echo failed; return; }
  done
  if [ "$signed" -eq 0 ]; then echo unsigned; else echo sent; fi
}
drop_unsigned() { # a record, and run-latest.json or timestamped copies with the same bytes
  local dir copy
  dir=$(dirname "$1")
  for copy in "$dir"/run-*.json; do
    [ -f "$copy" ] && [ "$copy" != "$1" ] && cmp -s "$copy" "$1" && rm -f "$copy"
  done
  rm -f "$1"
}
if [ -d "$RECORDS" ]; then
  for rec in "$RECORDS"/run-*.json; do
    [ -f "$rec" ] || continue
    case $(record_state "$rec") in
      unsigned)
        say "an earlier run stopped before signing (for example a mistyped password). Nothing of it was sent."
        say "removing forge's unsigned record $rec"
        drop_unsigned "$rec"
        ;;
      sent) ;;
      pending)
        refuse "$rec holds a signed transaction that is not on chain yet (still pending, or the record is not from X Layer mainnet). Nothing is sent; wait a minute and run again, or ask Claude to look at it"
        ;;
      *)
        refuse "$rec holds a signed transaction that reverted. Nothing more is sent; ask Claude to look at it"
        ;;
    esac
  done
fi

# ---- 5. The build: the site as HEAD has it, exported with git archive into a scratch directory and built there
#      with the command of web/package.json's "build" script (type check, vite, size and self-containment budget),
#      run directly: in a scratch directory pnpm's dependency check would try to reinstall.
#      The site bundles deployments/xlayer.json (web/src/config.ts), so it is built from HEAD's copy of that file
#      WITHOUT .site: the publication's own record must not feed the build it records, or every publication would
#      change the next build. The snapshot in tools/deweb/sim/site (git-ignored) is what is rehearsed and sent.
say "commit     $COMMIT"
say "deployer   $DEPLOYER"
say "RPC        $RPC_URL"
SRC=$WORK/src
mkdir -p "$SRC"
git archive HEAD web packages chips/out chips/cells package.json pnpm-lock.yaml pnpm-workspace.yaml deployments | tar -x -C "$SRC"
jq 'del(.site)' "$SRC/$LIVE" >"$SRC/$LIVE.tmp" || refuse "cannot read HEAD's $LIVE"
mv "$SRC/$LIVE.tmp" "$SRC/$LIVE"
ln -s "$root/node_modules" "$SRC/node_modules" # dependencies: the repository's own, linked, never copied or installed
for d in web packages/*; do
  [ -d "$root/$d/node_modules" ] && [ -d "$SRC/$d" ] && rsync -a "$root/$d/node_modules/" "$SRC/$d/node_modules/"
done
say "building the site of $COMMIT in a scratch export: $(jq -r .scripts.build "$SRC/web/package.json")"
(cd "$SRC/web" && PATH="$PWD/node_modules/.bin:$PATH" sh -c "$(jq -r .scripts.build package.json)") >"$WORK/build.log" 2>&1 \
  || { tail -30 "$WORK/build.log" >&2; refuse "the site of HEAD did not build"; }
digest() { (cd "$1" && find . -type f ! -name .DS_Store -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) | shasum -a 256 | cut -c1-64; }
rm -rf "$SIM/site"
rsync -a --exclude .DS_Store "$SRC/web/dist/" "$SIM/site/"
SITE_DIGEST=$(digest "$SIM/site")
mkdir -p "$WORK/sim"
rsync -a --exclude broadcast/ --exclude measured/ "$SIM/" "$WORK/sim/"

# ---- 6. A local fork of the chain as it is now, and the plan read from the chain at exactly the fork's block.
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
FORK=http://127.0.0.1:$port
# a fork fetches state lazily: retry the public node's rate-limit answers instead of failing the rehearsal
anvil --fork-url "$RPC_URL" --port "$port" --auto-impersonate --silent --retries 20 --fork-retry-backoff 1000 --timeout 60000 &
ANVIL=$!
for _ in $(seq 1 60); do cast chain-id --rpc-url "$FORK" >/dev/null 2>&1 && break; sleep 1; done
[ "$(cast chain-id --rpc-url "$FORK" 2>/dev/null)" = "196" ] || refuse "the rehearsal fork did not start"
FORK_BLOCK=$(cast block-number --rpc-url "$FORK")
NONCE_BEFORE=$(cast nonce $DEPLOYER --rpc-url "$FORK")
BALANCE_BEFORE=$(cast balance $DEPLOYER --rpc-url "$FORK")
node tools/deweb/plan.ts --processor "$CIRCUITS" --circuit "$CIRCUIT_ID" --dir "$WORK/sim/site" --months "$MONTHS" \
  ${PLAN_PRUNE[@]+"${PLAN_PRUNE[@]}"} --from "$DEPLOYER" --rpc "$RPC_URL" --block "$FORK_BLOCK" --timeout 180 --json "$WORK/plan.json" >"$WORK/plan.txt" \
  || { cat "$WORK/plan.txt" >&2; refuse "plan.ts failed"; }
sed -n '/^Processor/,/^Chain state/p;/^TOTAL/,$p' "$WORK/plan.txt"
PROCESSOR_NUMBER=$(jq -r .target.processorNumber "$WORK/plan.json")
STEPS=$(jq -r '.steps | length' "$WORK/plan.json")

# ---- 7. The rehearsal: the whole publication on that fork, from the scratch copy, impersonating the deployer.
publish_env=(PROCESSOR="$CIRCUITS" CIRCUIT_ID="$CIRCUIT_ID" PROCESSOR_NUMBER="$PROCESSOR_NUMBER" MONTHS="$MONTHS" PRUNE="$PUBLISH_PRUNE")
say "REHEARSAL on a local fork of X Layer at block $FORK_BLOCK (deployer nonce $NONCE_BEFORE). Nothing is sent."
if [ "$STEPS" -gt 0 ]; then
  (cd "$WORK/sim" && env "${publish_env[@]}" SITE_DIR=site forge script script/Publish.s.sol --rpc-url "$FORK" \
    --sender "$DEPLOYER" --unlocked --broadcast --slow) >"$WORK/rehearsal.log" 2>&1 \
    || { tail -40 "$WORK/rehearsal.log" >&2; refuse "the rehearsal failed"; }
fi
NONCE_AFTER=$(cast nonce $DEPLOYER --rpc-url "$FORK")
SENT=$((NONCE_AFTER - NONCE_BEFORE))
[ "$SENT" -eq "$STEPS" ] || refuse "the rehearsal sent $SENT transactions, the plan has $STEPS"
SPENT=$(python3 -c "print(($BALANCE_BEFORE - $(cast balance $DEPLOYER --rpc-url "$FORK")) / 10**18)")
node tools/deweb/verify.ts --processor "$CIRCUITS" --circuit "$CIRCUIT_ID" --dir "$WORK/sim/site" --rpc "$FORK" \
  --block "$(cast block-number --rpc-url "$FORK")" --second-rpc none --no-gateway --timeout 180 \
  ${VERIFY_EXTRA[@]+"${VERIFY_EXTRA[@]}"} >"$WORK/verify-fork.txt" 2>&1 \
  || { cat "$WORK/verify-fork.txt" >&2; refuse "the rehearsed site does not read back identical from the fork"; }
kill "$ANVIL" 2>/dev/null || true
ANVIL=
say "rehearsal: $SENT transaction(s), $SPENT OKB in fees and gas; the site reads back byte for byte from the fork"

if [ "$broadcast" = no ]; then
  say "rehearsal only. To send it: deploy/publish-site.sh --broadcast"
  exit 0
fi

# ---- 8. The real publication.
if [ "$STEPS" -gt 0 ]; then
  now=$(cast nonce $DEPLOYER --rpc-url "$RPC_URL")
  [ "$now" = "$NONCE_BEFORE" ] || refuse "the deployer's nonce is $now, the rehearsal started from $NONCE_BEFORE. Nothing was sent; run this command again"
  [ "$(digest "$SIM/site")" = "$SITE_DIGEST" ] || refuse "$SIM/site changed since it was built and rehearsed. Nothing was sent; run this command again"
  echo
  say "BROADCAST: $STEPS transaction(s) from $DEPLOYER, about $SPENT OKB"
  say "forge asks for the keystore password next. Ctrl-C at that prompt stops everything; once entered, the transactions are sent one by one."
  if ! (cd "$SIM" && env "${publish_env[@]}" SITE_DIR=site forge script script/Publish.s.sol \
    --rpc-url "$RPC_URL" --account "$ACCOUNT" --sender "$DEPLOYER" --broadcast --slow); then
    if [ ! -f "$RECORDS/run-latest.json" ] || [ "$(record_state "$RECORDS/run-latest.json")" = "unsigned" ]; then
      refuse "forge stopped before signing (a mistyped password does this). Nothing was sent. Run the same command again"
    fi
    refuse "forge stopped after signing. Run the same command again: it reads the chain first and never sends again what reached it"
  fi
  [ -f "$RECORDS/run-latest.json" ] || refuse "forge wrote no broadcast record ($RECORDS/run-latest.json)"
  [ "$(record_state "$RECORDS/run-latest.json")" = "sent" ] \
    || refuse "a transaction of the publication is not on chain or did not succeed. Nothing more is sent; ask Claude to look at it"
  [ "$(digest "$SIM/site")" = "$SITE_DIGEST" ] || refuse "$SIM/site changed during the send; run this command again (it sends only what differs)"
else
  say "nothing to send: the container already holds this build and the name is active"
fi

# ---- 9. Read back from the chain (at the head now, so that the last transactions are included), record, and check
#      the gateway.
HEAD_NOW=$(cast block-number --rpc-url "$RPC_URL")
node tools/deweb/verify.ts --processor "$CIRCUITS" --circuit "$CIRCUIT_ID" --dir "$SIM/site" --rpc "$RPC_URL" --block "$HEAD_NOW" \
  ${LIVE_VERIFY_OPTS[@]+"${LIVE_VERIFY_OPTS[@]}"} ${VERIFY_EXTRA[@]+"${VERIFY_EXTRA[@]}"} --no-gateway >"$WORK/verify-chain.txt" 2>&1 \
  || { cat "$WORK/verify-chain.txt" >&2; refuse "the site on chain is not this build (see above). It is not recorded"; }
container=$(cast call 0x536adD8F30f03b69f6fbF29d425A816A0dC50106 "accountOf(address,uint256)(address)" "$CIRCUITS" "$CIRCUIT_ID" --rpc-url "$RPC_URL")
# cast annotates large numbers ("1793897036 [1.793e9]"): keep the number
paid_until=$(cast call 0x68809Fd2fb343aA57D0aeB7f33Defe477c9666f9 "containerPaidUntil(address)(uint40)" "$container" --rpc-url "$RPC_URL" | awk '{print $1}')
[[ "$paid_until" =~ ^[0-9]+$ ]] || refuse "could not read until when the name is paid ($paid_until)"
name=$(jq -r .target.name "$WORK/plan.json")
host=$(jq -r .target.host "$WORK/plan.json")
# every transaction of every publication run that reached the chain (the records left are all real: step 4)
txs=$( (jq -r '.site.txs[]? // empty' "$LIVE"; for rec in "$RECORDS"/run-[0-9]*.json; do
  [ -f "$rec" ] && jq -r '.transactions[] | .hash // empty' "$rec"; done) | awk 'NF && !seen[$0]++' | jq -R . | jq -sc .)
files=$(jq -c '[.files[] | {path, bytes, sha256, contentType}]' "$WORK/plan.json")
tmp=$(mktemp)
jq --arg c "$COMMIT" --arg p "$CIRCUITS" --argjson n "$PROCESSOR_NUMBER" --argjson id "$CIRCUIT_ID" --arg k "$container" \
  --arg nm "$name" --arg g "https://$host.tapekit.org/" --argjson u "$paid_until" --arg d "$SITE_DIGEST" \
  --argjson f "$files" --argjson t "$txs" \
  '.site = {commit: $c, processor: $p, processorNumber: $n, circuitId: $id, container: $k, name: $nm, gateway: $g,
    status: ($g + ".tape/status"), paidUntil: $u, build: "web/package.json build script at the commit, deployments/xlayer.json minus .site",
    buildDigest: $d, files: $f, txs: $t}' \
  "$LIVE" >"$tmp" || refuse "could not write .site into $LIVE (the publication is on chain; run this command again to record it)"
mv "$tmp" "$LIVE"
say "recorded in $LIVE under .site: $name, container $container, active until $(date -u -r "$paid_until" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$paid_until")"

if [ "$GATEWAY_CHECK" = yes ]; then
  say "checking the live gateway https://$host.tapekit.org/ in a headless browser"
  set +e
  node tools/deweb/verify.ts --processor "$CIRCUITS" --circuit "$CIRCUIT_ID" --dir "$SIM/site" --rpc "$RPC_URL" --block "$HEAD_NOW" \
    ${LIVE_VERIFY_OPTS[@]+"${LIVE_VERIFY_OPTS[@]}"} ${VERIFY_EXTRA[@]+"${VERIFY_EXTRA[@]}"} --expect-selector '#app *'
  code=$?
  set -e
  case $code in
    0) say "the gateway serves the site byte for byte and the site runs" ;;
    3) say "the gateway could not be checked from this machine (see above); the chain holds the site. Open https://$host.tapekit.org/ to look" ;;
    *) refuse "the gateway does not serve the site as built (see above). The publication itself is on chain and recorded" ;;
  esac
fi
echo
say "DONE. https://$host.tapekit.org/   (status: https://$host.tapekit.org/.tape/status)"
