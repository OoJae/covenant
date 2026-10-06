// The service against the REAL chip toolchain (`python -m tapc.architect`), not the fake one in fixtures/.
//
// Opt-in: one Flow Governor compile with its proofs takes half a minute or more and needs the Python
// environment of chips/. Without TAPC_E2E_CMD every test here is skipped, so `pnpm test` stays fast.
//
//   cd services/architect
//   TAPC_E2E_CMD="$PWD/../../chips/.venv/bin/python -m tapc.architect" TAPC_E2E_CWD="$PWD/../../chips/tools" \
//     node --test test/toolchain-real.test.ts
//
// chips/tools/tests/test_architect.py::test_service_adapter_against_the_real_toolchain runs exactly this.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { keccak256 } from 'viem';
import { toolchainConfig } from '../src/config.ts';
import { CompileRejected, compilePreset } from '../src/toolchain.ts';
import { ROOT, harness } from './helpers.ts';

const CMD = process.env['TAPC_E2E_CMD'];
const CWD = process.env['TAPC_E2E_CWD'];
const skip = CMD ? false : 'TAPC_E2E_CMD is not set (the real toolchain test is opt-in)';
const CHIPS = join(ROOT, '..', '..', 'chips');

/** The service's own configuration path: TAPC_CMD is split without a shell, the child gets the allow-listed env. */
const ENV: Record<string, string> = { TAPC_CMD: CMD ?? '', TAPC_TIMEOUT_MS: '120000', ...(CWD ? { TAPC_CWD: CWD } : {}) };
const compile = (preset: string, params: Record<string, unknown>) =>
  compilePreset(preset, params, toolchainConfig(ENV), process.env);

type Proof = { id: string; group: string; status: string };
type Answer = { netlistHex: string; manifest: Record<string, unknown>; proofs: Proof[]; cost: Record<string, unknown> };

test('stock flow-governor: the committed chip, byte for byte, with its proofs and cost', { skip }, async () => {
  const t0 = Date.now();
  const r = (await compile('flow-governor', {})) as Answer;
  const seconds = (Date.now() - t0) / 1000;

  const tap = readFileSync(join(CHIPS, 'out', 'fg.tap'));
  assert.equal(r.netlistHex, `0x${tap.toString('hex')}`, 'the netlist is chips/out/fg.tap');
  assert.equal(r.manifest['keccak256'], keccak256(r.netlistHex as `0x${string}`));
  assert.equal(r.manifest['keccak256'], '0xe548768a1adafa7331faacfd029e1a829b00af3f7d769657f3b234ccdd7143b4');
  assert.equal(r.manifest['format'], 'tapc-manifest/1');

  const arch = r.manifest['architect'] as { preset: string; params: object; pinManifest: { sha256: string; content: string } };
  assert.equal(arch.preset, 'flow-governor');
  assert.deepEqual(arch.params, {});
  assert.equal(arch.pinManifest.content, readFileSync(join(CHIPS, 'out', 'fg.pins.json'), 'utf8'));
  assert.equal(arch.pinManifest.sha256, '0xfe8b7a49a7d0f9a75d0684b88587648284fc586f936035f8831cb6d34060e209');

  assert.equal(r.proofs.filter((p) => p.status === 'failed').length, 0);
  for (const g of ['P1', 'P2', 'P3', 'P4']) {
    const rows = r.proofs.filter((p) => p.group === g);
    assert.ok(rows.length > 0 && rows.every((p) => p.status === 'proved'), `${g} proved`);
  }
  assert.equal(r.proofs.find((p) => p.id === 'EQ.rtl_equals_bytes.yosys')?.status, 'proved');

  assert.equal(r.cost['transistors'], 1952);
  assert.equal(r.cost['totalOKB'], '0.04166');
  assert.ok(seconds < 120, `compiled in ${seconds} s, inside TAPC_TIMEOUT_MS`);
  process.stdout.write(`# stock flow-governor through the adapter: ${seconds.toFixed(1)} s\n`);
});

test('a bad parameter is a CompileRejected with the toolchain diagnostics (HTTP 422, not charged)', { skip }, async () => {
  await assert.rejects(compile('flow-governor', { AL0: '99', M1: 'x' }), (err: unknown) => {
    assert.ok(err instanceof CompileRejected);
    assert.equal(err.code, 'invalid_params');
    assert.equal(err.stage, 'validate');
    assert.deepEqual(err.diagnostics.map((d) => [d.code, d.path]), [['range', 'params.AL0'], ['type', 'params.M1']]);
    return true;
  });
  await assert.rejects(compile('flow-gov', {}), (err: unknown) => err instanceof CompileRejected && err.code === 'unknown_preset');
  await assert.rejects(compile('glutton', { capT: 48 }), (err: unknown) => err instanceof CompileRejected && err.code === 'invalid_params');
});

test('over HTTP: free route 200 (cli), 422 for bad params, and a mock-paid call settles', { skip }, async () => {
  const h = harness({ ...ENV, X402_MODE: 'mock' }, { compile });

  const ok = await h.post('/v1/architect/compile', { preset: 'glutton', params: {} });
  assert.equal(ok.status, 200);
  assert.equal(ok.headers.get('X-Covenant-Toolchain'), 'cli');
  const doc = (await ok.json()) as Answer & { stub?: boolean };
  assert.equal(doc.stub, undefined);
  assert.equal(doc.netlistHex, `0x${readFileSync(join(CHIPS, 'cells', 'glutton', 'glutton.tap')).toString('hex')}`);
  assert.ok(doc.proofs.length === 10 && doc.proofs.every((p) => p.status === 'proved'));

  const bad = await h.post('/v1/architect/compile', { preset: 'flow-governor', params: { M1: 999 } });
  assert.equal(bad.status, 422);
  const err = ((await bad.json()) as { error: { code: string; diagnostics: Array<{ path: string }> } }).error;
  assert.equal(err.code, 'invalid_params');
  assert.equal(err.diagnostics[0]?.path, 'params.M1');

  const paid = await h.payMock({ preset: 'glutton' });
  assert.equal(paid.status, 200);
  assert.ok(paid.headers.get('PAYMENT-RESPONSE'), 'settled after the real compile');
  assert.equal(paid.headers.get('X-Covenant-X402-Mode'), 'mock');
});
