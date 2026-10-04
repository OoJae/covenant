// POST /v1/architect/chip: the 402 challenge, the mock-paid happy path, and "a failed compile is not charged".
// Mock mode runs OKX's real seller SDK with an in-process facilitator: nothing here contacts OKX.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ExactEvmScheme } from '@okxweb3/x402-evm/exact/server';
import { MOCK_PAYER, MOCK_PAYMENT_MARKER, mockPaymentHeader } from '../src/mock-facilitator.ts';
import { CompileRejected, ToolchainError } from '../src/toolchain.ts';
import { FAKE_TAPC, PAY_TO, PUBLIC, challengeOf, decodeHeader, harness } from './helpers.ts';

const MOCK = { X402_MODE: 'mock', PAY_TO, PUBLIC_BASE_URL: PUBLIC };
const CHIP = '/v1/architect/chip';

// ------------------------------------------------------------------------------------------- the 402 challenge

test('an unpaid request gets HTTP 402 with the challenge base64-encoded in PAYMENT-REQUIRED', async () => {
  const h = harness(MOCK);
  // Exactly the self-check of OKX's A2MCP guide: curl -i -X POST <endpoint>, no body.
  const res = await h.post(CHIP);
  assert.equal(res.status, 402);
  assert.match(res.headers.get('content-type') ?? '', /^application\/json/);
  assert.deepEqual(await res.json(), {});

  const header = res.headers.get('PAYMENT-REQUIRED');
  assert.ok(header, 'the PAYMENT-REQUIRED header is present');
  assert.match(header, /^[A-Za-z0-9+/]+={0,2}$/, 'plain base64');

  assert.deepEqual(challengeOf(res), {
    x402Version: 2,
    error: 'Payment required',
    resource: {
      url: 'https://architect.example/v1/architect/chip',
      description: 'Covenant Architect: compile a vault chip preset into a TAP-20 netlist with its pin manifest, proofs and cost.',
      mimeType: 'application/json',
    },
    accepts: [
      {
        scheme: 'exact',
        network: 'eip155:196',
        amount: '500000', // 0.50 USDT0, 6 decimals
        asset: '0x779ded0c9e1022225f8e0630b35a9b54be713736',
        payTo: PAY_TO,
        maxTimeoutSeconds: 300,
        extra: { name: 'USD₮0', version: '1' },
      },
    ],
  });

  // Nothing ran and nothing was verified or settled.
  assert.equal(h.compiles.length, 0);
  assert.deepEqual(h.paywall.mock?.calls, { supported: 1, verify: 0, settle: 0 });
});

test('the challenge is the same with a valid body, and is exposed to browsers by CORS', async () => {
  const h = harness(MOCK);
  const res = await h.post(CHIP, { preset: 'flow-governor', params: { epochLen: 900 } }, { origin: 'https://covenant.example' });
  assert.equal(res.status, 402);
  assert.equal(challengeOf(res).accepts[0]?.amount, '500000');
  assert.equal(res.headers.get('access-control-allow-origin'), '*');
  assert.match(res.headers.get('access-control-expose-headers') ?? '', /PAYMENT-REQUIRED/);
  assert.equal(res.headers.get('X-Covenant-X402-Mode'), 'mock');
});

test('the token name survives the header encoding (it contains a non-ASCII character)', async () => {
  const h = harness(MOCK);
  const res = await h.post(CHIP);
  const raw = Buffer.from(res.headers.get('PAYMENT-REQUIRED') ?? '', 'base64');
  // U+20AE TUGRIK SIGN is e2 82 ae in UTF-8.
  assert.ok(raw.includes(Buffer.from([0x55, 0x53, 0x44, 0xe2, 0x82, 0xae, 0x30])), 'USD₮0 is UTF-8 encoded');
});

test('PRICE_USD sets the amount, exactly', async () => {
  const cases: Array<[string, string]> = [
    ['0.50', '500000'],
    ['0.5', '500000'],
    ['0.01', '10000'],
    ['1', '1000000'],
    ['0.000001', '1'],
    ['12.345678', '12345678'],
  ];
  for (const [price, amount] of cases) {
    const h = harness({ ...MOCK, PRICE_USD: price });
    const res = await h.post(CHIP);
    assert.equal(res.status, 402, price);
    assert.equal(challengeOf(res).accepts[0]?.amount, amount, price);
  }
});

test('the explicit amount, asset and domain equal what the SDK derives from "$0.50" on eip155:196', async () => {
  const h = harness(MOCK);
  const sdk = await new ExactEvmScheme().parsePrice('$0.50', 'eip155:196');
  const mine = challengeOf(await h.post(CHIP)).accepts[0]!;
  assert.deepEqual({ amount: mine.amount, asset: mine.asset, extra: mine.extra }, sdk);
});

test('without PUBLIC_BASE_URL the resource URL falls back to the request URL', async () => {
  const h = harness({ X402_MODE: 'mock', PAY_TO });
  const res = await h.app.request('http://localhost:8787/v1/architect/chip', { method: 'POST' });
  assert.equal(challengeOf(res).resource.url, 'http://localhost:8787/v1/architect/chip');
});

test('RAILWAY_PUBLIC_DOMAIN is used for the resource URL when PUBLIC_BASE_URL is unset', async () => {
  const h = harness({ X402_MODE: 'mock', PAY_TO, RAILWAY_PUBLIC_DOMAIN: 'covenant-architect.up.railway.app' });
  assert.equal(challengeOf(await h.post(CHIP)).resource.url, 'https://covenant-architect.up.railway.app/v1/architect/chip');
});

test('GET is answered with 405 and Allow: POST (OKX clients probe with GET, then switch to POST)', async () => {
  const h = harness(MOCK);
  const res = await h.app.request(CHIP);
  assert.equal(res.status, 405);
  assert.equal(res.headers.get('allow'), 'POST');
  assert.equal(res.headers.get('PAYMENT-REQUIRED'), null);
});

test('a malformed body is refused with 400 before any payment is asked for', async () => {
  const h = harness(MOCK);
  for (const body of ['{not json', '[1,2]', '{"preset":"Has Spaces"}', '{"params":7}', '{"prompt":"hello"}']) {
    const res = await h.post(CHIP, body);
    assert.equal(res.status, 400, body);
    assert.equal(res.headers.get('PAYMENT-REQUIRED'), null, body);
    const doc = (await res.json()) as { error: { code: string }; parameters: Record<string, unknown>; required: string[] };
    assert.match(doc.error.code, /^invalid_(json|request)$/);
    // The answer tells a client what the endpoint takes.
    assert.deepEqual(Object.keys(doc.parameters), ['preset', 'params']);
    assert.deepEqual(doc.required, []);
  }
  assert.equal(h.paywall.mock?.calls.verify, 0);
});

// ------------------------------------------------------------------------------------------- mock-paid happy path

test('mock-paid happy path: verified, compiled, settled once, result delivered with PAYMENT-RESPONSE', async () => {
  const h = harness(MOCK);
  const res = await h.payMock({ preset: 'flow-governor', params: { epochLen: 900 } });
  assert.equal(res.status, 200);

  const body = (await res.json()) as Record<string, unknown>;
  assert.deepEqual(Object.keys(body).sort(), ['cost', 'manifest', 'netlistHex', 'proofs', 'stub']);
  assert.match(String(body['netlistHex']), /^0x[0-9a-f]+$/);
  assert.equal(body['stub'], true); // TAPC_CMD is unset in this test: mock mode may serve the stub
  assert.equal(res.headers.get('X-Covenant-Toolchain'), 'stub');
  assert.equal(res.headers.get('X-Covenant-X402-Mode'), 'mock');

  const receipt = decodeHeader(res.headers.get('PAYMENT-RESPONSE'));
  assert.equal(receipt['success'], true);
  assert.equal(receipt['status'], 'success');
  assert.equal(receipt['network'], 'eip155:196');
  assert.equal(receipt['payer'], MOCK_PAYER);
  assert.equal(receipt['amount'], '500000');
  assert.equal(receipt['transaction'], 'MOCK-NOT-A-TRANSACTION-1');
  assert.doesNotMatch(String(receipt['transaction']), /^0x[0-9a-f]{64}$/, 'a mock settlement must not look like a transaction hash');

  const mock = h.paywall.mock!;
  assert.deepEqual(mock.calls, { supported: 1, verify: 1, settle: 1 });
  assert.deepEqual(mock.settlements, [
    { payTo: PAY_TO, amount: '500000', asset: '0x779ded0c9e1022225f8e0630b35a9b54be713736', network: 'eip155:196', transaction: 'MOCK-NOT-A-TRANSACTION-1' },
  ]);
  assert.deepEqual(h.compiles, [{ preset: 'flow-governor', params: { epochLen: 900 } }]);
  assert.equal(h.lines.filter((l) => l['event'] === 'payment_settled').length, 1);
});

test('mock-paid happy path through the real subprocess adapter', async () => {
  const h = harness({ ...MOCK, TAPC_CMD: FAKE_TAPC });
  const res = await h.payMock({ preset: 'ok', params: { a: 1 } });
  assert.equal(res.status, 200);
  const body = (await res.json()) as { manifest: Record<string, unknown>; stub?: boolean };
  assert.equal(body.stub, undefined);
  assert.equal(body.manifest['name'], 'ok');
  assert.deepEqual(body.manifest['params'], { a: 1 });
  assert.equal(res.headers.get('X-Covenant-Toolchain'), 'cli');
  assert.equal(h.paywall.mock?.calls.settle, 1);
});

test('a bare paid POST compiles the default preset', async () => {
  const h = harness({ ...MOCK, DEFAULT_PRESET: 'graduation-ratchet' });
  const res = await h.payMock();
  assert.equal(res.status, 200);
  assert.deepEqual(h.compiles, [{ preset: 'graduation-ratchet', params: {} }]);
});

test('mock mode refuses anything that is not a mock payment, and says so', async () => {
  const h = harness(MOCK);
  const unpaid = await h.post(CHIP);
  const challenge = challengeOf(unpaid);
  // Shaped like a real exact/EIP-3009 payment. Mock mode must not treat it as paid.
  const realLooking = {
    x402Version: 2,
    resource: challenge.resource,
    accepted: challenge.accepts[0],
    payload: { signature: `0x${'ab'.repeat(65)}`, authorization: { from: MOCK_PAYER, to: PAY_TO, value: '500000' } },
  };
  const res = await h.post(CHIP, undefined, { 'PAYMENT-SIGNATURE': Buffer.from(JSON.stringify(realLooking)).toString('base64') });
  assert.equal(res.status, 402);
  assert.equal(challengeOf(res).error, 'mock_mode');
  assert.equal(h.compiles.length, 0);
  assert.equal(h.paywall.mock?.calls.settle, 0);
});

test('a payment for different terms than the challenge is refused before verification', async () => {
  const h = harness(MOCK);
  const challenge = challengeOf(await h.post(CHIP));
  const cheaper = {
    x402Version: 2,
    resource: challenge.resource,
    accepted: { ...challenge.accepts[0], amount: '1' },
    payload: { mock: MOCK_PAYMENT_MARKER },
  };
  const res = await h.post(CHIP, undefined, { 'PAYMENT-SIGNATURE': Buffer.from(JSON.stringify(cheaper)).toString('base64') });
  assert.equal(res.status, 402);
  assert.equal(challengeOf(res).error, 'No matching payment requirements');
  assert.deepEqual(h.paywall.mock?.calls, { supported: 1, verify: 0, settle: 0 });
  assert.equal(h.compiles.length, 0);
});

test('a payment header that is not base64 JSON is treated as no payment', async () => {
  const h = harness(MOCK);
  const res = await h.post(CHIP, undefined, { 'PAYMENT-SIGNATURE': '%%%not-base64%%%' });
  assert.equal(res.status, 402);
  assert.equal(h.compiles.length, 0);
});

// ------------------------------------------------------------------------------------------- failure is not charged

const notCharged = async (
  name: string,
  compile: () => Promise<never>,
  status: number,
  code: string,
): Promise<void> => {
  const h = harness(MOCK, { compile });
  const res = await h.payMock({ preset: 'flow-governor' });
  assert.equal(res.status, status, name);
  const body = (await res.json()) as { error: { code: string; charged?: boolean }; netlistHex?: string };
  assert.equal(body.error.code, code, name);
  assert.equal(body.netlistHex, undefined, name);
  assert.equal(res.headers.get('PAYMENT-RESPONSE'), null, `${name}: no settlement receipt`);
  const mock = h.paywall.mock!;
  assert.equal(mock.calls.verify, 1, `${name}: the payment was verified`);
  assert.equal(mock.calls.settle, 0, `${name}: and never settled`);
  assert.equal(mock.settlements.length, 0, name);
  assert.equal(h.lines.filter((l) => l['event'] === 'payment_settled').length, 0, name);
};

test('failure is not charged: the toolchain rejects the request (422)', async () => {
  await notCharged('rejected', async () => Promise.reject(new CompileRejected('unknown_preset', 'no such preset', 'validate')), 422, 'unknown_preset');
});

test('failure is not charged: a proof fails (422)', async () => {
  await notCharged('proof', async () => Promise.reject(new CompileRejected('proof_failed', '1 proof(s) failed', 'prove')), 422, 'proof_failed');
});

test('failure is not charged: the toolchain times out (504)', async () => {
  await notCharged('timeout', async () => Promise.reject(new ToolchainError('timeout', 'too slow')), 504, 'toolchain_timeout');
});

test('failure is not charged: the toolchain crashes (502)', async () => {
  await notCharged('crash', async () => Promise.reject(new ToolchainError('crash', 'exit 3')), 502, 'toolchain_crash');
});

test('failure is not charged: an unexpected exception (500)', async () => {
  await notCharged('exception', async () => Promise.reject(new TypeError('boom')), 500, 'internal_error');
});

test('failure is not charged: through the real subprocess adapter, for every failing behaviour', async () => {
  const cases: Array<[string, number, string]> = [
    ['reject', 422, 'unknown_param'],
    ['reject-exit', 422, 'unknown_preset'],
    ['failed-proof', 422, 'proof_failed'],
    ['crash', 502, 'toolchain_crash'],
    ['garbage', 502, 'toolchain_bad_output'],
    ['big', 502, 'toolchain_bad_output'],
    ['bad-hex', 502, 'toolchain_bad_output'],
    ['no-ok', 502, 'toolchain_bad_output'],
  ];
  for (const [preset, status, code] of cases) {
    const h = harness({ ...MOCK, TAPC_CMD: FAKE_TAPC });
    const res = await h.payMock({ preset });
    assert.equal(res.status, status, preset);
    assert.equal(((await res.json()) as { error: { code: string } }).error.code, code, preset);
    assert.equal(h.paywall.mock?.calls.verify, 1, preset);
    assert.equal(h.paywall.mock?.calls.settle, 0, `${preset}: not settled`);
  }
});

test('failure is not charged: the compiler is busy (503)', async () => {
  let release: (() => void) | undefined;
  const gate = new Promise<void>((r) => (release = r));
  const h = harness(
    { ...MOCK, MAX_CONCURRENT_COMPILES: '1' },
    {
      compile: async () => {
        await gate;
        return { netlistHex: '0x00', manifest: {}, proofs: [], cost: {} };
      },
    },
  );
  const first = h.payMock({ preset: 'a' });
  // Let the first request reach the compiler, then send a second one.
  await new Promise((r) => setTimeout(r, 20));
  const second = await h.payMock({ preset: 'b' });
  assert.equal(second.status, 503);
  assert.equal(((await second.json()) as { error: { code: string } }).error.code, 'busy');
  assert.equal(second.headers.get('retry-after'), '5');
  assert.equal(h.paywall.mock?.calls.settle, 0);

  release?.();
  assert.equal((await first).status, 200);
  assert.equal(h.paywall.mock?.calls.settle, 1, 'only the request that was served is settled');
});

test('if settlement fails after a successful compile, the result is withheld', async () => {
  const h = harness(MOCK);
  h.paywall.mock!.failNextSettles = 1;
  const res = await h.payMock({ preset: 'flow-governor' });
  assert.equal(res.status, 402);
  const text = await res.text();
  assert.doesNotMatch(text, /netlistHex/, 'the compiled chip is not delivered unpaid');
  const receipt = decodeHeader(res.headers.get('PAYMENT-RESPONSE'));
  assert.equal(receipt['success'], false);
  assert.equal(receipt['errorReason'], 'mock_settle_failed');
  assert.equal(h.paywall.mock?.settlements.length, 0);
});

test('each paid request is settled exactly once', async () => {
  const h = harness(MOCK);
  for (let i = 1; i <= 3; i++) {
    const res = await h.payMock({ preset: 'flow-governor' });
    assert.equal(res.status, 200);
    assert.equal(h.paywall.mock?.calls.settle, i);
  }
});

test('mockPaymentHeader builds a v2 payload that echoes the accepted terms', async () => {
  const h = harness(MOCK);
  const unpaid = await h.post(CHIP);
  const payload = decodeHeader(mockPaymentHeader(unpaid.headers.get('PAYMENT-REQUIRED') ?? ''));
  assert.equal(payload['x402Version'], 2);
  assert.deepEqual(payload['accepted'], challengeOf(unpaid).accepts[0]);
  assert.deepEqual(payload['payload'], { mock: MOCK_PAYMENT_MARKER });
});
