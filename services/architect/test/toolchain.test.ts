// The toolchain adapter (src/toolchain.ts), the stub payload and the configuration that selects between them.

import assert from 'node:assert/strict';
import { join } from 'node:path';
import { test } from 'node:test';
import { ConfigError, loadConfig, splitCommand, toolchainConfig } from '../src/config.ts';
import { STUB_NETLIST_HEX, STUB_OUTPUTS, stubResult } from '../src/stub.ts';
import { CompileRejected, ToolchainError, childEnv, compilePreset, parseToolchainOutput, toolchainMode } from '../src/toolchain.ts';
import { FAKE_TAPC, HERE } from './helpers.ts';

const cli = (extra: Record<string, string> = {}) => toolchainConfig({ TAPC_CMD: FAKE_TAPC, ...extra });

// ------------------------------------------------------------------------------------------- stub mode

test('TAPC_CMD unset: stub mode, and compilePreset(preset, params) returns the fixed demo payload', async () => {
  const config = toolchainConfig({});
  assert.equal(config.command, null);
  assert.equal(toolchainMode(config), 'stub');

  const a = await compilePreset('flow-governor', { epochLen: 900 }, config);
  const b = await compilePreset('anything-else', {}, config);
  assert.equal(a.stub, true);
  assert.equal(a.netlistHex, b.netlistHex, 'the payload does not depend on the request');
  assert.deepEqual(Object.keys(a).sort(), ['cost', 'manifest', 'netlistHex', 'proofs', 'stub']);
  assert.equal(a.manifest['preset'], 'flow-governor');
  assert.equal(b.manifest['preset'], 'anything-else');
});

test('the stub netlist is the one that was checked against the TAP-20 reference implementation', () => {
  // 788 bytes: one LATCH record (4 bytes) and 112 NAND records (7 bytes each).
  assert.equal(STUB_NETLIST_HEX.length, 2 + 2 * 788);
  assert.ok(STUB_NETLIST_HEX.startsWith('0x01000062'), 'record 0 is LATCH d=98, its own output');
  const r = stubResult('p', {}, 20_000_000_000_000n);
  const m = r.manifest;
  // Verified on 2026-10-04 with chips/vendor/tap-20/reference.py, chips/tools/tapc/netlist.py (check, keccak256)
  // and chips/golden/kernel_model.py (the outputs decode to STUB_OUTPUTS and set no clamp bit).
  assert.equal(m['keccak256'], '0x69cfc16a9c811b90acaa1b64a763d545d60f421975fe9d93de8f89eb8179d0ae');
  assert.deepEqual(
    [m['format'], m['nIn'], m['nOut'], m['nState'], m['nNand'], m['nLatch'], m['gateCount'], m['signals'], m['bytes'], m['depth']],
    ['tapc-manifest/1', 96, 112, 1, 112, 1, 113, 211, 788, 1],
  );
  assert.equal((m['inputs'] as unknown[]).length, 96);
  assert.equal((m['outputs'] as unknown[]).length, 112);
  assert.deepEqual((m['outputs'] as Array<{ bit: number; name: string; signal: number }>)[0], { bit: 0, name: 'T_BUY[0]', signal: 99 });
  assert.deepEqual((m['inputs'] as Array<{ bit: number; name: string; signal: number }>)[80], { bit: 80, name: 'GRAD', signal: 82 });
  // Interface v1 limits.
  assert.ok(113 <= 3400 && 7 * 112 + 4 * 1 <= 24_000);
});

test('the stub outputs are a well-formed word: both share groups sum to 256', () => {
  const o = STUB_OUTPUTS;
  assert.equal(o['T_BUY']! + o['T_HOLD']! + o['T_ALLOW']! + o['T_RES']!, 256);
  assert.equal(o['V_BUY']! + o['V_HOLD']! + o['V_ALLOW']! + o['V_RES']!, 256);

  // Decode the constants straight from the netlist bytes: NAND(0,0) = 1, NAND(1,1) = 0.
  const bytes = Buffer.from(STUB_NETLIST_HEX.slice(2), 'hex');
  let word = 0n;
  for (let bit = 0; bit < 112; bit++) {
    const record = bytes.subarray(4 + 7 * bit, 4 + 7 * bit + 7);
    assert.equal(record[0], 0x00, 'NAND opcode');
    const a = record.readUIntBE(1, 3);
    const b = record.readUIntBE(4, 3);
    assert.ok(a === b && (a === 0 || a === 1));
    if (a === 0) word |= 1n << BigInt(bit);
  }
  const field = (offset: number, width: number): number => Number((word >> BigInt(offset)) & ((1n << BigInt(width)) - 1n));
  assert.deepEqual([field(0, 9), field(9, 9), field(18, 9), field(27, 9)], [128, 0, 0, 128]);
  assert.deepEqual([field(72, 9), field(81, 10)], [2, 1023]);
});

test('stub cost: transistors times the unit price', () => {
  const r = stubResult('p', {}, 20_000_000_000_000n);
  assert.equal(r.cost['transistors'], 113);
  assert.equal(r.cost['transistorCostWei'], '2260000000000000');
  assert.equal(r.cost['settleGasEstimate'], 250_000 + 48_000 + 2_300 * 113);
  assert.equal(stubResult('p', {}, 5n).cost['transistorCostWei'], '565');
});

// ------------------------------------------------------------------------------------------- CLI mode

test('TAPC_CMD set: the command gets one JSON request on stdin and its answer is returned', async () => {
  const r = await compilePreset('ok', { epochLen: 900, nested: { a: [1, 2] } }, cli(), {});
  assert.equal(r.stub, undefined);
  assert.equal(r.netlistHex, '0x0100006200000001000001');
  assert.deepEqual(r.manifest['params'], { epochLen: 900, nested: { a: [1, 2] } });
  assert.equal(r.manifest['protocol'], 'covenant-architect/1');
  assert.deepEqual(r.proofs, [{ id: 'shares-sum-256', status: 'proved' }]);
  assert.deepEqual(r.cost, { transistors: 2 });
});

test('the toolchain sees an allow-listed environment only: no credentials', async () => {
  const env = {
    PATH: process.env['PATH'],
    HOME: '/home/test',
    YOWASP_CACHE_DIR: '/var/cache/yowasp',
    PYTHONPATH: '/app/chips/tools',
    TAPC_SOMETHING: 'x',
    OKX_API_KEY: 'placeholder-api-key',
    OKX_SECRET_KEY: 'placeholder-secret-key',
    OKX_PASSPHRASE: 'placeholder-passphrase',
    PAY_TO: '0x1111111111111111111111111111111111111111',
    KEEPER_PRIVATE_KEY: 'placeholder',
    RAILWAY_TOKEN: 'placeholder',
  };
  const r = await compilePreset('env', {}, cli(), env);
  const keys = r.manifest['envKeys'] as string[];
  for (const forbidden of ['OKX_API_KEY', 'OKX_SECRET_KEY', 'OKX_PASSPHRASE', 'PAY_TO', 'KEEPER_PRIVATE_KEY', 'RAILWAY_TOKEN']) {
    assert.ok(!keys.includes(forbidden), `${forbidden} must not reach the toolchain`);
  }
  for (const allowed of ['HOME', 'YOWASP_CACHE_DIR', 'PYTHONPATH', 'TAPC_SOMETHING']) {
    assert.ok(keys.includes(allowed), `${allowed} is passed through`);
  }
  assert.deepEqual(r.manifest['argv'], [], 'no extra arguments are appended to TAPC_CMD');
  assert.deepEqual(Object.keys(childEnv(env)).sort(), ['HOME', 'PATH', 'PYTHONPATH', 'TAPC_SOMETHING', 'YOWASP_CACHE_DIR']);
});

test('TAPC_CWD sets the working directory', async () => {
  const r = await compilePreset('env', {}, cli({ TAPC_CWD: join(HERE, 'fixtures') }), {});
  assert.match(String(r.manifest['cwd']), /fixtures$/);
});

test('a rejection is a CompileRejected with the diagnostics, whatever the exit code', async () => {
  await assert.rejects(compilePreset('reject', {}, cli(), {}), (e: unknown) => {
    assert.ok(e instanceof CompileRejected);
    assert.deepEqual([e.code, e.stage, e.message], ['unknown_param', 'validate', 'epochLen must be at least 300']);
    assert.equal(e.diagnostics[0]?.path, 'params.epochLen');
    return true;
  });
  await assert.rejects(compilePreset('reject-exit', {}, cli(), {}), (e: unknown) => e instanceof CompileRejected && e.code === 'unknown_preset');
});

test('ok:true with a failed proof is a rejection, never a success', async () => {
  await assert.rejects(compilePreset('failed-proof', {}, cli(), {}), (e: unknown) => {
    assert.ok(e instanceof CompileRejected);
    assert.equal(e.code, 'proof_failed');
    assert.equal(e.proofs?.length, 2);
    return true;
  });
});

test('faults of the toolchain are ToolchainError with a kind', async () => {
  const kind = async (preset: string, config = cli()): Promise<string> => {
    try {
      await compilePreset(preset, {}, config, {});
      return 'no error';
    } catch (e) {
      return e instanceof ToolchainError ? e.kind : `other: ${String(e)}`;
    }
  };
  assert.equal(await kind('crash'), 'crash');
  assert.equal(await kind('garbage'), 'bad_output');
  assert.equal(await kind('big'), 'bad_output');
  assert.equal(await kind('bad-hex'), 'bad_output');
  assert.equal(await kind('no-ok'), 'bad_output');
  assert.equal(await kind('slow', cli({ TAPC_TIMEOUT_MS: '1000' })), 'timeout');
  assert.equal(await kind('ok', toolchainConfig({ TAPC_CMD: '/nonexistent/covenant-tapc --flag' })), 'spawn');
  // A command that exits without reading its input must not break the service (EPIPE).
  assert.equal(await kind('ok', toolchainConfig({ TAPC_CMD: `${JSON.stringify(process.execPath)} -e "process.exit(4)"` })), 'crash');
});

test('stderr is kept for the server log on a crash', async () => {
  await assert.rejects(compilePreset('crash', {}, cli(), {}), (e: unknown) => e instanceof ToolchainError && /Traceback/.test(e.stderrTail));
});

test('parseToolchainOutput: the shapes it accepts and refuses', () => {
  const good = { ok: true, netlistHex: '0x00', manifest: {}, proofs: [], cost: {} };
  assert.deepEqual(parseToolchainOutput(JSON.stringify(good), 0), { netlistHex: '0x00', manifest: {}, proofs: [], cost: {} });
  // Extra top-level fields are dropped; a skipped proof is fine.
  assert.deepEqual(
    parseToolchainOutput(JSON.stringify({ ...good, extra: 1, proofs: [{ id: 'x', status: 'skipped' }] }), 0).proofs,
    [{ id: 'x', status: 'skipped' }],
  );
  const bad = (doc: unknown, code = 0): string => {
    try {
      parseToolchainOutput(typeof doc === 'string' ? doc : JSON.stringify(doc), code);
      return 'accepted';
    } catch (e) {
      return e instanceof ToolchainError ? e.kind : e instanceof CompileRejected ? `rejected:${e.code}` : 'other';
    }
  };
  assert.equal(bad(''), 'bad_output');
  assert.equal(bad('', 1), 'crash');
  assert.equal(bad([]), 'bad_output');
  assert.equal(bad({ ...good, ok: 'yes' }), 'bad_output');
  assert.equal(bad(good, 1), 'crash'); // ok:true but a non-zero exit is not trusted
  assert.equal(bad({ ...good, netlistHex: '0x' }), 'bad_output');
  assert.equal(bad({ ...good, netlistHex: '0x0' }), 'bad_output');
  assert.equal(bad({ ...good, netlistHex: `0x${'00'.repeat(24_000)}` }), 'accepted');
  assert.equal(bad({ ...good, netlistHex: `0x${'00'.repeat(24_001)}` }), 'bad_output');
  assert.equal(bad({ ...good, manifest: [] }), 'bad_output');
  assert.equal(bad({ ...good, proofs: {} }), 'bad_output');
  assert.equal(bad({ ...good, cost: null }), 'bad_output');
  assert.equal(bad({ ok: false }), 'rejected:rejected');
  assert.equal(bad({ ok: false, error: { code: 'too_many_gates' } }, 2), 'rejected:too_many_gates');
});

// ------------------------------------------------------------------------------------------- configuration

test('splitCommand: whitespace, quotes and escapes, no shell', () => {
  assert.deepEqual(splitCommand('python -m tapc architect'), ['python', '-m', 'tapc', 'architect']);
  assert.deepEqual(splitCommand('  /app/.venv/bin/python   -m tapc  '), ['/app/.venv/bin/python', '-m', 'tapc']);
  assert.deepEqual(splitCommand('"/path with spaces/python" \'-c\' "a b"'), ['/path with spaces/python', '-c', 'a b']);
  assert.deepEqual(splitCommand('a\\ b "c \\" d" \'e \\ f\''), ['a b', 'c " d', 'e \\ f']);
  assert.deepEqual(splitCommand('tool ""'), ['tool', '']);
  // Shell syntax is plain text here.
  assert.deepEqual(splitCommand('tapc; rm -rf / $(whoami) | cat'), ['tapc;', 'rm', '-rf', '/', '$(whoami)', '|', 'cat']);
  assert.throws(() => splitCommand('python "unterminated'), ConfigError);
});

test('general configuration errors are ConfigError; paid problems are reasons', () => {
  assert.throws(() => loadConfig({ PORT: 'eighty' }), ConfigError);
  assert.throws(() => loadConfig({ BODY_LIMIT_BYTES: '1' }), ConfigError);
  assert.throws(() => loadConfig({ TAPC_TIMEOUT_MS: '999999' }), ConfigError);
  assert.throws(() => loadConfig({ DEFAULT_PRESET: 'Not Valid' }), ConfigError);
  assert.throws(() => loadConfig({ PUBLIC_BASE_URL: 'architect.example' }), ConfigError);
  assert.throws(() => loadConfig({ LOG_LEVEL: 'loud' }), ConfigError);
  assert.throws(() => loadConfig({ TRUST_PROXY: 'maybe' }), ConfigError);

  const c = loadConfig({});
  assert.equal(c.port, 8787);
  assert.equal(c.bodyLimitBytes, 16_384);
  assert.equal(c.freeRatePerMinute, 10);
  assert.equal(c.trustProxy, false);
  assert.equal(c.defaultPreset, 'flow-governor');
  assert.equal(c.paid.mode, 'live');
  assert.equal(c.paid.amount, '500000');
  assert.equal(c.paid.syncSettle, true);
  assert.equal(c.paid.maxTimeoutSeconds, 300);
  assert.deepEqual(c.paid.reasons, [
    'PAY_TO is not set',
    'OKX_API_KEY, OKX_SECRET_KEY, OKX_PASSPHRASE are not set',
    'TAPC_CMD is not set: the toolchain is a stub, and the paid route does not sell stub output',
  ]);
});

test('on Railway the proxy is trusted and the public URL comes from RAILWAY_PUBLIC_DOMAIN', () => {
  const c = loadConfig({ RAILWAY_ENVIRONMENT_NAME: 'production', RAILWAY_PUBLIC_DOMAIN: 'covenant-architect.up.railway.app', PORT: '8080' });
  assert.equal(c.trustProxy, true);
  assert.equal(c.publicBaseUrl, 'https://covenant-architect.up.railway.app');
  assert.equal(c.port, 8080);
  // An explicit PUBLIC_BASE_URL wins, and a trailing slash is dropped.
  assert.equal(loadConfig({ RAILWAY_PUBLIC_DOMAIN: 'x.up.railway.app', PUBLIC_BASE_URL: 'https://architect.covenant.example/' }).publicBaseUrl, 'https://architect.covenant.example');
});

test('mock mode needs no credentials and defaults the payee to the burn address', () => {
  const c = loadConfig({ X402_MODE: 'mock' });
  assert.deepEqual(c.paid.reasons, []);
  assert.equal(c.paid.payTo, '0x000000000000000000000000000000000000dEaD');
  assert.equal(c.paid.okx, null);
});
