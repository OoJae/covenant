// Live mode: failing closed, and the wiring of OKX's facilitator client. The OKX API is never contacted:
// where the real OKXFacilitatorClient is used, global fetch is replaced for the duration of the test.

import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { mock, test } from 'node:test';
import type { FacilitatorClient } from '@okxweb3/x402-core/server';
import { confirmTransferOnChain } from '../src/paywall.ts';
import { FAKE_OKX, FAKE_TAPC, PAY_TO, PUBLIC, challengeOf, decodeHeader, harness } from './helpers.ts';

const CHIP = '/v1/architect/chip';
const LIVE = { ...FAKE_OKX, PAY_TO, PUBLIC_BASE_URL: PUBLIC, TAPC_CMD: FAKE_TAPC };

const errorOf = async (res: Response): Promise<{ code: string; message: string; reasons?: string[] }> =>
  ((await res.json()) as { error: { code: string; message: string; reasons?: string[] } }).error;

// ------------------------------------------------------------------------------------------- fail closed

test('no credentials: the paid route answers 503 with the missing variable names, and the free route still works', async () => {
  const h = harness({ PAY_TO, TAPC_CMD: FAKE_TAPC });
  const res = await h.post(CHIP, { preset: 'ok' });
  assert.equal(res.status, 503);
  assert.equal(res.headers.get('PAYMENT-REQUIRED'), null, 'no challenge is issued by a server that cannot settle');
  const err = await errorOf(res);
  assert.equal(err.code, 'paid_endpoint_unavailable');
  assert.deepEqual(err.reasons, ['OKX_API_KEY, OKX_SECRET_KEY, OKX_PASSPHRASE are not set']);
  assert.equal(h.compiles.length, 0);

  // Even with a payment header attached, nothing runs.
  const paid = await h.post(CHIP, { preset: 'ok' }, { 'PAYMENT-SIGNATURE': 'e30=' });
  assert.equal(paid.status, 503);
  assert.equal(h.compiles.length, 0);

  assert.equal((await h.post('/v1/architect/compile', { preset: 'ok' })).status, 200);

  const health = (await (await h.app.request('/healthz')).json()) as { ok: boolean; paid: { ready: boolean; reasons: string[] } };
  assert.equal(health.ok, true);
  assert.equal(health.paid.ready, false);
  assert.deepEqual(health.paid.reasons, ['OKX_API_KEY, OKX_SECRET_KEY, OKX_PASSPHRASE are not set']);
});

test('each missing piece is named', async () => {
  const cases: Array<[Record<string, string | undefined>, RegExp]> = [
    [{ ...LIVE, OKX_SECRET_KEY: undefined }, /^OKX_SECRET_KEY is not set$/],
    [{ ...LIVE, OKX_API_KEY: '', OKX_PASSPHRASE: '  ' }, /^OKX_API_KEY, OKX_PASSPHRASE are not set$/],
    [{ ...LIVE, PAY_TO: undefined }, /^PAY_TO is not set$/],
    [{ ...LIVE, PAY_TO: '0x123' }, /^PAY_TO is not a 20-byte hex address$/],
    [{ ...LIVE, PAY_TO: '0x779Ded0c9e1022225f8E0630b35a9b54bE713737' }, /^PAY_TO fails the EIP-55 checksum/],
    [{ ...LIVE, PAY_TO: '0x0000000000000000000000000000000000000000' }, /^PAY_TO is the zero address$/],
    [{ ...LIVE, PRICE_USD: 'fifty cents' }, /^PRICE_USD must be a plain decimal number/],
    [{ ...LIVE, PRICE_USD: '0' }, /^PRICE_USD must be greater than zero$/],
    [{ ...LIVE, X402_MODE: 'free' }, /^X402_MODE is "free"; it must be "live" or "mock"$/],
    [{ ...LIVE, TAPC_CMD: undefined }, /^TAPC_CMD is not set: the toolchain is a stub, and the paid route does not sell stub output$/],
    [{ ...LIVE, OKX_BASE_URL: 'http://okx.example/path' }, /^OKX_BASE_URL must look like/],
  ];
  for (const [env, pattern] of cases) {
    const h = harness(env);
    const res = await h.post(CHIP);
    assert.equal(res.status, 503, String(pattern));
    const err = await errorOf(res);
    assert.equal(err.reasons?.length, 1, String(pattern));
    assert.match(err.reasons?.[0] ?? '', pattern);
  }
});

test('the 503 never contains a credential value', async () => {
  const h = harness({ ...LIVE, PAY_TO: undefined });
  const text = await (await h.post(CHIP)).text();
  const health = await (await h.app.request('/healthz')).text();
  for (const value of Object.values(FAKE_OKX)) {
    assert.ok(value && !text.includes(value) && !health.includes(value));
  }
});

test('facilitator down: 503 without a challenge, retried after a pause, then it recovers', async () => {
  let up = false;
  let supportedCalls = 0;
  const facilitator: FacilitatorClient = {
    async getSupported() {
      supportedCalls++;
      if (!up) throw new Error('OKX getSupported failed: 401');
      return { kinds: [{ x402Version: 2, scheme: 'exact', network: 'eip155:196' }], extensions: [], signers: {} };
    },
    async verify() {
      return { isValid: false, invalidReason: 'unused' };
    },
    async settle() {
      throw new Error('unused');
    },
  };
  const h = harness(LIVE, { facilitator, retryAfterMs: 5000 });

  let res = await h.post(CHIP);
  assert.equal(res.status, 503);
  assert.equal((await errorOf(res)).code, 'facilitator_unavailable');
  assert.equal(res.headers.get('retry-after'), '10');
  assert.equal(res.headers.get('PAYMENT-REQUIRED'), null);
  assert.equal(supportedCalls, 1);

  // Within the pause the facilitator is not hammered.
  res = await h.post(CHIP);
  assert.equal(res.status, 503);
  assert.equal(supportedCalls, 1);

  const health = (await (await h.app.request('/healthz')).json()) as { paid: { ready: boolean; facilitator: string } };
  assert.deepEqual([health.paid.ready, health.paid.facilitator], [false, 'unavailable']);
  // The facilitator's error text goes to the log, not to the public health endpoint.
  assert.ok(h.lines.some((l) => l['event'] === 'paywall_facilitator_unavailable' && /401/.test(String(l['error']))));

  up = true;
  h.clock.advance(5001);
  res = await h.post(CHIP);
  assert.equal(res.status, 402);
  assert.equal(supportedCalls, 2);
  assert.equal(challengeOf(res).accepts[0]?.payTo, PAY_TO);
});

test('a facilitator that does not support exact on X Layer keeps the route closed', async () => {
  const facilitator: FacilitatorClient = {
    async getSupported() {
      return { kinds: [{ x402Version: 2, scheme: 'exact', network: 'eip155:1' }], extensions: [], signers: {} };
    },
    async verify() {
      return { isValid: false };
    },
    async settle() {
      throw new Error('unused');
    },
  };
  const h = harness(LIVE, { facilitator });
  const res = await h.post(CHIP);
  assert.equal(res.status, 503);
  assert.equal((await errorOf(res)).code, 'facilitator_unavailable');
});

// ------------------------------------------------------------------------------------------- OKX client wiring

interface Seen {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: Record<string, unknown> | null;
}

/** Replace global fetch with a scripted OKX facilitator. Returns what it was asked. */
function fakeOkx(t: { mock: typeof mock }, settle: Record<string, unknown>): Seen[] {
  const seen: Seen[] = [];
  t.mock.method(globalThis, 'fetch', async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const headers = Object.fromEntries(Object.entries((init?.headers ?? {}) as Record<string, string>));
    const body = typeof init?.body === 'string' ? (JSON.parse(init.body) as Record<string, unknown>) : null;
    seen.push({ url, method: init?.method ?? 'GET', headers, body });
    const reply = (data: unknown): Response => new Response(JSON.stringify({ code: '0', data }), { status: 200 });
    if (url.endsWith('/api/v6/pay/x402/supported')) {
      return reply({ kinds: [{ x402Version: 2, scheme: 'exact', network: 'eip155:196' }], extensions: [], signers: {} });
    }
    if (url.endsWith('/api/v6/pay/x402/verify')) return reply({ isValid: true, payer: '0x00000000000000000000000000000000000000Aa' });
    if (url.endsWith('/api/v6/pay/x402/settle')) return reply(settle);
    if (url.includes('/api/v6/pay/x402/settle/status?txHash=')) return reply({ success: true, status: 'pending' });
    return new Response('not found', { status: 404 });
  });
  return seen;
}

const TX = `0x${'cd'.repeat(32)}`;
const payment = (challenge: ReturnType<typeof challengeOf>): string =>
  Buffer.from(
    JSON.stringify({ x402Version: 2, resource: challenge.resource, accepted: challenge.accepts[0], payload: { signature: '0xsigned', authorization: {} } }),
  ).toString('base64');

test('live mode talks to OKX with HMAC-signed requests, settles with syncSettle, and never logs the credentials', async (t) => {
  const seen = fakeOkx(t, { success: true, status: 'success', transaction: TX, network: 'eip155:196', payer: '0x00000000000000000000000000000000000000Aa' });
  const h = harness(LIVE);

  const unpaid = await h.post(CHIP, { preset: 'ok' });
  assert.equal(unpaid.status, 402);
  assert.equal(unpaid.headers.get('X-Covenant-X402-Mode'), 'live');
  const challenge = challengeOf(unpaid);
  assert.equal(challenge.accepts[0]?.payTo, PAY_TO);
  assert.equal(challenge.resource.url, 'https://architect.example/v1/architect/chip');

  // The handshake: one signed GET to OKX's x402 API on the SDK's default host.
  assert.equal(seen.length, 1);
  const supported = seen[0]!;
  assert.equal(supported.url, 'https://web3.okx.com/api/v6/pay/x402/supported');
  assert.equal(supported.headers['OK-ACCESS-KEY'], 'placeholder-api-key');
  assert.equal(supported.headers['OK-ACCESS-PASSPHRASE'], 'placeholder-passphrase');
  const ts = supported.headers['OK-ACCESS-TIMESTAMP']!;
  assert.equal(
    supported.headers['OK-ACCESS-SIGN'],
    createHmac('sha256', 'placeholder-secret-key').update(`${ts}GET/api/v6/pay/x402/supported`).digest('base64'),
  );

  const paid = await h.post(CHIP, { preset: 'ok' }, { 'PAYMENT-SIGNATURE': payment(challenge) });
  assert.equal(paid.status, 200);
  assert.equal(decodeHeader(paid.headers.get('PAYMENT-RESPONSE'))['transaction'], TX);

  assert.deepEqual(seen.map((s) => s.url.replace('https://web3.okx.com/api/v6/pay/x402/', '')), ['supported', 'verify', 'settle']);
  const settle = seen[2]!;
  assert.equal(settle.method, 'POST');
  assert.equal(settle.body?.['syncSettle'], true);
  assert.equal(settle.body?.['x402Version'], 2);
  assert.equal((settle.body?.['paymentRequirements'] as { payTo: string }).payTo, PAY_TO);
  assert.equal((settle.body?.['paymentRequirements'] as { amount: string }).amount, '500000');

  // The log has the settlement, and not one of the three credential values.
  const log = JSON.stringify(h.lines);
  assert.match(log, /payment_settled/);
  for (const value of Object.values(FAKE_OKX)) assert.ok(value && !log.includes(value));
});

test('live mode: a failed compile makes no settle call to OKX', async (t) => {
  const seen = fakeOkx(t, { success: true, status: 'success', transaction: TX, network: 'eip155:196' });
  const h = harness(LIVE);
  const challenge = challengeOf(await h.post(CHIP, { preset: 'reject' }));
  const res = await h.post(CHIP, { preset: 'reject' }, { 'PAYMENT-SIGNATURE': payment(challenge) });
  assert.equal(res.status, 422);
  assert.equal(res.headers.get('PAYMENT-RESPONSE'), null);
  assert.deepEqual(seen.map((s) => s.url.split('/').at(-1)), ['supported', 'verify']);
});

test('live mode: X402_SYNC_SETTLE=0 is passed to OKX as syncSettle false', async (t) => {
  const seen = fakeOkx(t, { success: true, status: 'pending', transaction: TX, network: 'eip155:196' });
  const h = harness({ ...LIVE, X402_SYNC_SETTLE: '0' });
  const challenge = challengeOf(await h.post(CHIP, { preset: 'ok' }));
  const res = await h.post(CHIP, { preset: 'ok' }, { 'PAYMENT-SIGNATURE': payment(challenge) });
  assert.equal(res.status, 200);
  assert.equal(seen.at(-1)?.body?.['syncSettle'], false);
});

test('live mode: OKX refusing the payment at verification yields 402 and no compile', async (t) => {
  const seen: string[] = [];
  t.mock.method(globalThis, 'fetch', async (input: string | URL | Request) => {
    const url = String(input);
    seen.push(url.split('/').at(-1) ?? '');
    const reply = (data: unknown): Response => new Response(JSON.stringify({ code: '0', data }), { status: 200 });
    if (url.endsWith('/supported')) return reply({ kinds: [{ x402Version: 2, scheme: 'exact', network: 'eip155:196' }], extensions: [], signers: {} });
    return reply({ isValid: false, invalidReason: 'insufficient_funds' });
  });
  const h = harness(LIVE);
  const challenge = challengeOf(await h.post(CHIP));
  const res = await h.post(CHIP, undefined, { 'PAYMENT-SIGNATURE': payment(challenge) });
  assert.equal(res.status, 402);
  assert.equal(challengeOf(res).error, 'insufficient_funds');
  assert.equal(h.compiles.length, 0);
  assert.deepEqual(seen, ['supported', 'verify']);
});

// ------------------------------------------------------------------------------------------- settlement timeout

const TRANSFER = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
const pad = (address: string): string => `0x${'0'.repeat(24)}${address.slice(2).toLowerCase()}`;
const USDT0 = { address: '0x779ded0c9e1022225f8e0630b35a9b54be713736', name: 'USD₮0', version: '1', decimals: 6 } as const;
const cfg = { rpcUrls: ['https://rpc.example'], asset: USDT0, payTo: PAY_TO as `0x${string}`, amount: '500000' };

const rpcFetch = (receipt: unknown): typeof fetch =>
  (async () => new Response(JSON.stringify({ jsonrpc: '2.0', id: 1, result: receipt }), { status: 200 })) as typeof fetch;

const PAYER = '0x00000000000000000000000000000000000000Aa';
const NONCE = `0x${'5a'.repeat(32)}`;
const AUTHORIZATION_USED = '0x98de503528ee59b575ef0c0a2576a82497bfc029a5685b209e9ec333479b10a5';

const transferLog = (to: string, value: bigint, token: string = USDT0.address, from: string = PAYER) => ({
  address: token,
  topics: [TRANSFER, pad(from), pad(to)],
  data: `0x${value.toString(16).padStart(64, '0')}`,
});

// What USD₮0 emits for every EIP-3009 authorization it executes, next to the Transfer.
const authorizationUsedLog = (authorizer: string = PAYER, nonce: string = NONCE, token: string = USDT0.address) => ({
  address: token,
  topics: [AUTHORIZATION_USED, pad(authorizer), nonce],
  data: '0x',
});
const settled = (to: string, value: bigint) => ({ status: '0x1', logs: [authorizationUsedLog(), transferLog(to, value)] });

test('settlement timeout: the transfer is confirmed from the receipt only if it pays the payee the price in USDT0', async () => {
  const opts = { sleep: async () => {}, attempts: 2 };
  const ok = settled(PAY_TO, 500000n);
  assert.equal(await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch(ok) }), true);
  // More than the price is fine.
  assert.equal(await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch(settled(PAY_TO, 600000n)) }), true);

  // Too little, another payee, another token, a reverted transaction, no receipt, a malformed hash.
  assert.equal(await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch(settled(PAY_TO, 499999n)) }), false);
  assert.equal(await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch(settled('0x2222222222222222222222222222222222222222', 500000n)) }), false);
  assert.equal(await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch({ status: '0x1', logs: [authorizationUsedLog(), transferLog(PAY_TO, 500000n, '0x3333333333333333333333333333333333333333')] }) }), false);
  assert.equal(await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch({ ...settled(PAY_TO, 500000n), status: '0x0' }) }), false);
  assert.equal(await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch(null) }), false);
  assert.equal(await confirmTransferOnChain('MOCK-NOT-A-TRANSACTION-1', cfg, { ...opts, fetch: rpcFetch(ok) }), false);
});

// Review A-F6. Once PAY_TO is a contract that also receives other USD₮0 (a Covenant kernel receives its vault's tax
// claim every settle, and anyone's claimFor), a Transfer to PAY_TO of at least the price no longer proves that this
// buyer paid. The transfer must be the one an EIP-3009 authorization executed: USD₮0 emits AuthorizationUsed for the
// sender of that Transfer, and, when the payment's authorization is known, its `from` and nonce must match.
test('settlement timeout: a transfer to the payee that no EIP-3009 authorization executed does not confirm a payment', async () => {
  const opts = { sleep: async () => {}, attempts: 1 };
  const VAULT = '0x4444444444444444444444444444444444444444';
  // a vault claim (or a claimFor) paying the kernel more than the price: no AuthorizationUsed in the transaction
  const claim = { status: '0x1', logs: [transferLog(PAY_TO, 3_000_000n, USDT0.address, VAULT)] };
  assert.equal(await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch(claim) }), false);
  // an authorization by somebody else in the same transaction does not make the claim a payment
  const mixed = { status: '0x1', logs: [authorizationUsedLog(), transferLog(PAY_TO, 3_000_000n, USDT0.address, VAULT)] };
  assert.equal(await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch(mixed) }), false);
  // an AuthorizationUsed from another token contract does not count
  const foreign = { status: '0x1', logs: [authorizationUsedLog(PAYER, NONCE, '0x3333333333333333333333333333333333333333'), transferLog(PAY_TO, 500000n)] };
  assert.equal(await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch(foreign) }), false);
  // the real thing: the authorizer's own transfer, either log order
  assert.equal(await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch(settled(PAY_TO, 500000n)) }), true);
  const reversed = { status: '0x1', logs: [transferLog(PAY_TO, 500000n), authorizationUsedLog()] };
  assert.equal(await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch(reversed) }), true);

  // when the payment's authorization is known, its payer and nonce must be the ones on chain
  const known = { from: PAYER, nonce: NONCE };
  assert.equal(await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch(settled(PAY_TO, 500000n)) }, known), true);
  assert.equal(
    await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch(settled(PAY_TO, 500000n)) }, { from: '0x00000000000000000000000000000000000000Bb', nonce: NONCE }),
    false,
  );
  assert.equal(
    await confirmTransferOnChain(TX, cfg, { ...opts, fetch: rpcFetch(settled(PAY_TO, 500000n)) }, { from: PAYER, nonce: `0x${'6b'.repeat(32)}` }),
    false,
  );
});

test('settlement timeout end to end: OKX says timeout, the chain says paid, the result is delivered', async (t) => {
  const seen = fakeOkx(t, { success: false, status: 'timeout', transaction: TX, network: 'eip155:196' });
  // The harness hands this fetch to the on-chain check; OKX calls go through the mocked global fetch.
  // The SDK first polls OKX's settle/status (here for 50 ms instead of 5 s), which keeps answering "pending".
  const h = harness(
    { ...LIVE, RPC_URLS: 'https://rpc.example', X402_SETTLE_POLL_MS: '50' },
    { fetch: rpcFetch(settled(PAY_TO, 500000n)) },
  );
  const challenge = challengeOf(await h.post(CHIP, { preset: 'ok' }));
  const res = await h.post(CHIP, { preset: 'ok' }, { 'PAYMENT-SIGNATURE': payment(challenge) });
  assert.equal(res.status, 200);
  assert.equal(decodeHeader(res.headers.get('PAYMENT-RESPONSE'))['status'], 'success');
  assert.ok(seen.some((s) => s.url.includes('/settle/status?txHash=')), 'the facilitator was polled first');
  assert.ok(h.lines.some((l) => l['event'] === 'payment_settlement_timeout' && l['confirmedOnChain'] === true));
});

const paymentBy = (challenge: ReturnType<typeof challengeOf>, from: string, nonce: string): string =>
  Buffer.from(
    JSON.stringify({
      x402Version: 2,
      resource: challenge.resource,
      accepted: challenge.accepts[0],
      payload: { signature: '0xsigned', authorization: { from, to: PAY_TO, value: '500000', validAfter: '0', validBefore: '9999999999', nonce } },
    }),
  ).toString('base64');

test('settlement timeout end to end: the payment is checked against its own payer and nonce', async (t) => {
  fakeOkx(t, { success: false, status: 'timeout', transaction: TX, network: 'eip155:196' });
  const VAULT = '0x4444444444444444444444444444444444444444';
  // A receipt in which the payee only receives a claim from a vault: not this buyer's payment.
  const claimOnly = harness(
    { ...LIVE, RPC_URLS: 'https://rpc.example', X402_SETTLE_POLL_MS: '50' },
    { fetch: rpcFetch({ status: '0x1', logs: [transferLog(PAY_TO, 3_000_000n, USDT0.address, VAULT)] }) },
  );
  let challenge = challengeOf(await claimOnly.post(CHIP, { preset: 'ok' }));
  let res = await claimOnly.post(CHIP, { preset: 'ok' }, { 'PAYMENT-SIGNATURE': paymentBy(challenge, PAYER, NONCE) });
  assert.equal(res.status, 402);
  assert.doesNotMatch(await res.text(), /netlistHex/);
  assert.ok(claimOnly.lines.some((l) => l['event'] === 'payment_settlement_timeout' && l['confirmedOnChain'] === false && l['payerKnown'] === true));

  // Somebody else's authorization in the receipt: not this buyer's payment either.
  const otherNonce = harness(
    { ...LIVE, RPC_URLS: 'https://rpc.example', X402_SETTLE_POLL_MS: '50' },
    { fetch: rpcFetch(settled(PAY_TO, 500000n)) },
  );
  challenge = challengeOf(await otherNonce.post(CHIP, { preset: 'ok' }));
  res = await otherNonce.post(CHIP, { preset: 'ok' }, { 'PAYMENT-SIGNATURE': paymentBy(challenge, PAYER, `0x${'6b'.repeat(32)}`) });
  assert.equal(res.status, 402);

  // This buyer's authorization, executed: delivered.
  const paid = harness(
    { ...LIVE, RPC_URLS: 'https://rpc.example', X402_SETTLE_POLL_MS: '50' },
    { fetch: rpcFetch(settled(PAY_TO, 500000n)) },
  );
  challenge = challengeOf(await paid.post(CHIP, { preset: 'ok' }));
  res = await paid.post(CHIP, { preset: 'ok' }, { 'PAYMENT-SIGNATURE': paymentBy(challenge, PAYER, NONCE) });
  assert.equal(res.status, 200);
  assert.ok(paid.lines.some((l) => l['event'] === 'payment_settlement_timeout' && l['confirmedOnChain'] === true && l['payerKnown'] === true));
});

test('settlement timeout end to end: OKX says timeout and the chain has no such transfer: 402, nothing delivered', async (t) => {
  fakeOkx(t, { success: false, status: 'timeout', transaction: TX, network: 'eip155:196' });
  const h = harness({ ...LIVE, RPC_URLS: 'https://rpc.example', X402_SETTLE_POLL_MS: '50' }, { fetch: rpcFetch(null) });
  const challenge = challengeOf(await h.post(CHIP, { preset: 'ok' }));
  const res = await h.post(CHIP, { preset: 'ok' }, { 'PAYMENT-SIGNATURE': payment(challenge) });
  assert.equal(res.status, 402);
  assert.doesNotMatch(await res.text(), /netlistHex/);
  // The SDK forwards the facilitator's own answer in the receipt header.
  const receipt = decodeHeader(res.headers.get('PAYMENT-RESPONSE'));
  assert.equal(receipt['success'], false);
  assert.equal(receipt['status'], 'timeout');
  assert.equal(receipt['transaction'], TX);
  assert.ok(h.lines.some((l) => l['event'] === 'payment_settlement_timeout' && l['confirmedOnChain'] === false));
});
