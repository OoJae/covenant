#!/usr/bin/env bash
#
# Tests of script/ignite.sh, the wrapper the human runs. No chain, no key, no network:
#
#   - a throwaway git repository with the layout of the real one is built in a temporary directory, with a
#     second (bare) repository as its `origin`;
#   - `forge` is a stub that records its arguments and the environment the wrapper gave it.
#
# So what is tested is exactly what the wrapper adds: its refusals, what it puts in COMMIT and MAINTAINER, and
# which forge commands it runs, in which order, with and without --broadcast.
#
#   bash test/shell/ignite.test.sh          (from contracts/issuance)
#
# Set WRAPPER=<path> to test another copy of the script (the mutation pass does).

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
WRAPPER=${WRAPPER:-$here/../../script/ignite.sh}
DEPLOYER=0x84cE7bAe1b788C7aD985D57721cA428b401aE34D

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Nothing of the machine's own git setup leaks in, and nothing here touches it.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset XLAYER_RPC_URL REHEARSAL COMMIT MAINTAINER

failures=0
checks=0
ok() { checks=$((checks + 1)); }
fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  echo "FAIL [$scenario] $*"
}
expect_eq() { if [ "$1" = "$2" ]; then ok; else fail "$3: expected '$2', got '$1'"; fi; }
expect_has() { if printf '%s' "$1" | grep -qF -- "$2"; then ok; else fail "$3: '$2' not found in: $1"; fi; }
expect_hasnt() { if printf '%s' "$1" | grep -qF -- "$2"; then fail "$3: '$2' found in: $1"; else ok; fi; }

# ------------------------------------------------------------------ the stub forge

mkdir -p "$work/bin"
cat >"$work/bin/forge" <<'STUB'
#!/usr/bin/env bash
# One line per call: the arguments, then what the wrapper exported.
n=$(($(wc -l <"$FORGE_LOG" 2>/dev/null || echo 0) + 1))
echo "args=[$*] COMMIT=[${COMMIT-unset}] MAINTAINER=[${MAINTAINER-unset}] REHEARSAL=[${REHEARSAL-unset}] cwd=[$(pwd -P)]" >>"$FORGE_LOG"
echo "stub forge call $n"
[ "$n" = "${FORGE_FAIL_ON_CALL:-0}" ] && exit 1
exit 0
STUB
chmod +x "$work/bin/forge"
export PATH="$work/bin:$PATH"
export FORGE_LOG="$work/forge.log"

# ------------------------------------------------------------------ a fresh repository per scenario

# $repo: the working repository. $origin: its bare remote. HEAD is pushed to origin/main.
new_repo() {
  scenario=$1
  repo="$work/$scenario/repo"
  origin="$work/$scenario/origin.git"
  rm -rf "${work:?}/${scenario:?}"
  mkdir -p "$repo/contracts/issuance/src/lib" "$repo/contracts/issuance/script/lib" "$repo/contracts/issuance/test"
  (
    cd "$repo" || exit 1
    git init -q -b main .
    echo "contract Splitter {}" >contracts/issuance/src/Splitter.sol
    echo "library Native {}" >contracts/issuance/src/lib/Native.sol
    echo "contract Ignite {}" >contracts/issuance/script/Ignite.s.sol
    echo "library Story {}" >contracts/issuance/script/lib/Story.sol
    echo "contract T {}" >contracts/issuance/test/T.t.sol
    printf '/out/\n/cache/\n/lib/\n' >contracts/issuance/.gitignore
    echo "readme" >README.md
    cp "$WRAPPER" contracts/issuance/script/ignite.sh
    chmod +x contracts/issuance/script/ignite.sh
    git add -A
    git commit -q -m "issuance"
    git init -q --bare -b main "$origin"
    git remote add origin "$origin"
    git push -q origin main
  ) || { echo "could not build the test repository"; exit 2; }
  : >"$FORGE_LOG"
}

# runs the wrapper of the current repository; sets $status and $output
run() {
  output=$(cd "$repo/contracts/issuance" && bash script/ignite.sh "$@" 2>&1)
  status=$?
}

calls() { wc -l <"$FORGE_LOG" | tr -d ' '; }
call() { sed -n "${1}p" "$FORGE_LOG"; }
commit() { git -C "$repo" commit -q -m "$1"; }

SIM="args=[script script/Ignite.s.sol:Ignite --rpc-url https://rpc.xlayer.tech --sender $DEPLOYER]"
SEND="args=[script script/Ignite.s.sol:Ignite --rpc-url https://rpc.xlayer.tech --account covenant-deployer --sender $DEPLOYER --broadcast --slow]"

# ------------------------------------------------------------------ what it runs

new_repo simulation
head=$(git -C "$repo" rev-parse HEAD)
run
expect_eq "$status" 0 "exit status"
expect_eq "$(calls)" 1 "forge calls"
expect_has "$(call 1)" "$SIM" "the simulation command"
expect_has "$(call 1)" "COMMIT=[$head]" "COMMIT is git rev-parse HEAD"
expect_eq "${#head}" 40 "a full 40 character commit"
expect_has "$(call 1)" "MAINTAINER=[$DEPLOYER]" "MAINTAINER is the deployer"
expect_has "$(call 1)" "REHEARSAL=[unset]" "no rehearsal flag"
expect_has "$(call 1)" "cwd=[$(cd "$repo/contracts/issuance" && pwd -P)]" "forge runs in contracts/issuance"
expect_hasnt "$(cat "$FORGE_LOG")" "--broadcast" "nothing is broadcast without --broadcast"
expect_hasnt "$(cat "$FORGE_LOG")" "--account" "no keystore without --broadcast"
expect_has "$output" "SIMULATION. Nothing is sent." "says it is a simulation"
expect_has "$output" "$head" "prints the commit"

new_repo broadcast
head=$(git -C "$repo" rev-parse HEAD)
run --broadcast
expect_eq "$status" 0 "exit status"
expect_eq "$(calls)" 2 "forge calls: the simulation, then the broadcast"
expect_has "$(call 1)" "$SIM" "first the simulation"
expect_hasnt "$(call 1)" "--broadcast" "the first call sends nothing"
expect_has "$(call 2)" "$SEND" "then the broadcast, from the keystore and the deployer"
expect_has "$(call 2)" "COMMIT=[$head]" "the same commit"
expect_has "$(call 2)" "MAINTAINER=[$DEPLOYER]" "the same maintainer"

new_repo simulation_fails
FORGE_FAIL_ON_CALL=1 run --broadcast
expect_eq "$status" 1 "exit status when the simulation fails"
expect_eq "$(calls)" 1 "nothing is broadcast after a failed simulation"

new_repo from_another_directory
output=$(cd "$work" && bash "$repo/contracts/issuance/script/ignite.sh" 2>&1)
status=$?
expect_eq "$status" 0 "exit status"
expect_has "$(call 1)" "cwd=[$(cd "$repo/contracts/issuance" && pwd -P)]" "forge still runs in contracts/issuance"

new_repo other_rpc
XLAYER_RPC_URL=https://xlayerrpc.okx.com run --broadcast
expect_eq "$status" 0 "exit status"
expect_has "$(call 1)" "--rpc-url https://xlayerrpc.okx.com --sender" "the simulation uses XLAYER_RPC_URL"
expect_has "$(call 2)" "--rpc-url https://xlayerrpc.okx.com --account" "the broadcast uses XLAYER_RPC_URL"

new_repo rehearsal_flag_is_dropped
REHEARSAL=true run --broadcast
expect_eq "$status" 0 "exit status"
expect_has "$(call 1)" "REHEARSAL=[unset]" "REHEARSAL does not reach the simulation"
expect_has "$(call 2)" "REHEARSAL=[unset]" "REHEARSAL does not reach the broadcast"

new_repo environment_cannot_choose_commit_or_maintainer
head=$(git -C "$repo" rev-parse HEAD)
COMMIT=1111111111111111111111111111111111111111 MAINTAINER=0x000000000000000000000000000000000000dEaD run
expect_has "$(call 1)" "COMMIT=[$head]" "COMMIT from the environment is overwritten"
expect_has "$(call 1)" "MAINTAINER=[$DEPLOYER]" "MAINTAINER from the environment is overwritten"

new_repo origin_is_ahead
head=$(git -C "$repo" rev-parse HEAD)
(
  other="$work/$scenario/other"
  git clone -q "$origin" "$other" && cd "$other" && echo more >>README.md && git commit -q -am "later" && git push -q origin main
)
run
expect_eq "$status" 0 "HEAD behind origin/main is still public"
expect_eq "$(calls)" 1 "forge calls"
expect_has "$(call 1)" "COMMIT=[$head]" "COMMIT is HEAD, the source being deployed, not the newer origin/main"
expect_hasnt "$(call 1)" "COMMIT=[$(git -C "$origin" rev-parse main)]" "COMMIT is not origin/main"

# ------------------------------------------------------------------ what it refuses

refused() { # $1 = text the refusal must contain; uses $status, $output
  expect_eq "$status" 1 "exit status"
  expect_has "$output" "REFUSED" "says it refused"
  expect_has "$output" "$1" "says why"
  expect_eq "$(calls)" 0 "forge is not run at all"
}

new_repo modified_file
echo "// changed" >>"$repo/contracts/issuance/src/Splitter.sol"
run --broadcast
refused "differs from HEAD"

new_repo staged_change
echo "// changed" >>"$repo/contracts/issuance/src/lib/Native.sol"
git -C "$repo" add -A
run
refused "differs from HEAD"

new_repo untracked_file
echo "contract Extra {}" >"$repo/contracts/issuance/src/Extra.sol"
run --broadcast
refused "differs from HEAD"

# not only source files: anything in the project that is not in the commit
new_repo untracked_file_that_is_not_source
echo "optimizer_runs = 1" >"$repo/contracts/issuance/foundry.local.toml"
run --broadcast
refused "differs from HEAD"

# what git ignores on purpose does not count: build output, the dependency folder, dry-run records
new_repo ignored_build_output
mkdir -p "$repo/contracts/issuance/out" "$repo/contracts/issuance/cache" "$repo/contracts/issuance/lib/forge-std"
echo "{}" >"$repo/contracts/issuance/out/Splitter.json"
echo "{}" >"$repo/contracts/issuance/cache/solidity-files-cache.json"
echo "contract Dependency {}" >"$repo/contracts/issuance/lib/forge-std/Dependency.sol"
run
expect_eq "$status" 0 "build output and dependencies do not stop it"
expect_eq "$(calls)" 1 "forge calls"

new_repo deleted_file
rm "$repo/contracts/issuance/script/lib/Story.sol"
run
refused "differs from HEAD"

new_repo change_outside_issuance_is_not_its_business
echo "more" >>"$repo/README.md"
run
expect_eq "$status" 0 "a change outside contracts/issuance does not stop it"
expect_eq "$(calls)" 1 "forge calls"

new_repo splitter_not_tracked
(
  cd "$repo" || exit 1
  git rm -q --cached contracts/issuance/src/Splitter.sol
  echo "Splitter.sol" >>contracts/issuance/.gitignore
  git add -A && commit "splitter ignored" && git push -q origin main
)
expect_eq "$(git -C "$repo" status --porcelain)" "" "the tree is clean although the file is not in the commit"
run --broadcast
refused "src/Splitter.sol is not tracked by git"

# The mistake this project made once: the pattern `lib/` in .gitignore, meant for the dependency folder,
# also hides src/lib and script/lib.
new_repo ignored_source_file
(
  cd "$repo" || exit 1
  git rm -q -r --cached contracts/issuance/src/lib contracts/issuance/script/lib
  printf 'out/\ncache/\nlib/\n' >contracts/issuance/.gitignore
  git add -A && commit "lib ignored everywhere" && git push -q origin main
)
expect_eq "$(git -C "$repo" status --porcelain)" "" "the tree is clean although two source files are not in the commit"
run --broadcast
refused "source files that git does not track"
expect_has "$output" "contracts/issuance/src/lib/Native.sol" "names the missing source file"
expect_has "$output" "contracts/issuance/script/lib/Story.sol" "names the missing script file"

new_repo not_pushed
(cd "$repo" && echo "// later" >>contracts/issuance/src/Splitter.sol && git add -A && commit "local only")
run --broadcast
refused "HEAD is not on origin/main"

new_repo diverged
(
  other="$work/$scenario/other"
  git clone -q "$origin" "$other" && cd "$other" && echo more >>README.md && git commit -q -am "theirs" && git push -q origin main
)
(cd "$repo" && echo "// ours" >>contracts/issuance/src/Splitter.sol && git add -A && commit "ours")
run
refused "HEAD is not on origin/main"

# origin/main as last seen is not enough: the fetch is what decides
new_repo origin_was_rewound
(cd "$repo" && echo "// second" >>contracts/issuance/src/Splitter.sol && git add -A && commit "second" && git push -q origin main)
git -C "$origin" update-ref refs/heads/main "$(git -C "$repo" rev-parse HEAD~1)"
run --broadcast
refused "HEAD is not on origin/main"

new_repo no_remote
git -C "$repo" remote remove origin
run
refused "could not fetch origin/main"

# A fork on this machine reports chain id 196 too. The simulation may use one; the real thing may not.
new_repo broadcast_to_a_local_rpc
XLAYER_RPC_URL=http://127.0.0.1:8545 run --broadcast
refused "--broadcast needs an https RPC"
XLAYER_RPC_URL=http://localhost:8545 run --broadcast
refused "--broadcast needs an https RPC"
XLAYER_RPC_URL=ws://rpc.example run --broadcast
refused "--broadcast needs an https RPC"
XLAYER_RPC_URL=http://127.0.0.1:8545 run
expect_eq "$status" 0 "a simulation may use a local fork"
expect_has "$(call 1)" "--rpc-url http://127.0.0.1:8545 --sender" "the simulation uses the local RPC"
expect_eq "$(calls)" 1 "forge calls"

new_repo unknown_argument
run --brodcast
refused "unknown argument"
run -broadcast
refused "unknown argument"
run broadcast
refused "unknown argument"

new_repo too_many_arguments
run --broadcast --broadcast
refused "too many arguments"
run --broadcast now
refused "too many arguments"

# ------------------------------------------------------------------ result

echo "$checks checks, $failures failed"
[ "$failures" = 0 ]
