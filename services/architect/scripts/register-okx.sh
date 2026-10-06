#!/usr/bin/env bash
#
# Registers the Covenant Architect on OKX.AI and submits it for listing review, with the `onchainos` CLI of the
# wallet that will own the agent. A person runs this; it asks before each step that creates or submits anything.
#
#   services/architect/scripts/register-okx.sh https://<host> [avatar.png]
#
# The commands and field values are the ones `node services/architect/scripts/okx-listing.ts <host>` prints
# (src/listing.ts). Before registering, the endpoint must answer HTTP 402 correctly:
#   PAY_TO=<payee> PRICE_USD=0.50 node services/architect/scripts/selfcheck.ts <host> --run

set -euo pipefail

HOST=${1:?usage: register-okx.sh https://<host> [avatar.png]}
AVATAR=${2:-docs/assets/architect.png}
HOST=${HOST%/}
cd "$(dirname "$0")/../../.."
[ -f "$AVATAR" ] || { echo "no avatar at $AVATAR" >&2; exit 1; }
command -v onchainos >/dev/null || { echo "onchainos is not installed" >&2; exit 1; }

NAME='Covenant Architect'
DESCRIPTION='Covenant Architect compiles vault chips for IGNIX tokens on X Layer: tax-routing circuits anyone can read and nobody can change, delivered as TapeOut netlists with a pin manifest, proofs and a cost quote.'
SERVICE=$(node -e '
const host = process.argv[1];
process.stdout.write(JSON.stringify([{
  serviceName: "Vault Chip Compiler",
  serviceDescription: [
    "1. [Service Description] Compiles a Covenant vault chip preset for an IGNIX token into a TapeOut TAP-20 netlist and returns JSON with netlistHex, the pin manifest, proof results and the tape-out cost.",
    "2. [Parameter Spec] preset(string, optional): vault chip preset name, default flow-governor; params(object, optional): preset parameters as a JSON object, default {}",
    "3. [Request Method] POST",
    `4. [Request Example] curl -X POST ${host}/v1/architect/chip -H "Content-Type: application/json" -d \x27{"preset":"flow-governor","params":{}}\x27`,
  ].join("\n"),
  serviceType: "A2MCP",
  fee: "0.5",
  endpoint: `${host}/v1/architect/chip`,
}]));' "$HOST")

ask() {
  local answer
  read -r -p "$1 [y/N] " answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ] || { echo "stopped; nothing more was sent"; exit 0; }
}
field() { # json, jq path list -> first non-empty value
  jq -r "$2 // empty" <<<"$1" | head -1
}

echo "== 0. the endpoint answers 402"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$HOST/v1/architect/chip" -H 'Content-Type: application/json' -d '{}')
[ "$code" = "402" ] || { echo "POST $HOST/v1/architect/chip answered $code, not 402: run selfcheck.ts first" >&2; exit 1; }
echo "   402"

echo "== 1. wallet and pre-check"
onchainos wallet status || true
out=$(onchainos agent pre-check --role asp)
echo "$out"
if [ "$(field "$out" '.data.canCreate, .canCreate')" != "true" ]; then
  echo "canCreate is not true. If it asks for consent, read the terms it names and run:" >&2
  echo "  onchainos agent pre-check --role asp --consent-key <consentKey>" >&2
  echo "then run this script again." >&2
  exit 1
fi

echo "== 2. avatar upload ($AVATAR)"
out=$(onchainos agent upload --file "$AVATAR")
echo "$out"
URL=$(field "$out" '.data.url, .url, .data.fileUrl')
[ -n "$URL" ] || { echo "no url in the upload answer; continue by hand from step 4 of okx-listing.ts" >&2; exit 1; }

echo "== 3. local validation"
out=$(onchainos agent validate-listing --role asp --name "$NAME" --description "$DESCRIPTION" --service "$SERVICE")
echo "$out"
[ "$(field "$out" '.data.pass, .pass')" = "true" ] || { echo "validation did not pass; nothing was created" >&2; exit 1; }

echo
echo "== 4. create the agent '$NAME' (endpoint $HOST/v1/architect/chip, 0.5 USDT per call)"
ask "Create it now?"
out=$(onchainos agent create --role asp --name "$NAME" --description "$DESCRIPTION" --picture "$URL" --service "$SERVICE")
echo "$out"
ID=$(field "$out" '.data.newAgentId, .newAgentId, .data.agentId, .agentId')
[ -n "$ID" ] || { echo "no agent id in the answer; activate by hand: onchainos agent activate --agent-id <id> --preferred-language en-US" >&2; exit 1; }
echo "   agent id $ID"

echo
echo "== 5. submit agent $ID for listing review (usually within 48 hours; keep the endpoint up)"
ask "Submit it now?"
onchainos agent activate --agent-id "$ID" --preferred-language en-US
echo "submitted: agent $ID"
