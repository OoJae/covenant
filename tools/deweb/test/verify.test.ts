// The checks behind verify.ts that need no network: site names, the comparison of a local build with the chain,
// the gateway's conditions for showing a site, the Content-Security-Policy against what Covenant's site needs,
// and the verdict. Offline.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { assumeFresh } from '../src/chain.ts';
import { chunkCountOf, loadSite } from '../src/site.ts';
import { COVENANT_NEEDS, checkResolution, checkSelfConsistent, compareLocalWithChain, cspAllows, firstDifference, gatewayOrigin, parseSite, verdictOf, type ChainSite } from '../src/verify.ts';

/**
 * The policy tapekit.org's Service Worker puts on every file of a site (sw.js version 0.3.0, `siteCsp`, fetched
 * from https://tapekit.org/sw.js on 2026-10-04 and again on 2026-10-06; unchanged).
 */
const GATEWAY_SITE_CSP = [
  "default-src 'self' blob: data:",
  "script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:",
  "style-src 'self' 'unsafe-inline' blob: data: https:",
  "img-src 'self' blob: data: https:",
  "font-src 'self' blob: data: https:",
  "media-src 'self' blob: data: https:",
  "connect-src 'self' blob: data: https: wss:",
  "frame-src 'self' https:",
  "worker-src 'self' blob:",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self' https:",
  "frame-ancestors 'self'",
  'report-uri /.tape/csp-report',
].join('; ');

const SITE = fileURLToPath(new URL('../sim/test/fixtures/site', import.meta.url));

test('site names: label, on-chain name, short name, display label, gateway URL', () => {
  for (const s of ['1-2-283', '1.2.283.tape', '1.2.283', '#1@2.283', 'https://1-2-283.tapekit.org/#/kernel', 'tape://1.2.283.tape/index.html']) {
    assert.deepEqual(parseSite(s), { circuitId: 1n, processorNumber: 283 }, s);
  }
  assert.throws(() => parseSite('1-3-283'), /area code 3 is not X Layer/);
  assert.throws(() => parseSite('covenant'), /not an X Layer site name/);
  assert.throws(() => parseSite('01-2-283'), /not an X Layer site name/);
  const t = assumeFresh('0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b', 1n, 283, '0x84cE7bAe1b788C7aD985D57721cA428b401aE34D');
  assert.equal(gatewayOrigin(t), 'https://1-2-283.tapekit.org');
  assert.equal(gatewayOrigin(t, 'http://{label}.localhost:8096'), 'http://1-2-283.localhost:8096');
});

test("the gateway's policy allows everything Covenant's site does", () => {
  for (const need of COVENANT_NEEDS) {
    const r = cspAllows(GATEWAY_SITE_CSP, need);
    assert.ok(r.allowed, `${need.what}: ${r.by}`);
  }
  // and refuses what it must: a script from another origin
  assert.equal(cspAllows(GATEWAY_SITE_CSP, { what: 'a CDN script', directive: 'script-src', source: 'https://cdn.example' }).allowed, false);
  assert.equal(cspAllows("default-src 'none'", COVENANT_NEEDS[0]).allowed, false);
  assert.equal(cspAllows("connect-src https://rpc.xlayer.tech", COVENANT_NEEDS[5]).allowed, false);
});

function chainOf(files: ReturnType<typeof loadSite>): ChainSite {
  return {
    paths: files.map((f) => f.path),
    fallback: '',
    files: files.map((f) => ({ path: f.path, info: { size: f.data.length, contentType: f.contentType, sha256: f.sha256, updatedAt: 1, chunkCount: chunkCountOf(f.data.length) }, data: f.data, sha256: f.sha256, state: 'ok' as const })),
  };
}

test('local build against the chain: identical, then each kind of difference', () => {
  const local = loadSite(SITE);
  assert.equal(compareLocalWithChain(local, chainOf(local), false).status, 'MATCH');
  assert.equal(checkSelfConsistent(chainOf(local)).status, 'MATCH');
  const changed = chainOf(local);
  changed.files[0].data = new Uint8Array([...changed.files[0].data.slice(0, 5), 0x00, ...changed.files[0].data.slice(6)]);
  assert.match(compareLocalWithChain(local, changed, false).detail, /app\.js: byte 5 differs/);
  const missing = chainOf(local.slice(1));
  assert.match(compareLocalWithChain(local, missing, false).detail, /app\.js: not on chain/);
  const extra = chainOf(local);
  extra.paths.push('old.html');
  assert.equal(compareLocalWithChain(local, extra, false).status, 'MISMATCH');
  assert.equal(compareLocalWithChain(local, extra, true).status, 'MATCH');
  const unhashed = chainOf(local);
  unhashed.files[0].info.sha256 = '0x' + '0'.repeat(64);
  assert.match(checkSelfConsistent(unhashed).detail, /no SHA-256 declared/);
  assert.equal(firstDifference(new Uint8Array([1, 2]), new Uint8Array([1, 2, 3]), 'a', 'b'), 'length differs (a 2 bytes, b 3 bytes; identical up to the shorter one)');
});

test("the gateway's conditions: opened, accepted implementations, name activated", () => {
  const t = assumeFresh('0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b', 1n, 283, '0x84cE7bAe1b788C7aD985D57721cA428b401aE34D');
  assert.match(checkResolution(t).detail, /not opened.*HTTP 404/);
  assert.match(checkResolution({ ...t, opened: true }).detail, /not activated \(it was never paid\).*HTTP 402/);
  assert.match(checkResolution({ ...t, opened: true, implementationsAccepted: false }).detail, /store-changed/);
  const now = 1_800_000_000;
  assert.equal(checkResolution({ ...t, opened: true, live: true, paidUntil: now + 30 * 86_400 }, now).status, 'MATCH');
});

test('the verdict: a difference wins, an unperformed check is never a match', () => {
  const ok = { name: 'a', status: 'MATCH' as const, detail: '', lines: [] };
  const no = { name: 'b', status: 'NOT CHECKED' as const, detail: 'no browser', lines: [] };
  const bad = { name: 'c', status: 'MISMATCH' as const, detail: 'x', lines: [] };
  assert.equal(verdictOf([ok]).exitCode, 0);
  assert.equal(verdictOf([ok, no]).exitCode, 3);
  assert.match(verdictOf([ok, no]).line, /^NOT FULLY VERIFIED/);
  assert.equal(verdictOf([ok, no, bad]).exitCode, 1);
  assert.match(verdictOf([ok], ['the gateway']).line, /Left out on request: the gateway/);
});
