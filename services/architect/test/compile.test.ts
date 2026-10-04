// GET /healthz and POST /v1/architect/compile (free): shape, validation, rate limiting, body limit.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { RateLimiter, clientAddress } from '../src/ratelimit.ts';
import { FAKE_TAPC, harness } from './helpers.ts';

const FREE = '/v1/architect/compile';

test('GET /healthz is 200 and reports the toolchain and paywall state without secrets', async () => {
  const h = harness({});
  const res = await h.app.request('/healthz');
  assert.equal(res.status, 200);
  const doc = (await res.json()) as Record<string, unknown>;
  assert.equal(doc['ok'], true);
  assert.equal(doc['service'], 'covenant-architect');
  assert.deepEqual(doc['toolchain'], { mode: 'stub' });
  const paid = doc['paid'] as Record<string, unknown>;
  assert.equal(paid['mode'], 'live');
  assert.equal(paid['ready'], false);
  assert.equal(paid['priceUsd'], '0.50');
  assert.equal(paid['network'], 'eip155:196');
});

test('GET / lists the endpoints; unknown paths are 404 JSON', async () => {
  const h = harness({});
  const index = (await (await h.app.request('/')).json()) as { endpoints: Record<string, string> };
  assert.deepEqual(Object.keys(index.endpoints), ['GET /healthz', 'POST /v1/architect/compile', 'POST /v1/architect/chip']);
  const missing = await h.app.request('/v1/architect/draft', { method: 'POST' });
  assert.equal(missing.status, 404);
  assert.equal(((await missing.json()) as { error: { code: string } }).error.code, 'not_found');
});

test('free compile, stub mode: {netlistHex, manifest, proofs, cost}, clearly marked as a stub', async () => {
  const h = harness({});
  const res = await h.post(FREE, { preset: 'flow-governor', params: { epochLen: 900 } });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('X-Covenant-Toolchain'), 'stub');
  const doc = (await res.json()) as { stub: boolean; netlistHex: string; manifest: Record<string, unknown>; proofs: Array<Record<string, unknown>>; cost: Record<string, unknown> };
  assert.equal(doc.stub, true);
  assert.equal(doc.manifest['stub'], true);
  assert.match(String(doc.manifest['warning']), /^STUB OUTPUT/);
  assert.equal(doc.manifest['preset'], 'flow-governor');
  assert.deepEqual(doc.manifest['params'], { epochLen: 900 });
  assert.deepEqual(doc.proofs.map((p) => p['status']), ['skipped']);
  assert.equal(doc.cost['transistors'], 113);
});

test('free compile through the subprocess adapter', async () => {
  const h = harness({ TAPC_CMD: FAKE_TAPC });
  const res = await h.post(FREE, { preset: 'ok', params: { capT: 64 } });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('X-Covenant-Toolchain'), 'cli');
  const doc = (await res.json()) as Record<string, unknown>;
  assert.deepEqual(Object.keys(doc).sort(), ['cost', 'manifest', 'netlistHex', 'proofs']);
  const manifest = doc['manifest'] as Record<string, unknown>;
  // What the toolchain received on stdin.
  assert.equal(manifest['protocol'], 'covenant-architect/1');
  assert.equal(manifest['op'], 'compile');
  assert.deepEqual(manifest['params'], { capT: 64 });
});

test('the preset defaults, and params may be omitted or sent as JSON text', async () => {
  const h = harness({ TAPC_CMD: FAKE_TAPC, DEFAULT_PRESET: 'ok', COMPILE_CACHE_ENTRIES: '0' });
  assert.equal((await h.post(FREE)).status, 200); // no body at all
  assert.equal((await h.post(FREE, {})).status, 200);
  assert.equal((await h.post(FREE, { preset: 'ok', params: '{"epochLen":"900"}' })).status, 200);
  // A body sent without a JSON content type (plain `curl -d`) is still read as JSON.
  assert.equal((await h.post(FREE, '{"preset":"ok"}', { 'content-type': 'application/x-www-form-urlencoded' })).status, 200);
  assert.deepEqual(h.compiles, [
    { preset: 'ok', params: {} },
    { preset: 'ok', params: {} },
    { preset: 'ok', params: { epochLen: '900' } },
    { preset: 'ok', params: {} },
  ]);
});

test('invalid requests are 400 with a description of the inputs', async () => {
  const h = harness({ RATE_LIMIT_PER_MIN: '100' });
  const cases: Array<[string, RegExp]> = [
    ['{"preset":', /not valid JSON/],
    ['"just a string"', /must be a JSON object/],
    ['{"preset":42}', /preset must be a lowercase name/],
    ['{"preset":"../etc/passwd"}', /preset must be a lowercase name/],
    ['{"preset":"UPPER"}', /preset must be a lowercase name/],
    [`{"preset":"${'a'.repeat(65)}"}`, /preset must be a lowercase name/],
    ['{"params":[1]}', /params must be a JSON object/],
    ['{"params":"[1]"}', /params must be a JSON object/],
    ['{"params":"{broken"}', /not JSON text of an object/],
    ['{"dsl":"x"}', /Unknown field "dsl"/],
    [JSON.stringify({ params: { a: { b: { c: { d: { e: { f: { g: { h: { i: 1 } } } } } } } } } }), /nested deeper/],
    [JSON.stringify({ params: Object.fromEntries(Array.from({ length: 600 }, (_, i) => [`k${i}`, i])) }), /more than 500 values/],
  ];
  for (const [body, pattern] of cases) {
    const res = await h.post(FREE, body);
    assert.equal(res.status, 400, body.slice(0, 40));
    const doc = (await res.json()) as { error: { code: string; message: string }; parameters: Record<string, { default: unknown }> };
    assert.match(doc.error.message, pattern);
    assert.equal(doc.parameters['preset']?.default, 'flow-governor');
  }
  assert.equal(h.compiles.length, 0);
});

test('toolchain outcomes map to 422, 502 and 504', async () => {
  const h = harness({ TAPC_CMD: FAKE_TAPC, RATE_LIMIT_PER_MIN: '100' });
  const rejected = await h.post(FREE, { preset: 'reject', params: { epochLen: 1 } });
  assert.equal(rejected.status, 422);
  assert.deepEqual(await rejected.json(), {
    error: {
      code: 'unknown_param',
      message: 'epochLen must be at least 300',
      stage: 'validate',
      diagnostics: [{ code: 'range', path: 'params.epochLen', message: 'too small', hint: 'use 300 or more' }],
      charged: false,
    },
  });

  const proof = await h.post(FREE, { preset: 'failed-proof' });
  assert.equal(proof.status, 422);
  const proofDoc = (await proof.json()) as { error: { code: string; proofs: Array<{ status: string }> } };
  assert.equal(proofDoc.error.code, 'proof_failed');
  assert.deepEqual(proofDoc.error.proofs.map((p) => p.status), ['proved', 'failed']);

  const crash = await h.post(FREE, { preset: 'crash' });
  assert.equal(crash.status, 502);
  const crashText = await crash.text();
  assert.doesNotMatch(crashText, /Traceback/, 'stderr of the toolchain stays in the server log');
  assert.ok(h.lines.some((l) => l['event'] === 'compile_toolchain_fault' && /Traceback/.test(String(l['stderr']))));
});

test('a toolchain that overruns TAPC_TIMEOUT_MS is killed and answered with 504', async () => {
  const h = harness({ TAPC_CMD: FAKE_TAPC, TAPC_TIMEOUT_MS: '1000' });
  const t0 = Date.now();
  const res = await h.post(FREE, { preset: 'slow' });
  assert.equal(res.status, 504);
  assert.equal(((await res.json()) as { error: { code: string } }).error.code, 'toolchain_timeout');
  assert.ok(Date.now() - t0 < 10_000, 'did not wait for the toolchain');
});

// ------------------------------------------------------------------------------------------- cache

test('an identical request is served from the cache; the order of keys in params does not matter', async () => {
  const h = harness({ TAPC_CMD: FAKE_TAPC, RATE_LIMIT_PER_MIN: '100' });
  const first = await h.post(FREE, { preset: 'ok', params: { a: 1, b: { x: [1, 2], y: 2 } } });
  assert.equal(first.status, 200);
  assert.equal(first.headers.get('X-Covenant-Cache'), 'miss');

  const second = await h.post(FREE, { preset: 'ok', params: { b: { y: 2, x: [1, 2] }, a: 1 } });
  assert.equal(second.status, 200);
  assert.equal(second.headers.get('X-Covenant-Cache'), 'hit');
  assert.deepEqual(await second.json(), await first.json());
  assert.equal(h.compiles.length, 1, 'the toolchain ran once');

  // Different params, a different array order, or another preset are different requests.
  await h.post(FREE, { preset: 'ok', params: { a: 2, b: { x: [1, 2], y: 2 } } });
  await h.post(FREE, { preset: 'ok', params: { a: 1, b: { x: [2, 1], y: 2 } } });
  await h.post(FREE, { preset: 'env', params: { a: 1, b: { x: [1, 2], y: 2 } } });
  assert.equal(h.compiles.length, 4);
});

test('failures are never cached', async () => {
  const h = harness({ TAPC_CMD: FAKE_TAPC });
  assert.equal((await h.post(FREE, { preset: 'reject' })).status, 422);
  assert.equal((await h.post(FREE, { preset: 'reject' })).status, 422);
  assert.equal((await h.post(FREE, { preset: 'crash' })).status, 502);
  assert.equal((await h.post(FREE, { preset: 'crash' })).status, 502);
  assert.equal(h.compiles.length, 4);
});

test('identical requests that arrive together share one toolchain run', async () => {
  let runs = 0;
  let release: (() => void) | undefined;
  const gate = new Promise<void>((r) => (release = r));
  const h = harness(
    { MAX_CONCURRENT_COMPILES: '1', TAPC_CMD: FAKE_TAPC },
    {
      compile: async () => {
        runs += 1;
        await gate;
        return { netlistHex: '0x00', manifest: {}, proofs: [], cost: {} };
      },
    },
  );
  const a = h.post(FREE, { preset: 'ok', params: { n: 1 } });
  const b = h.post(FREE, { preset: 'ok', params: { n: 1 } });
  await new Promise((r) => setTimeout(r, 20));
  // A different request does need its own run, and the only slot is taken.
  assert.equal((await h.post(FREE, { preset: 'ok', params: { n: 2 } })).status, 503);
  release?.();
  assert.deepEqual([(await a).status, (await b).status], [200, 200]);
  assert.equal(runs, 1);
});

test('the cache is bounded and can be switched off', async () => {
  const small = harness({ TAPC_CMD: FAKE_TAPC, COMPILE_CACHE_ENTRIES: '2', RATE_LIMIT_PER_MIN: '100' });
  for (const n of [1, 2, 3]) await small.post(FREE, { preset: 'ok', params: { n } });
  // 1 was evicted; 2 and 3 are still there.
  assert.equal((await small.post(FREE, { preset: 'ok', params: { n: 3 } })).headers.get('X-Covenant-Cache'), 'hit');
  assert.equal((await small.post(FREE, { preset: 'ok', params: { n: 2 } })).headers.get('X-Covenant-Cache'), 'hit');
  assert.equal((await small.post(FREE, { preset: 'ok', params: { n: 1 } })).headers.get('X-Covenant-Cache'), 'miss');

  const off = harness({ TAPC_CMD: FAKE_TAPC, COMPILE_CACHE_ENTRIES: '0' });
  await off.post(FREE, { preset: 'ok' });
  assert.equal((await off.post(FREE, { preset: 'ok' })).headers.get('X-Covenant-Cache'), 'miss');
  assert.equal(off.compiles.length, 2);
});

test('a compile cached by the free route is what the paid route sells, and it is still settled', async () => {
  const h = harness({ X402_MODE: 'mock', TAPC_CMD: FAKE_TAPC });
  const free = await h.post(FREE, { preset: 'ok', params: { n: 7 } });
  const paid = await h.payMock({ preset: 'ok', params: { n: 7 } });
  assert.equal(paid.status, 200);
  assert.equal(paid.headers.get('X-Covenant-Cache'), 'hit');
  assert.deepEqual(await paid.json(), await free.json());
  assert.equal(h.compiles.length, 1);
  assert.equal(h.paywall.mock?.calls.settle, 1);
});

// ------------------------------------------------------------------------------------------- rate limiting

test('the free route is rate-limited per client address', async () => {
  const h = harness({ RATE_LIMIT_PER_MIN: '3', TRUST_PROXY: '1' });
  const from = (ip: string): Promise<Response> => h.post(FREE, {}, { 'x-real-ip': ip });

  for (let i = 0; i < 3; i++) {
    const res = await from('203.0.113.7');
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('RateLimit-Limit'), '3');
    assert.equal(res.headers.get('RateLimit-Remaining'), String(2 - i));
  }
  const limited = await from('203.0.113.7');
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get('Retry-After'), '60');
  assert.equal(limited.headers.get('RateLimit-Remaining'), '0');
  const doc = (await limited.json()) as { error: { code: string; retryAfterSeconds: number } };
  assert.deepEqual([doc.error.code, doc.error.retryAfterSeconds], ['rate_limited', 60]);
  assert.equal(h.compiles.length, 3, 'the fourth request never reached the compiler');

  // Another client is not affected.
  assert.equal((await from('203.0.113.8')).status, 200);

  // Still limited later in the same window, with a shorter wait; free again when the window is over.
  h.clock.advance(45_000);
  const later = await from('203.0.113.7');
  assert.equal(later.status, 429);
  assert.equal(later.headers.get('Retry-After'), '15');
  h.clock.advance(15_000);
  assert.equal((await from('203.0.113.7')).status, 200);
});

test('without a trusted proxy the forwarding headers are ignored (a client cannot pick its own bucket)', async () => {
  const h = harness({ RATE_LIMIT_PER_MIN: '2', TRUST_PROXY: '0' });
  assert.equal((await h.post(FREE, {}, { 'x-real-ip': '198.51.100.1' })).status, 200);
  assert.equal((await h.post(FREE, {}, { 'x-real-ip': '198.51.100.2' })).status, 200);
  assert.equal((await h.post(FREE, {}, { 'x-forwarded-for': '198.51.100.3' })).status, 429);
});

test('the paid route has its own, separate limit', async () => {
  const h = harness({ X402_MODE: 'mock', RATE_LIMIT_PER_MIN: '1', PAID_RATE_LIMIT_PER_MIN: '2', TRUST_PROXY: '1' });
  const ip = { 'x-real-ip': '203.0.113.9' };
  assert.equal((await h.post('/v1/architect/chip', undefined, ip)).status, 402);
  assert.equal((await h.post('/v1/architect/chip', undefined, ip)).status, 402);
  assert.equal((await h.post('/v1/architect/chip', undefined, ip)).status, 429);
  // The free route's budget was not touched.
  assert.equal((await h.post(FREE, {}, ip)).status, 200);
});

test('clientAddress: X-Real-IP, then the last X-Forwarded-For entry, then the socket', async () => {
  const h = harness({});
  const seen: string[] = [];
  h.app.get('/ip-trusted', (c) => {
    seen.push(clientAddress(c, true, () => '10.0.0.1'));
    return c.text('ok');
  });
  h.app.get('/ip-untrusted', (c) => {
    seen.push(clientAddress(c, false, () => '10.0.0.1'));
    return c.text('ok');
  });
  await h.app.request('/ip-trusted', { headers: { 'x-real-ip': '203.0.113.1', 'x-forwarded-for': '1.1.1.1, 2.2.2.2' } });
  await h.app.request('/ip-trusted', { headers: { 'x-forwarded-for': '1.1.1.1, 2.2.2.2' } });
  await h.app.request('/ip-trusted', { headers: { 'x-real-ip': 'not an address; drop table' } });
  await h.app.request('/ip-trusted');
  await h.app.request('/ip-untrusted', { headers: { 'x-real-ip': '203.0.113.1' } });
  assert.deepEqual(seen, ['203.0.113.1', '2.2.2.2', '10.0.0.1', '10.0.0.1', '10.0.0.1']);
});

test('RateLimiter: fixed window, bounded memory', () => {
  let t = 0;
  const limiter = new RateLimiter(2, 1000, () => t, 3);
  assert.deepEqual(limiter.take('a'), { allowed: true, limit: 2, remaining: 1, resetSeconds: 1 });
  assert.equal(limiter.take('a').allowed, true);
  assert.equal(limiter.take('a').allowed, false);
  t = 999;
  assert.equal(limiter.take('a').allowed, false);
  t = 1000;
  assert.equal(limiter.take('a').allowed, true);

  // Many distinct clients cannot grow the table past its bound.
  for (let i = 0; i < 50; i++) limiter.take(`client-${i}`);
  assert.ok(limiter.size <= 3);
});

// ------------------------------------------------------------------------------------------- body limit

test('a body over BODY_LIMIT_BYTES is refused with 413 on both routes', async () => {
  const h = harness({ X402_MODE: 'mock', BODY_LIMIT_BYTES: '256' });
  const big = JSON.stringify({ preset: 'flow-governor', params: { note: 'x'.repeat(400) } });
  for (const path of [FREE, '/v1/architect/chip']) {
    const res = await h.post(path, big);
    assert.equal(res.status, 413, path);
    assert.equal(((await res.json()) as { error: { code: string } }).error.code, 'body_too_large');
  }
  assert.equal(h.compiles.length, 0);
  assert.equal((await h.post(FREE, { preset: 'flow-governor' })).status, 200);
});

test('GET on the compile route is 405', async () => {
  const h = harness({});
  const res = await h.app.request(FREE);
  assert.equal(res.status, 405);
  assert.equal(res.headers.get('allow'), 'POST');
});

test('CORS preflight is answered for browser clients', async () => {
  const h = harness({});
  const res = await h.app.request(FREE, {
    method: 'OPTIONS',
    headers: { origin: 'https://covenant.example', 'access-control-request-method': 'POST', 'access-control-request-headers': 'content-type' },
  });
  assert.equal(res.status, 204);
  assert.equal(res.headers.get('access-control-allow-origin'), '*');
  assert.match(res.headers.get('access-control-allow-headers') ?? '', /PAYMENT-SIGNATURE/);
});
