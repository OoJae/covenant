#!/usr/bin/env bash
#
# Covenant ignition: the one command the human runs to create the processor.
#
#   script/ignite.sh               simulate against X Layer. Nothing is sent and no key is touched.
#   script/ignite.sh --broadcast   simulate, then SEND the creation transaction. It cannot be undone.
#
# The story written on-chain names a git commit, forever. So this script refuses to run unless that commit
# is exactly the source being deployed, and is public:
#
#   1. nothing in contracts/issuance differs from HEAD (no modified, staged or untracked file);
#   2. src/Splitter.sol is tracked by git, and so is every other .sol file under src/ and script/
#      (an ignored source file is missing from the commit while `git status` stays clean);
#   3. HEAD is an ancestor of origin/main after a fetch.
#
# COMMIT is `git rev-parse HEAD`. MAINTAINER is the deployer: script/Ignite.s.sol refuses any other.
# The RPC is https://rpc.xlayer.tech. To use the other public one: XLAYER_RPC_URL=https://xlayerrpc.okx.com
# With --broadcast the RPC must be an https one: a local fork is not X Layer, whatever chain id it reports.

set -euo pipefail

DEPLOYER=0x84cE7bAe1b788C7aD985D57721cA428b401aE34D
ACCOUNT=covenant-deployer
PROJECT=contracts/issuance
RPC_URL=${XLAYER_RPC_URL:-https://rpc.xlayer.tech}
USAGE="usage: script/ignite.sh [--broadcast]"

refuse() {
  echo "ignite.sh: REFUSED: $*" >&2
  exit 1
}

broadcast=no
case $# in
  0) ;;
  1)
    [ "$1" = "--broadcast" ] || refuse "unknown argument '$1' ($USAGE)"
    broadcast=yes
    ;;
  *) refuse "too many arguments ($USAGE)" ;;
esac

if [ "$broadcast" = yes ]; then
  case "$RPC_URL" in
    https://*) ;;
    *) refuse "--broadcast needs an https RPC, not '$RPC_URL'. A local fork is rehearsed with forge script (README.md, section 3)" ;;
  esac
fi

cd "$(dirname "$0")/.."
root=$(git rev-parse --show-toplevel)
[ "$(pwd -P)" = "$(cd "$root/$PROJECT" && pwd -P)" ] || refuse "this script belongs in $PROJECT/script of the repository"

# 1. The working tree is the commit.
changes=$(git -C "$root" status --porcelain -- "$PROJECT")
[ -z "$changes" ] || refuse "$PROJECT differs from HEAD. Commit it first:"$'\n'"$changes"

# 2. The commit holds the source.
git -C "$root" ls-files --error-unmatch -- "$PROJECT/src/Splitter.sol" >/dev/null 2>&1 \
  || refuse "$PROJECT/src/Splitter.sol is not tracked by git"
others=$(git -C "$root" ls-files --others -- "$PROJECT/src" "$PROJECT/script")
untracked=$(printf '%s\n' "$others" | grep '\.sol$' || true)
[ -z "$untracked" ] || refuse "source files that git does not track (are they ignored?):"$'\n'"$untracked"

# 3. The commit is public.
git -C "$root" fetch --quiet origin main || refuse "could not fetch origin/main"
git -C "$root" merge-base --is-ancestor HEAD origin/main \
  || refuse "HEAD is not on origin/main. Push first: the story will point at this commit"

# 4. Nothing outside the commit changes the build or the script. forge reads a .env file and FOUNDRY_* /
#    DAPP_* variables on its own; either could change compiler settings (the bytecode would no longer be the
#    one the commit builds) or set REHEARSAL.
for envfile in .env "$root/.env"; do
  [ ! -e "$envfile" ] || refuse "a .env file is present ($envfile): forge would read it. Move it away first"
done
if env | grep -qE '^(FOUNDRY_|DAPP_)'; then
  refuse "FOUNDRY_* or DAPP_* variables are set in this shell: $(env | grep -E '^(FOUNDRY_|DAPP_)' | cut -d= -f1 | tr '\n' ' ')"
fi
oz=$( (sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' lib/openzeppelin-contracts/package.json 2>/dev/null || true) | head -1)
[ "$oz" = "5.4.0" ] || refuse "lib/openzeppelin-contracts is '$oz', expected 5.4.0 (README.md, section 1)"

COMMIT=$(git -C "$root" rev-parse HEAD)
export COMMIT
export MAINTAINER=$DEPLOYER
export REHEARSAL=false # this is the real thing: chain 196 or nothing (an exported value beats any .env)

echo "ignite.sh: commit    $COMMIT"
echo "ignite.sh: deployer  $DEPLOYER (also the maintainer)"
echo "ignite.sh: RPC       $RPC_URL"
echo
echo "ignite.sh: SIMULATION. Nothing is sent."
forge script script/Ignite.s.sol:Ignite --rpc-url "$RPC_URL" --sender "$DEPLOYER"

if [ "$broadcast" = yes ]; then
  echo
  echo "ignite.sh: BROADCAST. What follows SENDS the creation transaction, signed by keystore '$ACCOUNT'."
  echo "ignite.sh: It cannot be undone. The story printed above is what goes on-chain. Ctrl-C stops here."
  forge script script/Ignite.s.sol:Ignite --rpc-url "$RPC_URL" \
    --account "$ACCOUNT" --sender "$DEPLOYER" --broadcast --slow
else
  echo
  echo "ignite.sh: simulation only. To create the processor: script/ignite.sh --broadcast"
fi
