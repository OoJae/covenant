// The self-check and the OKX.AI listing helper.

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { test } from 'node:test';
import { AGENT_DESCRIPTION, AGENT_NAME, SERVICE_NAME, a2mcpService, endpointOf, feeString, shq } from '../src/listing.ts';
import { curlSelfCheck, runSelfCheck } from '../src/selfcheck.ts';
import { FAKE_OKX, FAKE_TAPC, PAY_TO, ROOT, harness } from './helpers.ts';

const HOST = 'https://covenant-architect-production.up.railway.app';

/** Route a fetch to the in-process app, so the self-check runs without a port. */
const fetchInto = (h: ReturnType<typeof harness>): typeof fetch =>
  (async (input: string | URL | Request, init?: RequestInit) => h.app.request(String(input), init)) as typeof fetch;

// ------------------------------------------------------------------------------------------- self-check

test('the printed self-check contains the one-line check of the OKX guide', () => {
  const text = curlSelfCheck(`${HOST}/`);
  assert.match(text, /^curl -i -X POST https:\/\/covenant-architect-production\.up\.railway\.app\/v1\/architect\/chip$/m);
  assert.match(text, /Expect: HTTP 402 and a PAYMENT-REQUIRED response header/);
  assert.match(text, /base64 --decode/);
  assert.match(text, /curl -s https:\/\/covenant-architect-production\.up\.railway\.app\/healthz/);
});

test('the script prints the self-check for the given base URL', () => {
  const out = execFileSync(process.execPath, ['scripts/selfcheck.ts', 'https://architect.example'], { cwd: ROOT, encoding: 'utf8', env: { PATH: process.env['PATH'] ?? '' } });
  assert.match(out, /^curl -i -X POST https:\/\/architect\.example\/v1\/architect\/chip$/m);
});

test('runSelfCheck passes against a local mock-mode server with the stub toolchain, including a mock-paid call', async () => {
  // The README's quick start: X402_MODE=mock node src/index.ts, then selfcheck --run --mock-pay.
  const base = 'http://localhost:8787';
  const h = harness({ X402_MODE: 'mock', PUBLIC_BASE_URL: base });
  const checks = await runSelfCheck(base, { fetch: fetchInto(h), priceUsd: '0.50', mockPay: true });
  assert.deepEqual(checks.filter((c) => !c.ok), [], JSON.stringify(checks.filter((c) => !c.ok)));
  assert.equal(checks.length, 16);
  assert.ok(checks.some((c) => c.name === 'unpaid POST answers HTTP 402'));
  assert.ok(checks.some((c) => c.name === 'mock-paid call answers 200 with a netlist'));
  // Locally, a stub toolchain and mock payments are not held against the server.
  assert.ok(!checks.some((c) => c.name === 'toolchain is the real one' || c.name === 'payments are live, not mock'));
});

test('runSelfCheck passes against a fully configured public server', async (t) => {
  t.mock.method(globalThis, 'fetch', async () =>
    new Response(JSON.stringify({ data: { kinds: [{ x402Version: 2, scheme: 'exact', network: 'eip155:196' }], extensions: [], signers: {} } })),
  );
  const base = 'https://architect.example';
  const h = harness({ ...FAKE_OKX, PAY_TO, PUBLIC_BASE_URL: base, TAPC_CMD: FAKE_TAPC });
  // Let the facilitator handshake finish so that /healthz already reports it.
  await h.post('/v1/architect/chip');
  const checks = await runSelfCheck(base, { fetch: fetchInto(h), payTo: PAY_TO, priceUsd: '0.50' });
  assert.deepEqual(checks.filter((c) => !c.ok), [], JSON.stringify(checks.filter((c) => !c.ok)));
  assert.ok(checks.some((c) => c.name === 'toolchain is the real one' && c.ok));
  assert.ok(checks.some((c) => c.name === 'payments are live, not mock' && c.ok));
  assert.ok(checks.some((c) => c.name === 'resource.url is https' && c.ok));
});

test('runSelfCheck reports what is wrong', async () => {
  // A public deployment left in mock mode, with the stub toolchain and another payee and price than expected.
  const h = harness({ X402_MODE: 'mock', PAY_TO, PUBLIC_BASE_URL: 'https://architect.example' });
  const checks = await runSelfCheck('https://architect.example', {
    fetch: fetchInto(h),
    payTo: '0x2222222222222222222222222222222222222222',
    priceUsd: '0.25',
  });
  const failed = checks.filter((c) => !c.ok).map((c) => c.name);
  assert.deepEqual(failed, ['toolchain is the real one', 'payments are live, not mock', 'amount is 0.25 USDT0', 'payTo is the expected address']);
});

test('runSelfCheck on an unconfigured live server: the 402 check fails and names the reason', async () => {
  const h = harness({ PAY_TO, TAPC_CMD: FAKE_TAPC });
  const checks = await runSelfCheck('https://architect.example', { fetch: fetchInto(h) });
  const byName = Object.fromEntries(checks.map((c) => [c.name, c]));
  assert.equal(byName['paid route is configured']?.ok, false);
  assert.match(byName['paid route is configured']?.detail ?? '', /OKX_API_KEY/);
  assert.equal(byName['unpaid POST answers HTTP 402']?.ok, false);
  assert.equal(byName['unpaid POST answers HTTP 402']?.detail, 'HTTP 503');
});

test('runSelfCheck refuses to "pay" a live server', async (t) => {
  t.mock.method(globalThis, 'fetch', async (input: string | URL | Request) =>
    String(input).endsWith('/supported')
      ? new Response(JSON.stringify({ data: { kinds: [{ x402Version: 2, scheme: 'exact', network: 'eip155:196' }], extensions: [], signers: {} } }))
      : new Response('{}', { status: 500 }),
  );
  const h = harness({ ...FAKE_OKX, PAY_TO, TAPC_CMD: FAKE_TAPC, PUBLIC_BASE_URL: 'https://architect.example' });
  const checks = await runSelfCheck('https://architect.example', { fetch: fetchInto(h), mockPay: true });
  const pay = checks.find((c) => c.name === 'mock-paid call');
  assert.equal(pay?.ok, false);
  assert.match(pay?.detail ?? '', /never makes one/);
  assert.equal(h.compiles.length, 0);
});

// ------------------------------------------------------------------------------------------- OKX.AI listing

test('the proposed listing satisfies the rules of the okx-ai skill (identity/service-contract.md)', () => {
  const s = a2mcpService(HOST, '0.50', 'flow-governor');

  assert.equal(s.serviceType, 'A2MCP');
  // serviceName: 5-30 characters, different from the agent name, no price.
  assert.ok(s.serviceName.length >= 5 && s.serviceName.length <= 30);
  assert.notEqual(s.serviceName.toLowerCase(), AGENT_NAME.toLowerCase());
  assert.doesNotMatch(s.serviceName, /\d|usd|\$/i);
  // fee: a plain number as a string, at most 6 decimals.
  assert.equal(s.fee, '0.5');
  // endpoint: deployed public HTTPS, at most 512 characters.
  assert.equal(s.endpoint, `${HOST}/v1/architect/chip`);
  assert.ok(s.endpoint.length <= 512);
  // A2MCP carries no subscription, freeTrial or serviceGuide.
  assert.deepEqual(Object.keys(s).sort(), ['endpoint', 'fee', 'serviceDescription', 'serviceName', 'serviceType']);

  // serviceDescription: exactly four numbered lines with the four headings.
  const lines = s.serviceDescription.split('\n');
  assert.equal(lines.length, 4);
  assert.match(lines[0]!, /^1\. \[Service Description\] \S/);
  assert.match(lines[1]!, /^2\. \[Parameter Spec\] preset\(string, optional\): .+; params\(object, optional\): .+$/);
  assert.equal(lines[2], '3. [Request Method] POST');
  assert.equal(
    lines[3],
    `4. [Request Example] curl -X POST ${HOST}/v1/architect/chip -H "Content-Type: application/json" -d '{"preset":"flow-governor","params":{}}'`,
  );
  assert.ok(s.serviceDescription.length < 2000);
  assert.doesNotMatch(s.serviceDescription, /<[^>]+>|your-domain|example\.com/, 'no placeholders');

  // Agent identity: a brand name of 3-25 characters; one sentence of at most 500 characters without a URL.
  assert.ok(AGENT_NAME.length >= 3 && AGENT_NAME.length <= 25);
  assert.ok(AGENT_DESCRIPTION.length <= 500);
  assert.doesNotMatch(AGENT_DESCRIPTION, /https?:\/\//);
  assert.equal(SERVICE_NAME, 'Vault Chip Compiler');
});

test('the request example in the listing is a request this service accepts', async () => {
  const s = a2mcpService(HOST, '0.50', 'flow-governor');
  const body = /-d '(.+)'$/.exec(s.serviceDescription.split('\n')[3]!)?.[1];
  assert.ok(body);
  const h = harness({ X402_MODE: 'mock', PAY_TO });
  const res = await h.post('/v1/architect/chip', body);
  assert.equal(res.status, 402, 'unpaid: the challenge, not a validation error');
});

test('feeString and endpointOf', () => {
  assert.deepEqual(['0.50', '0.5', '1', '1.000000', '0.000001', '010.2500'].map(feeString), ['0.5', '0.5', '1', '1', '0.000001', '10.25']);
  assert.throws(() => feeString('0.0000001'));
  assert.throws(() => feeString('$0.50'));
  assert.equal(endpointOf('https://architect.covenant.example/'), 'https://architect.covenant.example/v1/architect/chip');
  assert.throws(() => endpointOf('http://architect.covenant.example'), /https/);
  assert.throws(() => endpointOf('https://localhost:8787'), /public/);
  assert.throws(() => endpointOf('https://10.0.0.5'), /public/);
});

test('shq quotes for a POSIX shell, single quotes included', () => {
  const s = a2mcpService(HOST, '0.50', 'flow-governor');
  const json = JSON.stringify([s]);
  const echoed = execFileSync('/bin/sh', ['-c', `printf %s ${shq(json)}`], { encoding: 'utf8' });
  assert.equal(echoed, json);
  assert.deepEqual(JSON.parse(echoed), [s]);
});

test('the listing script prints the five commands, and --json prints only the service array', () => {
  const run = (...args: string[]): string =>
    execFileSync(process.execPath, ['scripts/okx-listing.ts', ...args], { cwd: ROOT, encoding: 'utf8', env: { PATH: process.env['PATH'] ?? '' } });

  const json = JSON.parse(run(HOST, '--json')) as unknown[];
  assert.deepEqual(json, [a2mcpService(HOST, '0.50', 'flow-governor')]);

  const text = run(HOST, '--price', '0.25', '--avatar', './logo.png');
  for (const command of [
    'onchainos agent pre-check --role asp',
    "onchainos agent upload --file './logo.png'",
    'onchainos agent validate-listing --role asp',
    'onchainos agent create --role asp',
    'onchainos agent activate --agent-id <newAgentId> --preferred-language en-US',
  ]) {
    assert.ok(text.includes(command), command);
  }
  assert.match(text, /"fee":"0\.25"/);
  assert.match(text, /Nothing below has been run for you/);

  // A local address is refused: OKX.AI needs the deployed public endpoint.
  assert.throws(() => run('http://localhost:8787'));
});
