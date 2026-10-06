// The USD₮0 mode: a launch quoted in USD₮0 is approved only against the v2 kernel the deployment file names
// (contracts/core-v2, written by deploy/launch-kernel-v2.sh); every other rule is kernel v1's. Offline: the chain is
// the table server of helpers.ts, extended with a v2 kernel, its KernelFactoryV2 and USD₮0.
//
// The refusal matrix for the new quote is the last test: each row changes one thing about a good USD₮0 launch (or
// about the chain or the files) and names exactly the checks that must fail.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { UsageError, chooseGeneration, parseExpected, withDeployment, withDeploymentV2 } from '../args.ts';
import { DEFAULT_EXPECTED, USDT0, calldataLines, formatQuote, type Expected } from '../checks.ts';
import { MANAGER, selectorOf } from '../decode.ts';
import { hasKernelV2, missingPartsV2, parseDeployment } from '../deployment.ts';
import { addressWord, show, strip0x, word } from '../hex.ts';
import { GLOBALS_V2_FIELDS, encodeStruct, type GlobalsV2 } from '../kernel-abi.ts';
import { inputFile } from '../simulate.ts';
import { CHIP_ID, CIRCUITS, FAB, GLOBALS, KERNEL, KERNEL_FACTORY, LAUNCHER, SEALED_VM, TRANSISTORS, goodWorld, launch, serve, setCall, type LaunchOptions, type MockRpc, type World } from './helpers.ts';

const CLI = fileURLToPath(new URL('../launch-check.ts', import.meta.url));
const KERNEL_V2 = '0x00000000000000000000000000000000c0fe0011';
const KERNEL_FACTORY_V2 = '0x00000000000000000000000000000000c0fe0015';
const LENS = '0x00000000000000000000000000000000c0fe0009';
const LENS_V2 = '0x00000000000000000000000000000000c0fe0019';
const CHIP_ID_V2 = 9n;
const WOKB = '0xe538905cf8410324e03a5a23c1c177a474d59b2b';
const ZERO = '0x0000000000000000000000000000000000000000';

const GLOBALS_V2: GlobalsV2 = (() => {
  const { wokb: _wokb, ...rest } = GLOBALS;
  return { ...rest, quote: USDT0, factory: KERNEL_FACTORY_V2, chipId: CHIP_ID_V2, quoteShift: 33n };
})();

const w32 = (v: bigint | number): string => '0x' + word(v);
const a32 = (a: string): string => '0x' + addressWord(a);
const argAddress = (data: string, i: number): string => '0x' + strip0x(data).slice(8 + 64 * i + 24, 8 + 64 * i + 64);

/** goodWorld (the v1 kernel) plus a v2 kernel, its factory, its chip, and USD₮0 balances. */
function v2World(now: bigint): World {
  const world = goodWorld(now);
  world.code.set(KERNEL_V2, '0x' + '60'.repeat(45));
  world.code.set(KERNEL_FACTORY_V2, '0x' + '60'.repeat(80));
  world.code.set(USDT0, '0x' + '60'.repeat(80));
  setCall(world, KERNEL_V2, 'token()', a32(ZERO));
  setCall(world, KERNEL_V2, 'chipId()', w32(CHIP_ID_V2));
  setCall(world, KERNEL_V2, 'envelope()', world.calls.get(`${KERNEL}:${selectorOf('envelope()')}`) as string);
  setCall(world, KERNEL_V2, 'globals()', encodeStruct(GLOBALS_V2_FIELDS, { ...GLOBALS_V2 }));
  setCall(world, CIRCUITS, 'ownerOf(uint256)', (data) => {
    const id = BigInt('0x' + strip0x(data).slice(8));
    return id === CHIP_ID ? a32(KERNEL) : id === CHIP_ID_V2 ? a32(KERNEL_V2) : null;
  });
  setCall(world, KERNEL_FACTORY_V2, 'isKernel(address)', (data) => w32(argAddress(data, 0) === KERNEL_V2 ? 1 : 0));
  setCall(world, USDT0, 'balanceOf(address)', () => w32(0));
  setCall(world, USDT0, 'allowance(address,address)', () => w32(0));
  return world;
}

const NESTED = {
  chainId: 196,
  note: 'test',
  deployer: LAUNCHER,
  issuance: { splitter: '0x00000000000000000000000000000000c0fe00a0', transistors: TRANSISTORS, circuits: CIRCUITS, keeperTank: '0x00000000000000000000000000000000c0fe0004', teamRegistry: '0x00000000000000000000000000000000c0fe00a1' },
  evaluator: { sealedVM: SEALED_VM, fab: FAB, txs: [] },
  core: { kernelFactory: KERNEL_FACTORY, kernelImpl: '0x00000000000000000000000000000000c0fe000a', lens: LENS, txs: [] },
  flagship: { chipId: Number(CHIP_ID), kernel: KERNEL, txs: [] },
};
const NESTED_V2 = {
  ...NESTED,
  coreV2: { kernelFactory: KERNEL_FACTORY_V2, kernelImpl: '0x00000000000000000000000000000000c0fe001a', lens: LENS_V2, quote: '0x779Ded0c9e1022225f8E0630b35a9b54bE713736', quoteShift: 33, txs: [] },
  flagshipV2: { chipId: Number(CHIP_ID_V2), kernel: KERNEL_V2, allowancePayee: '0x00000000000000000000000000000000c0fe0004', txs: [] },
};

const usdLaunch = (now: bigint, o: LaunchOptions = {}): string =>
  launch({ now, ...o, p: { quote: USDT0, graduation: 8_000_000_000n, ...o.p }, call: { vaultData: '0x' + addressWord(KERNEL_V2), ...o.call } }).data;

// ───────────────────────────── the deployment file and the choice of kernel ─────────────────────────────

test('the deployment file: kernel v2 from coreV2 / flagshipV2 (nested) and from the flat keys of deploy/rehearsal-v2.json', () => {
  const nested = parseDeployment(JSON.stringify(NESTED_V2), 'nested');
  assert.equal(nested.kernelV2, KERNEL_V2);
  assert.equal(nested.kernelFactoryV2, KERNEL_FACTORY_V2);
  assert.equal(nested.lensV2, LENS_V2);
  assert.equal(nested.chipIdV2, CHIP_ID_V2);
  assert.equal(nested.quoteV2, USDT0);
  assert.equal(nested.quoteShiftV2, 33n);
  assert.equal(nested.kernel, KERNEL, 'kernel v1 is read as before');
  assert.equal(hasKernelV2(nested), true);
  const flat = parseDeployment(JSON.stringify({ deployer: LAUNCHER, circuits: CIRCUITS, kernelFactoryV2: KERNEL_FACTORY_V2, lensV2: LENS_V2, kernelV2: KERNEL_V2, chipIdV2: 9, quoteV2: USDT0, quoteShiftV2: 33 }), 'flat');
  assert.equal(flat.format, 'flat');
  assert.equal(flat.kernelV2, KERNEL_V2);
  assert.equal(flat.chipIdV2, 9n);
  assert.equal(hasKernelV2(flat), true);
  const v1Only = parseDeployment(JSON.stringify(NESTED), 'v1');
  assert.equal(hasKernelV2(v1Only), false);
  assert.deepEqual(missingPartsV2(v1Only).map((m) => m.part), ['coreV2', 'flagshipV2']);
  assert.throws(() => parseDeployment(JSON.stringify({ ...NESTED_V2, flagshipV2: { kernel: KERNEL_V2 } })), /names a v2 kernel but not its chipId/);
  assert.throws(() => parseDeployment(JSON.stringify({ ...NESTED_V2, coreV2: undefined })), /names a v2 kernel but not its KernelFactoryV2/);
  assert.throws(() => parseDeployment(JSON.stringify({ ...NESTED_V2, coreV2: { ...NESTED_V2.coreV2, quoteShift: 'x' } })), /coreV2.quoteShift must be a whole number/);
});

test('kernel v2 is chosen only for a USD₮0 quote AND a deployment that names a v2 kernel', () => {
  const now = 1_791_150_000n;
  const d2 = parseDeployment(JSON.stringify(NESTED_V2), 'nested v2');
  const d1 = parseDeployment(JSON.stringify(NESTED), 'nested v1');
  const usd = usdLaunch(now);
  const okb = launch({ now }).data;
  const wokb = launch({ now, p: { quote: WOKB } }).data;
  assert.equal(chooseGeneration(DEFAULT_EXPECTED, d2, usd), 'v2');
  assert.equal(chooseGeneration(DEFAULT_EXPECTED, d1, usd), 'v1', 'no v2 kernel: kernel v1, whose quote rule refuses USD₮0');
  assert.equal(chooseGeneration(DEFAULT_EXPECTED, null, usd), 'v1');
  assert.equal(chooseGeneration(DEFAULT_EXPECTED, d2, okb), 'v1');
  assert.equal(chooseGeneration(DEFAULT_EXPECTED, d2, wokb), 'v1', 'another ERC-20: kernel v1, which refuses it');
  assert.equal(chooseGeneration(DEFAULT_EXPECTED, d2, '0xdeadbeef'), 'v1', 'undecodable calldata');
  // an expected-values file decides, not the calldata
  const pinsOkb = parseExpected(JSON.stringify({ quote: ZERO }));
  const pinsUsd = parseExpected(JSON.stringify({ quote: USDT0 }));
  assert.equal(chooseGeneration(pinsOkb, d2, usd), 'v1');
  assert.equal(chooseGeneration(pinsUsd, d2, okb), 'v2');
  assert.throws(() => chooseGeneration(pinsUsd, d1, usd), (e: unknown) => e instanceof UsageError && /records no complete kernel v2/.test(e.message));
  assert.throws(() => parseExpected(JSON.stringify({ quote: WOKB })), /quote must be the zero address \(native OKB, kernel v1\) or USD₮0/);
  // the expected values each generation is checked against
  const e2 = withDeploymentV2(DEFAULT_EXPECTED, d2);
  assert.deepEqual([e2.generation, e2.kernel, e2.kernelFactory, e2.chipId, e2.quoteShift, e2.fab, e2.sealedVM, e2.circuits], ['v2', KERNEL_V2, KERNEL_FACTORY_V2, CHIP_ID_V2, 33n, FAB, SEALED_VM, CIRCUITS]);
  const e1 = withDeployment(DEFAULT_EXPECTED, d2);
  assert.deepEqual([e1.generation, e1.kernel, e1.kernelFactory, e1.chipId], ['v1', KERNEL, KERNEL_FACTORY, CHIP_ID]);
  assert.throws(() => withDeploymentV2(parseExpected(JSON.stringify({ kernel: KERNEL })), d2), /the expected-values file says the kernel is/);
  assert.throws(() => withDeploymentV2(DEFAULT_EXPECTED, parseDeployment(JSON.stringify({ ...NESTED_V2, coreV2: { ...NESTED_V2.coreV2, quote: WOKB } }))), /not USD₮0/);
});

test('amounts of a USD₮0 launch are shown in USD₮0 (6 decimals); the calldata rules of kernel v2', () => {
  assert.equal(formatQuote(8_000_000_000n, 'v2'), '8000 USD₮0 (8000000000 base units)');
  assert.equal(formatQuote(500_000n, 'v2'), '0.5 USD₮0 (500000 base units)');
  assert.equal(formatQuote(10n ** 18n, 'v1'), '1 OKB (1000000000000000000 wei)');
  const now = 1_791_150_000n;
  const e2: Expected = { ...DEFAULT_EXPECTED, generation: 'v2', kernel: KERNEL_V2 };
  const tx = (data: string, value = 0n) => ({ from: LAUNCHER, to: MANAGER, value, data, kernel: KERNEL_V2 });
  const failed = (data: string, value = 0n): string[] => calldataLines(tx(data, value), e2).lines.filter((l) => l.kind === 'check' && !l.ok).map((l) => l.label);
  assert.deepEqual(failed(usdLaunch(now)), []);
  const lines = calldataLines(tx(usdLaunch(now)), e2).lines;
  assert.ok(lines.some((l) => l.kind === 'info' && l.label === 'graduation target' && l.value.startsWith('8000 USD₮0')));
  assert.ok(lines.some((l) => l.kind === 'info' && l.label === 'kernel generation' && l.value.startsWith('v2 (contracts/core-v2)')));
  assert.deepEqual(failed(usdLaunch(now), 1n), ['msg.value is 0 (a USD₮0 launch pays its listing fee in USD₮0)']);
  assert.deepEqual(failed(usdLaunch(now, { p: { listingFee: 1_000_000n } }), 1_000_000n), ['msg.value is 0 (a USD₮0 launch pays its listing fee in USD₮0)'], 'the fee is never paid in OKB');
  assert.deepEqual(failed(usdLaunch(now, { p: { firstBuy: 5_000_000n } })), ['firstBuy is 0 (no team buy)']);
  assert.deepEqual(failed(launch({ now, call: { vaultData: '0x' + addressWord(KERNEL_V2) } }).data), ["quote is USD₮0 (the v2 kernel's quote asset)"]);
  assert.deepEqual(failed('0x1234'), ['function selector is createToken', 'calldata decodes as createToken arguments', 'calldata carries nothing beyond its arguments', 'templateId is 3 (Directed vault)', 'vault recipient is the kernel', "quote is USD₮0 (the v2 kernel's quote asset)", 'venue is 1 (Uniswap V2)', 'curve fees are 100 / 100 bps', 'buy tax and sell tax are the expected values', 'protection period is the expected value', 'firstBuy is 0 (no team buy)', 'msg.value is 0 (a USD₮0 launch pays its listing fee in USD₮0)', 'anti-snipe is off (snipeStartBps 0)', 'no founder round (founderBps 0, founderSecs 0, no founder root)']);
});

test('simulate.ts hands forge the v2 deployment (KernelFactoryV2, LensV2, the v2 chip, USD₮0 and its shift)', () => {
  const d2 = parseDeployment(JSON.stringify(NESTED_V2), 'nested v2');
  const tx = { from: LAUNCHER, to: MANAGER, value: 0n, data: '0x', kernel: KERNEL_V2 };
  const v2 = JSON.parse(inputFile(tx, 0, false, d2, 'v2'));
  assert.deepEqual(v2.deployment, { kernelFactory: KERNEL_FACTORY_V2, circuits: CIRCUITS, fab: FAB, sealedVM: SEALED_VM, lens: LENS_V2, chipId: '9', quote: USDT0, quoteShift: '33' });
  const v1 = JSON.parse(inputFile({ ...tx, kernel: KERNEL }, 0, false, d2));
  assert.deepEqual(v1.deployment, { kernelFactory: KERNEL_FACTORY, circuits: CIRCUITS, fab: FAB, sealedVM: SEALED_VM, lens: LENS, chipId: String(CHIP_ID) }, 'kernel v1 input unchanged (no quote key: native OKB)');
});

// ───────────────────────────── the CLI against a table chain ─────────────────────────────

interface Result {
  code: number | null;
  stdout: string;
  stderr: string;
}
const cli = (args: readonly string[]): Promise<Result> =>
  new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [CLI, ...args], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });
const failedLabels = (out: string): string[] => out.split('\n').filter((l) => l.startsWith('FAIL  ')).map((l) => l.slice(6).replace(/: .*$/, ''));

let dir: string;
const now = BigInt(Math.floor(Date.now() / 1000));
before(() => {
  dir = mkdtempSync(join(tmpdir(), 'launch-check-usdt0-'));
  writeFileSync(join(dir, 'v2.json'), JSON.stringify(NESTED_V2));
  writeFileSync(join(dir, 'v1.json'), JSON.stringify(NESTED));
  writeFileSync(join(dir, 'pins-usd.json'), JSON.stringify({ quote: USDT0 }));
  writeFileSync(join(dir, 'pins-okb.json'), JSON.stringify({ quote: ZERO }));
});
after(() => rmSync(dir, { recursive: true, force: true }));

async function runCli(o: { data: string; value?: string; kernel?: string; deployment?: string; expected?: string; change?: (w: World) => void }): Promise<Result> {
  const world = v2World(now);
  o.change?.(world);
  const rpc: MockRpc = await serve(world);
  try {
    const f = join(dir, `data-${Math.random().toString(16).slice(2)}.txt`);
    writeFileSync(f, o.data);
    return await cli([
      '--deployment',
      join(dir, o.deployment ?? 'v2.json'),
      '--from',
      LAUNCHER,
      '--to',
      MANAGER,
      '--value',
      o.value ?? '0',
      '--data',
      '@' + f,
      ...(o.kernel ? ['--kernel', o.kernel] : []),
      ...(o.expected ? ['--expected', join(dir, o.expected)] : []),
      '--rpc',
      rpc.url,
    ]);
  } finally {
    await rpc.close();
  }
}

test('a good USD₮0 launch to the deployment\'s v2 kernel passes every check, kernel v2 checks included', async () => {
  const r = await runCli({ data: usdLaunch(now) });
  assert.equal(r.code, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /^VERDICT: PASS\. All \d+ checks passed\./m);
  for (const line of [
    `      kernel ${show(KERNEL_V2)}`,
    '      kernel generation: v2 (contracts/core-v2)',
    `PASS  vault recipient is the kernel: ${show(KERNEL_V2)}`,
    `PASS  quote is USD₮0 (the v2 kernel's quote asset): ${show(USDT0)}`,
    'PASS  msg.value is 0 (a USD₮0 launch pays its listing fee in USD₮0)',
    `PASS  kernel was created by the Covenant KernelFactoryV2 (isKernel): isKernel = true at ${show(KERNEL_FACTORY_V2)}`,
    "PASS  kernel's globals name the deployment's KernelFactoryV2, Fab, SealedVM",
    `PASS  kernel quotes in USD₮0 with the 33-bit code shift (globals().quote, globals().quoteShift): quote ${show(USDT0)}, shift 33 bits`,
    'PASS  launcher can pay the USD₮0 listing fee (balance and allowance to the IgnixManager): listing fee 0: createToken pulls no USD₮0',
    `PASS  kernel holds its chip (Circuits.ownerOf(kernel.chipId()) is the kernel): chip ${CHIP_ID_V2} is owned by ${show(KERNEL_V2)}`,
    `PASS  kernel's chip is the deployment's chip: chip ${CHIP_ID_V2}`,
    '      graduation target: 8000 USD₮0 (8000000000 base units)',
  ]) {
    assert.ok(r.stdout.includes(line), `${line}\n---\n${r.stdout}`);
  }
  // the same launch file, the OKB launch of kernel v1, is still checked against kernel v1 with the same deployment
  const v1 = await runCli({ data: launch({ now }).data });
  assert.equal(v1.code, 0, v1.stdout);
  assert.ok(v1.stdout.includes(`PASS  quote is native OKB (the zero address): ${show(ZERO)}`));
  assert.ok(!v1.stdout.includes('kernel generation'));
});

test('the refusal matrix for the USD₮0 quote: each row names exactly the checks that fail', async () => {
  const good = usdLaunch(now);
  const toV1 = usdLaunch(now, { call: { vaultData: '0x' + addressWord(KERNEL) } });
  const rows: { name: string; run: Parameters<typeof runCli>[0]; fail: string[] | RegExp; code?: number }[] = [
    { name: 'USD₮0 launch, recipient = the v1 kernel', run: { data: toV1 }, fail: ['vault recipient is the kernel'] },
    { name: 'OKB launch, recipient = the v2 kernel', run: { data: launch({ now, call: { vaultData: '0x' + addressWord(KERNEL_V2) } }).data }, fail: ['vault recipient is the kernel'] },
    { name: 'another ERC-20 (WOKB), recipient = the v2 kernel', run: { data: launch({ now, p: { quote: WOKB }, call: { vaultData: '0x' + addressWord(KERNEL_V2) } }).data }, fail: ['vault recipient is the kernel', 'quote is native OKB (the zero address)'] },
    { name: 'USD₮0 launch, the deployment names no v2 kernel', run: { data: toV1, deployment: 'v1.json' }, fail: ['quote is native OKB (the zero address)'] },
    { name: 'USD₮0 launch, msg.value 1 wei', run: { data: good, value: '1' }, fail: ['msg.value is 0 (a USD₮0 launch pays its listing fee in USD₮0)'] },
    { name: 'USD₮0 launch with a first buy of 5 USD₮0', run: { data: usdLaunch(now, { p: { firstBuy: 5_000_000n } }) }, fail: ['firstBuy is 0 (no team buy)'] },
    { name: 'USD₮0 listing fee 1 USD₮0, no allowance to the Manager', run: { data: usdLaunch(now, { p: { listingFee: 1_000_000n } }) }, fail: ['launcher can pay the USD₮0 listing fee (balance and allowance to the IgnixManager)'] },
    {
      name: '--kernel: the v1 kernel for a USD₮0 launch to it',
      run: { data: toV1, kernel: KERNEL },
      fail: /kernel is the one the deployment \/ expected-values file names.*kernel was created by the Covenant KernelFactoryV2 \(isKernel\)/s,
    },
    { name: 'the v2 kernel has a 32-bit shift', run: { data: good, change: (w) => setCall(w, KERNEL_V2, 'globals()', encodeStruct(GLOBALS_V2_FIELDS, { ...GLOBALS_V2, quoteShift: 32n })) }, fail: ['kernel quotes in USD₮0 with the 33-bit code shift (globals().quote, globals().quoteShift)'] },
    { name: 'the v2 kernel quotes in WOKB', run: { data: good, change: (w) => setCall(w, KERNEL_V2, 'globals()', encodeStruct(GLOBALS_V2_FIELDS, { ...GLOBALS_V2, quote: WOKB })) }, fail: ['kernel quotes in USD₮0 with the 33-bit code shift (globals().quote, globals().quoteShift)'] },
    { name: 'the v2 kernel was not created by the KernelFactoryV2', run: { data: good, change: (w) => setCall(w, KERNEL_FACTORY_V2, 'isKernel(address)', () => w32(0)) }, fail: ['kernel was created by the Covenant KernelFactoryV2 (isKernel)'] },
    { name: 'the v2 kernel is already bound', run: { data: good, change: (w) => setCall(w, KERNEL_V2, 'token()', a32('0x00000000000000000000000000000000c0fe00bb')) }, fail: ['kernel is not bound yet (token() is the zero address)'] },
    { name: 'the v2 kernel answers kernel v1 globals', run: { data: good, change: (w) => setCall(w, KERNEL_V2, 'globals()', w.calls.get(`${KERNEL}:${selectorOf('globals()')}`) as string) }, fail: /kernel's globals name the deployment's KernelFactoryV2, Fab, SealedVM.*kernel is wired to the IgnixManager proxy.*kernel quotes in USD₮0/s },
    { name: 'the expected-values file pins OKB, the calldata says USD₮0', run: { data: good, expected: 'pins-okb.json' }, fail: ['vault recipient is the kernel', 'quote is native OKB (the zero address)'] },
    { name: 'the expected-values file pins USD₮0, the deployment has no v2 kernel', run: { data: toV1, deployment: 'v1.json', expected: 'pins-usd.json' }, fail: [], code: 2 },
  ];
  for (const row of rows) {
    const r = await runCli(row.run);
    const want = row.code ?? 1;
    assert.equal(r.code, want, `${row.name}\n${r.stdout}${r.stderr}`);
    if (want === 2) {
      assert.match(r.stderr, /launch-check could not run: .*records no complete kernel v2/, row.name);
      continue;
    }
    assert.match(r.stdout, /DO NOT SIGN this transaction\./, row.name);
    const got = failedLabels(r.stdout);
    if (row.fail instanceof RegExp) assert.match(got.join('\n'), row.fail, `${row.name}: ${got.join(' | ')}`);
    else assert.deepEqual(got, row.fail, row.name);
  }
  // the listing fee passes once the launcher holds and approved it (and the value stays 0)
  const fee = await runCli({
    data: usdLaunch(now, { p: { listingFee: 1_000_000n } }),
    change: (w) => {
      setCall(w, USDT0, 'balanceOf(address)', () => w32(2_000_000));
      setCall(w, USDT0, 'allowance(address,address)', () => w32(1_000_000));
    },
  });
  assert.equal(fee.code, 0, fee.stdout);
  assert.ok(fee.stdout.includes('PASS  launcher can pay the USD₮0 listing fee (balance and allowance to the IgnixManager): fee 1 USD₮0 (1000000 base units); balance 2 USD₮0'));
});

// ───────────────────────────── payto-check.ts: the Architect's PAY_TO ─────────────────────────────

const PAYTO_CLI = fileURLToPath(new URL('../payto-check.ts', import.meta.url));
const TOKEN_V2 = '0x00000000000000000000000000000000c0fe00c2';
const VAULT_V2 = '0x00000000000000000000000000000000c0fe00b2';
const AGENT_WALLET = '0xbe5088307e15aaf8cf0c53bfcc4c612c9ead6da0';

/** v2World with the v2 kernel bound to TOKEN_V2, whose vault is quoted in USD₮0 and pays the kernel. */
function boundWorld(): World {
  const w = v2World(now);
  setCall(w, KERNEL_V2, 'token()', a32(TOKEN_V2));
  setCall(w, KERNEL_V2, 'vault()', a32(VAULT_V2));
  setCall(w, KERNEL_V2, 'quote()', a32(USDT0));
  setCall(w, VAULT_V2, 'QUOTE()', a32(USDT0));
  setCall(w, VAULT_V2, 'RECIPIENT()', a32(KERNEL_V2));
  setCall(w, MANAGER, 'vaultOf(address)', (data) => a32(argAddress(data, 0) === TOKEN_V2 ? VAULT_V2 : ZERO));
  setCall(w, USDT0, 'isBlocked(address)', () => w32(0));
  return w;
}

async function payto(payTo: string, change: (w: World) => void = () => {}, deployment = 'v2.json'): Promise<Result> {
  const w = boundWorld();
  change(w);
  const server = await serve(w);
  try {
    return await new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [PAYTO_CLI, '--deployment', join(dir, deployment), '--pay-to', payTo, '--rpc', server.url], { stdio: ['ignore', 'pipe', 'pipe'] });
      let stdout = '';
      let stderr = '';
      child.stdout.on('data', (d) => (stdout += d));
      child.stderr.on('data', (d) => (stderr += d));
      child.on('error', reject);
      child.on('close', (code) => resolve({ code, stdout, stderr }));
    });
  } finally {
    await server.close();
  }
}

test('payto-check: PAY_TO passes only for the deployment\'s bound v2 kernel; the off-chain conditions are printed', async () => {
  const ok = await payto(KERNEL_V2);
  assert.equal(ok.code, 0, ok.stdout + ok.stderr);
  assert.match(ok.stdout, /^VERDICT: PASS on chain \(\d+ checks\)\. Change PAY_TO only if \(a\), \(b\) and \(d\) above hold as well\./m);
  assert.match(ok.stdout, /\(a\) IGNIX has confirmed in writing, in the Developer Support topic/);
  assert.match(ok.stdout, /\(b\) OKX\.AI agent 14683 has finished its review/);
  assert.match(ok.stdout, /No team wallet may ever pay the kernel or call the paid endpoint\./);
  assert.ok(ok.stdout.includes(`PASS  the kernel is bound (token() is not the zero address): ${show(TOKEN_V2)}`));

  const rows: [string, string, (w: World) => void, string[]][] = [
    ['the v2 kernel before bind()', KERNEL_V2, (w) => setCall(w, KERNEL_V2, 'token()', a32(ZERO)), ['the kernel is bound (token() is not the zero address)', "the token's vault is quoted in USD₮0, pays this kernel, and is the Manager's vault for the token"]],
    ['the agent wallet (today\'s PAY_TO)', AGENT_WALLET, () => {}, ["PAY_TO is the deployment's v2 kernel (flagshipV2.kernel)", 'PAY_TO has code', 'PAY_TO was created by the KernelFactoryV2 (isKernel)', "the kernel's quote is USD₮0", 'the kernel is bound (token() is not the zero address)', "the token's vault is quoted in USD₮0, pays this kernel, and is the Manager's vault for the token", 'the kernel holds its chip (Circuits.ownerOf(kernel.chipId()))']],
    ['the v1 kernel', KERNEL, () => {}, ["PAY_TO is the deployment's v2 kernel (flagshipV2.kernel)", 'PAY_TO was created by the KernelFactoryV2 (isKernel)', "the kernel's quote is USD₮0", 'the kernel is bound (token() is not the zero address)', "the token's vault is quoted in USD₮0, pays this kernel, and is the Manager's vault for the token"]],
    ['a v2 kernel USD₮0 has blocked', KERNEL_V2, (w) => setCall(w, USDT0, 'isBlocked(address)', () => w32(1)), ['USD₮0 has not blocked the kernel']],
    ['a vault that pays someone else', KERNEL_V2, (w) => setCall(w, VAULT_V2, 'RECIPIENT()', a32(KERNEL)), ["the token's vault is quoted in USD₮0, pays this kernel, and is the Manager's vault for the token"]],
  ];
  for (const [name, who, change, want] of rows) {
    const r = await payto(who, change);
    assert.equal(r.code, 1, `${name}\n${r.stdout}${r.stderr}`);
    assert.match(r.stdout, /Keep PAY_TO on the agent wallet\./, name);
    assert.deepEqual(failedLabels(r.stdout), want, name);
  }
  const noV2 = await payto(KERNEL_V2, () => {}, 'v1.json');
  assert.equal(noV2.code, 1);
  assert.match(noV2.stdout, /^payto-check refuses: .* records no coreV2 \(the KernelFactoryV2 and the LensV2\), flagshipV2/m);
});
