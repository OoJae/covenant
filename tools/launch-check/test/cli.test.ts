// The launch-check program as a human runs it: arguments in, lines and an exit code out.
// Offline: the chain is the table server of helpers.ts.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { MANAGER } from '../decode.ts';
import { show } from '../hex.ts';
import { CHIP_ID, CIRCUITS, FAB, KERNEL, KERNEL_FACTORY, LAUNCHER, SEALED_VM, TRANSISTORS, goodWorld, launch, serve, type MockRpc, type World } from './helpers.ts';

const LENS = '0x00000000000000000000000000000000c0fe0009';

const CLI = fileURLToPath(new URL('../launch-check.ts', import.meta.url));
const ob = JSON.parse(readFileSync(new URL('./fixtures/ob-launch.json', import.meta.url), 'utf8'));

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

let world: World;
let rpc: MockRpc;
let dir: string;
const now = BigInt(Math.floor(Date.now() / 1000));

before(async () => {
  world = goodWorld(now);
  rpc = await serve(world);
  dir = mkdtempSync(join(tmpdir(), 'launch-check-'));
  // a deployment file in the format of deploy/rehearsal.json
  writeFileSync(
    join(dir, 'deployment.json'),
    JSON.stringify({ forkBlock: 1, deployer: LAUNCHER, kernel: KERNEL, chipId: Number(CHIP_ID), circuits: CIRCUITS, transistors: TRANSISTORS, kernelFactory: KERNEL_FACTORY, fab: FAB, sealedVM: SEALED_VM, lens: LENS, rehearsed: ['evaluator', 'core', 'flagship'], nonceBefore: { evaluator: 5 } }),
  );
  // the same deployment in the nested format of deployments/xlayer.json, after signing session 2
  writeFileSync(
    join(dir, 'xlayer.json'),
    JSON.stringify({
      chainId: 196,
      note: 'test',
      deployer: LAUNCHER,
      issuance: { commit: 'c', splitter: '0x00000000000000000000000000000000c0fe00a0', block: 1, transistors: TRANSISTORS, circuits: CIRCUITS, keeperTank: '0x00000000000000000000000000000000c0fe0004', teamRegistry: '0x00000000000000000000000000000000c0fe00a1' },
      probe: { circuitId: 1, gates: 118 },
      keeper: '0x7444eC2a06d3c1070203b76c2c3EeE998317C4Ff',
      evaluator: { commit: 'c', sealedVM: SEALED_VM, fab: FAB, txs: ['0x01'] },
      core: { commit: 'c', kernelFactory: KERNEL_FACTORY, kernelImpl: '0x00000000000000000000000000000000c0fe00a2', lens: LENS, txs: [] },
      flagship: { commit: 'c', chip: 'Flow Governor', chipId: Number(CHIP_ID), kernel: KERNEL, netlistKeccak256: '0x00', manifestHash: '0x00', allowancePayee: '0x00000000000000000000000000000000c0fe0004', txs: [] },
    }),
  );
});
after(async () => {
  await rpc.close();
  rmSync(dir, { recursive: true, force: true });
});

const base = (data: string): string[] => ['--from', show(LAUNCHER), '--to', show(MANAGER), '--value', '0', '--data', data, '--kernel', show(KERNEL), '--circuits', show(CIRCUITS), '--deployment', join(dir, 'deployment.json'), '--rpc', rpc.url];

test('a correct launch: every line is PASS and the exit code is 0', async () => {
  const { data } = launch({ now });
  const r = await cli(base(data));
  assert.equal(r.code, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /VERDICT: PASS\. All \d+ checks passed\./);
  assert.doesNotMatch(r.stdout, /^FAIL/m);
  assert.match(r.stdout, /^PASS  firstBuy is 0 \(no team buy\): 0 OKB \(0 wei\)$/m);
  assert.ok(r.stdout.split('\n').includes(`PASS  vault recipient is the kernel: ${show(KERNEL)}`));
  assert.match(r.stdout, /^PASS  signature deadline has at least 3 minutes left: (29 min \d+ s|30 min) left/m);
  assert.match(r.stdout, /name   \(compare with what you typed\): "Covenant Reference"/);
  assert.match(r.stdout, /ticker \(compare with what you typed\): "CVREF"/);
  assert.ok(!world.seen.some((m) => /send|sign|personal|accounts/i.test(m)), 'only read methods were used');
  assert.deepEqual([...new Set(world.seen)].sort(), ['eth_call', 'eth_chainId', 'eth_getBalance', 'eth_getBlockByNumber', 'eth_getCode']);
});

test('the deployment file alone names the kernel and the processor; without it the verdict is never PASS', async () => {
  const { data } = launch({ now });
  const minimal = ['--deployment', join(dir, 'deployment.json'), '--from', show(LAUNCHER), '--to', show(MANAGER), '--value', '0', '--data', data, '--rpc', rpc.url];
  const r = await cli(minimal);
  assert.equal(r.code, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /^PASS  kernel was created by the Covenant KernelFactory \(isKernel\): isKernel = true/m);
  assert.match(r.stdout, new RegExp(`^      kernel ${show(KERNEL)}$`, 'm'));

  const without = await cli(['--from', show(LAUNCHER), '--to', show(MANAGER), '--value', '0', '--data', data, '--kernel', show(KERNEL), '--circuits', show(CIRCUITS), '--rpc', rpc.url]);
  assert.equal(without.code, 1);
  assert.match(without.stdout, /^FAIL  kernel was created by the Covenant KernelFactory \(isKernel\): NOT CHECKED  <-- could not be performed: no KernelFactory address was given: pass --deployment/m);
  assert.match(without.stdout, /VERDICT: FAIL\. 1 of \d+ checks/);

  const other = await cli(minimal.concat(['--kernel', '0x00000000000000000000000000000000c0fe00ff']));
  assert.equal(other.code, 1);
  assert.ok(other.stdout.includes(`FAIL  kernel is the one the deployment / expected-values file names: ${show('0x00000000000000000000000000000000c0fe00ff')}  <-- the file says ${show(KERNEL)}`));

  // a misspelt key is ignored, so the addresses it should give are missing: refused, never passed
  const file = join(dir, 'bad-deployment.json');
  writeFileSync(file, JSON.stringify({ ...JSON.parse(readFileSync(join(dir, 'deployment.json'), 'utf8')), kernel: undefined, kernal: KERNEL }));
  const bad = await cli(['--deployment', file, ...minimal.slice(2)]);
  assert.equal(bad.code, 1);
  assert.match(bad.stdout, /signing session 2 is not deployed yet: .* records no flagship/);
  // a key the tools use, with the wrong type, is a usage error
  writeFileSync(file, JSON.stringify({ kernelFactory: 7 }));
  const wrong = await cli(['--deployment', file, ...minimal.slice(2)]);
  assert.equal(wrong.code, 2);
  assert.match(wrong.stderr, /kernelFactory must be an address string or null/);
});

test('deployments/xlayer.json (nested) is read like the flat file; before session 2 it is refused clearly', async () => {
  const { data } = launch({ now });
  const nested = ['--deployment', join(dir, 'xlayer.json'), '--from', show(LAUNCHER), '--to', show(MANAGER), '--value', '0', '--data', data, '--rpc', rpc.url];
  const r = await cli(nested);
  assert.equal(r.code, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /^VERDICT: PASS\. All 34 checks passed\./m);

  // session 1 only: the shape of deployments/xlayer.json until deploy/launch-kernel.sh has run
  const full = JSON.parse(readFileSync(join(dir, 'xlayer.json'), 'utf8'));
  for (const [name, drop] of [['session1', ['evaluator', 'core', 'flagship']], ['noflagship', ['flagship']]] as const) {
    const o = { ...full };
    for (const k of drop) delete o[k];
    const file = join(dir, `${name}.json`);
    writeFileSync(file, JSON.stringify(o));
    for (const args of [['--deployment', file, ...nested.slice(2)], ['--deployment', file, ...nested.slice(2), '--kernel', show(KERNEL)]]) {
      const x = await cli(args);
      assert.equal(x.code, 1, x.stdout + x.stderr);
      assert.match(x.stdout, /^launch-check refuses: signing session 2 is not deployed yet: /m);
      assert.ok(x.stdout.includes(drop.length === 3 ? 'records no evaluator (the SealedVM and the Fab), core (the KernelFactory and the Lens), flagship (the flagship chip and its kernel)' : 'records no flagship (the flagship chip and its kernel)'), x.stdout);
      assert.match(x.stdout, /DO NOT SIGN/);
      assert.doesNotMatch(x.stdout, /VERDICT: PASS/);
    }
  }
});

test('--tx takes the eth_sendTransaction parameters a page hook captures', async () => {
  const { data } = launch({ now });
  const deployment = ['--deployment', join(dir, 'deployment.json'), '--rpc', rpc.url];
  const params = { from: show(LAUNCHER), to: show(MANAGER), value: '0x0', data, gas: '0x4c4b40', chainId: '0xc4' };
  const forms: [string, unknown][] = [
    ['params object', params],
    ['params array', [params]],
    ['whole request', { method: 'eth_sendTransaction', params: [params] }],
    ['no value, input instead of data', { from: LAUNCHER, to: MANAGER, input: data }],
  ];
  for (const [name, body] of forms) {
    const file = join(dir, 'tx.json');
    writeFileSync(file, JSON.stringify(body));
    const r = await cli([...deployment, '--tx', '@' + file]);
    assert.equal(r.code, 0, `${name}: ${r.stdout}${r.stderr}`);
    assert.match(r.stdout, /^VERDICT: PASS\./m, name);
  }
  // inline JSON works too, and a value above the listing fee is caught like with --value
  const inline = await cli([...deployment, '--tx', JSON.stringify({ ...params, value: '0x1' })]);
  assert.equal(inline.code, 1);
  assert.match(inline.stdout, /^FAIL  msg\.value is the listing fee alone: value 0\.000000000000000001 OKB \(1 wei\)/m);
  // mistakes are exit code 2
  const bad: [unknown, RegExp][] = [
    [{ ...params, chainId: '0x1' }, /chainId is "0x1", not X Layer/],
    [{ method: 'eth_signTypedData_v4', params: [] }, /not eth_sendTransaction/],
    [{ to: MANAGER, data }, /"from" is missing/],
    [{ ...params, value: 0.5 }, /not an exact whole number of wei/],
    [{ ...params, input: '0xef44bdf2' }, /"data" and "input" differ/],
  ];
  for (const [body, message] of bad) {
    const r = await cli([...deployment, '--tx', JSON.stringify(body)]);
    assert.equal(r.code, 2, JSON.stringify(body));
    assert.match(r.stderr, message);
  }
  const both = await cli([...deployment, '--tx', JSON.stringify(params), '--from', show(LAUNCHER)]);
  assert.equal(both.code, 2);
  assert.match(both.stderr, /do not also pass --from/);
});

test('the calldata may come from a file, with the line breaks of a copy-paste', async () => {
  const { data } = launch({ now });
  const file = join(dir, 'calldata.txt');
  writeFileSync(file, data.replace(/(.{64})/g, '$1\n') + '\n');
  const args = base('@' + file);
  const r = await cli(args);
  assert.equal(r.code, 0, r.stdout + r.stderr);
});

test('the expected-values file supplies the processor address and exact name checks', async () => {
  const { data } = launch({ now });
  const file = join(dir, 'expected.json');
  writeFileSync(file, JSON.stringify({ taxBuyBps: 300, taxSellBps: 300, protectionSecs: 8640000, name: 'Covenant Reference', symbol: 'CVREF', kernel: KERNEL, processor: { circuits: CIRCUITS, transistors: null } }));
  const args = base(data).filter((a, i, all) => a !== '--circuits' && all[i - 1] !== '--circuits');
  const r = await cli([...args, '--expected', file]);
  assert.equal(r.code, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /^PASS  ticker is the expected ticker: "CVREF"$/m);
  assert.match(r.stdout, /^PASS  kernel is the one the deployment \/ expected-values file names/m);
});

test('a first buy is refused: FAIL lines, DO NOT SIGN, exit code 1', async () => {
  const { data } = launch({ now, p: { firstBuy: 4n * 10n ** 17n } });
  const args = base(data);
  args[5] = '0.4okb';
  const r = await cli(args);
  assert.equal(r.code, 1);
  assert.match(r.stdout, /^FAIL  firstBuy is 0 \(no team buy\): 0\.4 OKB \(400000000000000000 wei\)  <-- /m);
  assert.match(r.stdout, /^FAIL  msg\.value is the listing fee alone: /m);
  assert.match(r.stdout, /VERDICT: FAIL\. 2 of \d+ checks failed or could not be performed\. DO NOT SIGN this transaction\./);
});

test('the real OB launch is refused for each rule it breaks', async () => {
  const tx = ob.transaction;
  const r = await cli(['--from', tx.from, '--to', tx.to, '--value', tx.value, '--data', tx.input, '--kernel', '0xC12fBf15Df59800f39F2Ebb34c9CBDce150Ae404', '--circuits', show(CIRCUITS), '--rpc', rpc.url]);
  assert.equal(r.code, 1);
  for (const label of ['buy tax and sell tax are the expected values: 100 / 100 bps', 'firstBuy is 0 \\(no team buy\\): 0\\.4 OKB', 'msg\\.value is the listing fee alone', 'anti-snipe is off \\(snipeStartBps 0\\): snipeStartBps 5000, snipeMins 30', 'signature deadline has at least 3 minutes left: expired', 'kernel address has code: 0 bytes']) {
    assert.match(r.stdout, new RegExp(`^FAIL  ${label}`, 'm'), label);
  }
  assert.match(r.stdout, /^PASS  vault recipient is the kernel: 0xC12fBf15Df59800f39F2Ebb34c9CBDce150Ae404$/m);
  assert.match(r.stdout, /name   \(compare with what you typed\): "OpenBook"/);
  assert.match(r.stdout, /DO NOT SIGN/);
});

test('--json prints the same result for a program to read', async () => {
  const { data } = launch({ now });
  const r = await cli([...base(data), '--json']);
  assert.equal(r.code, 0);
  const j = JSON.parse(r.stdout);
  assert.equal(j.ok, true);
  assert.equal(j.failed, 0);
  assert.equal(j.tx.kernel, KERNEL);
  assert.ok(j.lines.every((l: any) => l.kind === 'info' || l.ok === true));
});

test('a mistake in the arguments is exit code 2 and is never a PASS', async () => {
  const { data } = launch({ now });
  const cases: [string[], RegExp][] = [
    [[], /--from <launcher address>/],
    [base(data).slice(2), /--from is required/],
    [base(data).filter((a, i, all) => !['--kernel', '--deployment'].includes(a) && !['--kernel', '--deployment'].includes(all[i - 1])), /--kernel is required \(or --deployment/],
    [[...base(data), '--kernal', 'x'], /unknown option --kernal/],
    [base(data).map((a) => (a === show(KERNEL) ? '0x00000000000000000000000000000000c0FE0001' : a)), /wrong EIP-55 checksum/],
    [base(data).map((a) => (a === '0' ? '0.4' : a)), /not a wei amount/],
    [base('0xnothex'), /--data is not hex/],
    [[...base(data), '--expected', join(dir, 'missing.json')], /cannot read/],
  ];
  for (const [args, message] of cases) {
    const r = await cli(args);
    assert.equal(r.code, 2, args.join(' '));
    assert.match(r.stdout + r.stderr, message);
    assert.doesNotMatch(r.stdout + r.stderr, /VERDICT: PASS/);
  }
  const help = await cli(['--help']);
  assert.equal(help.code, 0);
  assert.match(help.stdout, /It never signs and never sends/);
});

test('an unreachable node: exit code 1 and no chain check says PASS', async () => {
  const { data } = launch({ now });
  const args = base(data);
  args[args.length - 1] = 'http://127.0.0.1:9';
  const r = await cli(args);
  assert.equal(r.code, 1);
  assert.match(r.stdout, /^FAIL  kernel address has code: NOT CHECKED  <-- could not be performed: /m);
  assert.match(r.stdout, /^FAIL  signature deadline has at least 3 minutes left: NOT CHECKED/m);
  assert.match(r.stdout, /DO NOT SIGN/);
});
