#!/usr/bin/env bash
#
# Checks what script/Ignite.s.sol PRINTS, with the real forge, in a simulation. Nothing is sent, no key is used.
#
# The human signs off the story from this output, so it is compared here with the approved text itself:
# test/fixtures/story.head.txt and story.tail.txt, filled in by this script with addresses computed by `cast`.
# No Solidity is involved in building what is expected.
#
#   bash test/shell/ignite-output.test.sh        (from contracts/issuance; needs an X Layer RPC)
#
# XLAYER_RPC_URL chooses the RPC (default https://rpc.xlayer.tech; a local anvil fork works too).
# SENDER chooses the simulated deployer (default: the real one). It must hold the 0.0066 OKB deploy fee.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

RPC=${XLAYER_RPC_URL:-https://rpc.xlayer.tech}
SENDER=${SENDER:-0x84cE7bAe1b788C7aD985D57721cA428b401aE34D}
COMMIT_TEXT=0123456789abcdef0123456789abcdef01234567

failures=0
checks=0
ok() { checks=$((checks + 1)); }
fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  echo "FAIL $*"
}
expect_eq() { if [ "$1" = "$2" ]; then ok; else fail "$3: expected '$2', got '$1'"; fi; }

# ------------------------------------------------------------------ what is expected

created() { cast compute-address "$1" --nonce "$2" | awk '{print $NF}'; }

nonce=$(cast nonce "$SENDER" --rpc-url "$RPC") || { echo "no RPC at $RPC"; exit 2; }
splitter=$(created "$SENDER" "$nonce")
registry=$(created "$splitter" 1)
tank=$(created "$splitter" 2)

tail=$(cat test/fixtures/story.tail.txt)
tail=${tail//\{S\}/$splitter}
tail=${tail//\{T\}/$tank}
tail=${tail//\{A\}/$(cast to-check-sum-address "$SENDER")}
tail=${tail//\{R\}/$registry}
tail=${tail//\{C\}/$COMMIT_TEXT}
story="$(cat test/fixtures/story.head.txt)$tail"
shown=${story:0:600}

expect_eq "${#story}" 1366 "length of the expected story"
expect_eq "${#shown}" 600 "length of what TapeOut's site shows"

# ------------------------------------------------------------------ the simulation

out=$(MAINTAINER=$SENDER COMMIT=$COMMIT_TEXT forge script script/Ignite.s.sol:Ignite --rpc-url "$RPC" --sender "$SENDER" 2>&1)
status=$?
expect_eq "$status" 0 "forge script exit status"
if [ "$status" != 0 ]; then
  printf '%s\n' "$out" | tail -5
fi

# forge indents every log line by two spaces
line_of() { printf '%s\n' "$out" | grep -n -F -x -- "  $1" | head -1 | cut -d: -f1; }
count_of() { printf '%s\n' "$out" | grep -c -F -x -- "  $1"; }
after() { printf '%s\n' "$out" | sed -n "$(($1 + 1))p"; }

planned_addresses=$(line_of "== Planned addresses (nothing has been sent yet) ==")
planned_story=$(line_of "== Planned story (nothing has been sent yet) ==")
first600=$(line_of "== Its first 600 characters: all that TapeOut's own site shows ==")
created_line=$(line_of "== Created in this run (story on-chain equals the planned story: checked) ==")

for section in "$planned_addresses" "$planned_story" "$first600" "$created_line"; do
  if [ -n "$section" ]; then ok; else fail "a section heading is missing from the output"; fi
done

# the whole story, once, on a line of its own, under its heading
expect_eq "$(count_of "$story")" 1 "the planned story is printed, whole, exactly once"
expect_eq "$(after "${planned_story:-0}")" "  length (bytes)         1366" "the length printed under the story heading"
expect_eq "$(after "$((${planned_story:-0} + 2))")" "  $story" "the story follows its heading, length and hash"

# its first 600 characters, on their own, right under their heading
expect_eq "$(after "${first600:-0}")" "  $shown" "the first 600 characters follow their heading"
expect_eq "$(count_of "$shown")" 1 "the first 600 characters are printed on a line of their own, once"

# the planned addresses, each printed twice with the same value: once planned, once created
for pair in "Splitter (creator)    :$splitter" "TeamRegistry          :$registry" "KeeperTank            :$tank"; do
  label=${pair%%:*}
  address=${pair#*:}
  expect_eq "$(count_of "$label $address")" 2 "'$label' is printed as planned and as created, with the address cast computes"
done
for label in "Transistors (ERC-1155)" "Circuits (ERC-721)    "; do
  lines=$(printf '%s\n' "$out" | grep -F -- "  $label 0x" | sort -u | wc -l | tr -d ' ')
  total=$(printf '%s\n' "$out" | grep -c -F -- "  $label 0x")
  expect_eq "$total/$lines" "2/1" "'$label' is printed as planned and as created, with one and the same address"
done

# everything the human signs off comes before the creation is reported
if [ -n "$planned_addresses" ] && [ -n "$planned_story" ] && [ -n "$first600" ] && [ -n "$created_line" ] \
  && [ "$planned_addresses" -lt "$planned_story" ] && [ "$planned_story" -lt "$first600" ] && [ "$first600" -lt "$created_line" ]; then
  ok
else
  fail "the plan is not printed before the creation (lines: $planned_addresses, $planned_story, $first600, $created_line)"
fi

expect_eq "$(count_of "commit                 $COMMIT_TEXT")" 1 "the commit is printed as 40 bare hex characters"
expect_eq "$(printf '%s\n' "$out" | grep -c -F 'SIMULATION COMPLETE')" 1 "forge says it only simulated"
expect_eq "$(printf '%s\n' "$out" | grep -c -F 'ONCHAIN EXECUTION')" 0 "nothing was sent"

echo "$checks checks, $failures failed"
[ "$failures" = 0 ]
