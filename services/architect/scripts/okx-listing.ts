// Prints the OKX.AI registration commands for this service, with the A2MCP service JSON filled in for the
// deployed endpoint. It runs nothing: a person runs the printed commands.
//
//   node scripts/okx-listing.ts https://<public-host>              the commands
//   node scripts/okx-listing.ts https://<public-host> --json       only the --service JSON array
//
// Options:  --price 0.50   --preset flow-governor   --avatar ./avatar.png   (defaults: PRICE_USD, DEFAULT_PRESET)

import { AGENT_DESCRIPTION, AGENT_NAME, a2mcpService, shq } from '../src/listing.ts';

const args = process.argv.slice(2);
const flag = (name: string): string | undefined => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const base = args.find((a) => /^https?:\/\//.test(a)) ?? process.env['PUBLIC_BASE_URL'];
const price = flag('--price') ?? process.env['PRICE_USD'] ?? '0.50';
const preset = flag('--preset') ?? process.env['DEFAULT_PRESET'] ?? 'flow-governor';
const avatar = flag('--avatar') ?? './covenant-architect-avatar.png';

if (!base) {
  process.stderr.write('usage: node scripts/okx-listing.ts https://<public-host> [--json] [--price 0.50] [--preset name] [--avatar file]\n');
  process.exit(2);
}

let service;
try {
  service = a2mcpService(base, price, preset);
} catch (err) {
  process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(2);
}
const json = JSON.stringify([service]);

if (args.includes('--json')) {
  process.stdout.write(json + '\n');
  process.exit(0);
}

const out = `# OKX.AI registration for ${service.endpoint}
# Run these yourself, in order, from a terminal where \`onchainos wallet status\` shows the wallet that should
# own the agent. Nothing below has been run for you.

# 0. The endpoint must already answer 402 (see: node scripts/selfcheck.ts ${base} --run)

# 1. Pre-check. Read canCreate. If "consent" comes back, read the terms and re-run with the key it gives you.
onchainos agent pre-check --role asp
# onchainos agent pre-check --role asp --consent-key <consentKey from the first call>

# 2. Upload the avatar (PNG, JPEG or WebP, at most 1 MB). Keep the "url" it returns.
onchainos agent upload --file ${shq(avatar)}

# 3. Validate the listing locally (no network). Expect {"pass": true, "findings": []}.
onchainos agent validate-listing --role asp \\
  --name ${shq(AGENT_NAME)} \\
  --description ${shq(AGENT_DESCRIPTION)} \\
  --service ${shq(json)}

# 4. Create the agent. Replace <avatar url> with the url from step 2. Keep the newAgentId it returns.
onchainos agent create --role asp \\
  --name ${shq(AGENT_NAME)} \\
  --description ${shq(AGENT_DESCRIPTION)} \\
  --picture '<avatar url>' \\
  --service ${shq(json)}

# 5. Submit for listing review (usually within 48 hours; watch the linked email). Keep the endpoint up meanwhile.
onchainos agent activate --agent-id <newAgentId> --preferred-language en-US

# Field values proposed
#   name                ${AGENT_NAME}
#   description         ${AGENT_DESCRIPTION}
#   serviceType         ${service.serviceType}
#   serviceName         ${service.serviceName}
#   fee                 ${service.fee}   (USDT per call; must equal PRICE_USD of the deployment)
#   endpoint            ${service.endpoint}
#   serviceDescription  (four numbered lines)
${service.serviceDescription
  .split('\n')
  .map((l) => `#     ${l}`)
  .join('\n')}
`;
process.stdout.write(out);
