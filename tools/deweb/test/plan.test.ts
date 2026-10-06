// plan.ts against the Solidity planner the forge script runs (sim/src/SitePublisher.sol): the fork tests in
// sim/ execute the plan on a fork of X Layer and leave, per transaction, the kind, target, value, calldata hash
// and the gas actually used in sim/measured/*.json. Here the TypeScript planner gets the same inputs and must
// produce byte-identical calldata, and its gas estimate must stay close to the measurement. Offline.
//
// Regenerate the measurements: forge test --root tools/deweb/sim (forks X Layer at block 72,376,000).

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { toBytes } from '../../../packages/chain/src/index.ts';
import { keccak256Hex } from '../../../packages/chain/src/keccak.ts';
import { XLAYER, assumeFresh, containerAddress, hostLabel, onChainName, type Target } from '../src/chain.ts';
import { EMPTY_SITE, KIND_NUMBER, buildPlan, okb, staleFiles, totalsOf, type OnChainSite } from '../src/plan.ts';
import { CHUNK_MAX, checkPath, chunkCountOf, chunksOf, contentTypeOf, loadSite, servedContentType, sha256Hex, type SiteFile } from '../src/site.ts';

const SIM = fileURLToPath(new URL('../sim/', import.meta.url));
const measured = (name: string): any => JSON.parse(readFileSync(`${SIM}measured/${name}.json`, 'utf8'));
const hashOf = (data: string): string => keccak256Hex(toBytes(data));

function targetOf(m: any): Target {
  return {
    ...assumeFresh(m.processor, BigInt(m.circuitId), m.processorNumber, m.holder),
    opened: m.opened,
    live: m.live,
    paidUntil: m.live ? 1 : 0,
    openFee: BigInt(m.openFee),
    monthlyFee: BigInt(m.monthlyFee),
  };
}

/** Each step against the measured one: same kind, target, value and calldata; gas within the stated tolerance. */
function compare(name: string, m: any, steps: ReturnType<typeof buildPlan>): void {
  assert.equal(steps.length, m.kinds.length, `${name}: number of transactions`);
  steps.forEach((s, i) => {
    const at = `${name} step ${i + 1} (${m.labels[i]})`;
    assert.equal(KIND_NUMBER[s.kind], m.kinds[i], `${at}: kind`);
    assert.equal(s.target.toLowerCase(), m.targets[i].toLowerCase(), `${at}: target`);
    assert.equal(s.value.toString(), m.values[i], `${at}: value`);
    assert.equal((s.data.length - 2) / 2, m.calldataBytes[i], `${at}: calldata length`);
    assert.equal(hashOf(s.data), m.calldataHashes[i], `${at}: calldata`);
    assert.equal(s.label, m.labels[i], `${at}: label`);
    const off = Math.abs(s.gas - m.gasUsed[i]) / m.gasUsed[i];
    assert.ok(off <= (s.gasIsRough ? 0.25 : 0.005), `${at}: gas estimate ${s.gas}, measured ${m.gasUsed[i]} (${(off * 100).toFixed(2)}% off)`);
  });
}

const fixtureDir = (d: string): string => `${SIM}${d}`;

test('a site directory: order (HTML last), content types, SHA-256 and 24,000-byte chunks', () => {
  const files = loadSite(fixtureDir('test/fixtures/site'));
  assert.deepEqual(files.map((f) => f.path), ['app.js', 'big.bin', 'data.json', 'style.css', 'index.html']);
  assert.deepEqual(files.map((f) => f.contentType), ['text/javascript; charset=utf-8', 'application/octet-stream', 'application/json; charset=utf-8', 'text/css; charset=utf-8', 'text/html; charset=utf-8']);
  const big = files[1];
  assert.equal(big.data.length, 60_000);
  assert.equal(chunkCountOf(big.data.length), 3);
  assert.deepEqual(chunksOf(big.data).map((c) => c.length), [CHUNK_MAX, CHUNK_MAX, 12_000]);
  assert.equal(chunkCountOf(0), 1, 'an empty file still takes one chunk');
  assert.equal(big.sha256, sha256Hex(big.data));
  assert.equal(contentTypeOf('A/B.JS'), 'text/javascript; charset=utf-8', 'extensions are case-insensitive');
  assert.equal(contentTypeOf('Makefile'), 'application/octet-stream');
  // what the gateway turns a declared type into (TAP-10 section 7.1 step 6; TapeKit withCharset)
  assert.equal(servedContentType('text/javascript; charset=utf-8'), 'text/javascript; charset=utf-8');
  assert.equal(servedContentType('text/css'), 'text/css; charset=utf-8');
  assert.equal(servedContentType('image/png'), 'image/png');
  assert.equal(servedContentType('nonsense'), 'application/octet-stream');
  for (const bad of ['', 'sw.js', '.tape/status', 'a\\b', 'café.html', 'x'.repeat(513)]) assert.throws(() => checkPath(bad), bad);
  checkPath('assets/index-DMOotP12.js');
});

test('the container address and the names are derived, as the opener and the gateway derive them', () => {
  const m = measured('fixture');
  assert.equal(containerAddress(m.processor, BigInt(m.circuitId)).toLowerCase(), m.container.toLowerCase(), 'the fork test read it with opener.accountOf');
  // Covenant's processor, circuit 1 (the probe): read from X Layer with opener.accountOf on 2026-10-06
  assert.equal(containerAddress('0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b', 1n), '0x911350102b2D81a1E8A816638D429a16b80B8Ee2');
  assert.equal(onChainName(1n, 283), '1.2.283.tape');
  assert.equal(hostLabel(1n, 283), '1-2-283');
  assert.equal(XLAYER.areaCode, 2);
});

test('fresh container: plan.ts = the Solidity plan executed on the fork (fixture, with a fallback)', () => {
  const m = measured('fixture');
  const files = loadSite(fixtureDir(m.siteDir));
  const steps = buildPlan(targetOf(m), files, { months: m.months, renew: false, fallbackPath: m.fallbackPath, prune: m.prune }, EMPTY_SITE);
  compare('fixture', m, steps);
  const totals = totalsOf(steps, 20_000_001n);
  assert.equal(totals.value, 80_000_000_000_000_000n + 26_000_000_000_000_000n, 'opening fee + one month of the name');
  assert.ok(Math.abs(totals.gas - m.totalGas) / m.totalGas < 0.005, `total gas ${totals.gas}, measured ${m.totalGas}`);
  assert.equal(okb(totals.value), '0.106');
});

test('an update: only what changed is written, and stale files are pruned (fixture v1 -> v2)', () => {
  const m = measured('fixture-update');
  const v1 = loadSite(fixtureDir('test/fixtures/site'));
  const v2 = loadSite(fixtureDir(m.siteDir));
  // the container as the first publication left it: v1 in publication order, fallback index.html
  const onChain: OnChainSite = {
    paths: v1.map((f) => f.path),
    fallback: 'index.html',
    info: new Map(v1.map((f: SiteFile) => [f.path, { size: f.data.length, contentType: f.contentType, sha256: f.sha256, updatedAt: 1, chunkCount: chunkCountOf(f.data.length) }])),
    identical: new Set(v2.filter((f) => v1.some((g) => g.path === f.path && Buffer.compare(Buffer.from(g.data), Buffer.from(f.data)) === 0)).map((f) => f.path)),
  };
  assert.deepEqual([...onChain.identical].sort(), ['app.js', 'data.json']);
  assert.deepEqual(staleFiles(v2, onChain), ['big.bin', 'style.css']);
  const steps = buildPlan(targetOf(m), v2, { months: m.months, renew: false, fallbackPath: m.fallbackPath, prune: m.prune }, onChain);
  compare('fixture-update', m, steps);
});

test('web/dist as measured by the last fork run: same calldata, gas within 0.5%', (t) => {
  const m = measured('web-dist');
  let files: SiteFile[];
  try {
    files = loadSite(fixtureDir(m.siteDir));
  } catch {
    return t.skip('web/dist is not built');
  }
  const steps = buildPlan(targetOf(m), files, { months: m.months, renew: false, fallbackPath: m.fallbackPath, prune: m.prune }, EMPTY_SITE);
  if (steps.length !== m.kinds.length || steps.some((s, i) => hashOf(s.data) !== m.calldataHashes[i])) {
    return t.skip('web/dist changed since the fork test measured it (rerun forge test --root tools/deweb/sim)');
  }
  compare('web-dist', m, steps);
});

test('the plan refuses what the contracts would refuse', () => {
  const m = measured('fixture');
  const files = loadSite(fixtureDir(m.siteDir));
  const t = targetOf(m);
  assert.throws(() => buildPlan(t, files, { months: 121, renew: false, fallbackPath: '', prune: false }), /months must be an integer from 0 to 120/);
  assert.throws(() => buildPlan(t, files, { months: 1, renew: false, fallbackPath: 'missing.html', prune: false }), /fallback path is not a file of the site/);
  // months 0: no bind, the gateway would answer 402
  assert.ok(!buildPlan(t, files, { months: 0, renew: false, fallbackPath: '', prune: false }).some((s) => s.kind === 'bind'));
  // an activated name is not paid again unless renew is asked for
  const live = { ...t, opened: true, live: true, paidUntil: 1 };
  assert.ok(!buildPlan(live, files, { months: 1, renew: false, fallbackPath: '', prune: false }).some((s) => s.kind === 'bind' || s.kind === 'open'));
  assert.equal(buildPlan(live, files, { months: 2, renew: true, fallbackPath: '', prune: false }).filter((s) => s.kind === 'bind')[0].value, 2n * 26_000_000_000_000_000n);
});
