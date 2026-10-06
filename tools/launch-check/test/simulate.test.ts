// simulate.ts: how forge's result becomes a verdict, and the program itself on the real OB launch.
// The second part forks X Layer inside forge; it is skipped when OFFLINE=1 or when forge is not installed.

import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { UsageError } from '../args.ts';
import { missingParts, parseDeployment, sessionTwoRefusal } from '../deployment.ts';
import { NotDeployed, checkDeployment, inputFile, judge } from '../simulate.ts';

const SUITE = 'test/Live.t.sol:LiveLaunch';
const FULL = 'test_launch_simulation_full()';
const CREATE_ONLY = 'test_launch_simulation_create_only_KERNEL_CHECKS_SKIPPED()';
const result = (full: [string, string | null], createOnly: [string, string | null]) => ({
  [SUITE]: {
    test_results: {
      [FULL]: { status: full[0], reason: full[1], decoded_logs: ['createToken succeeded on the fork'] },
      [CREATE_ONLY]: { status: createOnly[0], reason: createOnly[1], decoded_logs: ['createToken succeeded on the fork', 'KERNEL CHECKS SKIPPED'] },
    },
  },
});

test('only a successful full simulation is a PASS', () => {
  const ok = judge(result(['Success', null], ['Skipped', null]), false, '');
  assert.equal(ok.code, 0);
  assert.match(ok.lines.join('\n'), /VERDICT: PASS\./);

  const failed = judge(result(['Failure', 'sim: the vault RECIPIENT is not the kernel'], ['Skipped', null]), false, '');
  assert.equal(failed.code, 1);
  assert.match(failed.lines.join('\n'), /^FAIL  sim: the vault RECIPIENT is not the kernel$/m);
  assert.match(failed.lines.join('\n'), /DO NOT SIGN/);
  assert.doesNotMatch(failed.lines.join('\n'), /VERDICT: PASS/);

  // forge skipped the test (no inputs reached it): that is a failure, never a pass
  const skipped = judge(result(['Skipped', null], ['Skipped', null]), false, '');
  assert.equal(skipped.code, 1);
  assert.match(skipped.lines.join('\n'), /the simulation was skipped/);
  assert.doesNotMatch(skipped.lines.join('\n'), /VERDICT: PASS/);

  // forge did not produce results at all (compile error, forge crashed)
  const none = judge(null, false, 'Error: Compiler run failed');
  assert.equal(none.code, 1);
  assert.match(none.lines.join('\n'), /could not run/);
  assert.match(none.lines.join('\n'), /Compiler run failed/);

  // both tests ran: the inputs were inconsistent
  const both = judge(result(['Success', null], ['Success', null]), false, '');
  assert.equal(both.code, 1);
});

test('skipping the kernel steps is never a PASS', () => {
  const partial = judge(result(['Skipped', null], ['Success', null]), true, '');
  assert.equal(partial.code, 2);
  assert.match(partial.lines.join('\n'), /VERDICT: INCOMPLETE/);
  assert.match(partial.lines.join('\n'), /NOT a pass/);
  assert.doesNotMatch(partial.lines.join('\n'), /VERDICT: PASS/);
  const failed = judge(result(['Skipped', null], ['Failure', 'sim: createToken reverted: SignatureExpired(): the deadline has passed']), true, '');
  assert.equal(failed.code, 1);
});

test('the input file keeps the value exact and carries the deployment', () => {
  const tx = { from: '0x' + '11'.repeat(20), to: '0x' + '22'.repeat(20), value: 123456789012345678901234567890n, data: '0xef44bdf2', kernel: '0x' + '33'.repeat(20) };
  const j = JSON.parse(inputFile(tx, 0, false));
  assert.equal(j.value, '123456789012345678901234567890');
  assert.equal(j.block, 0);
  assert.equal(j.skipKernelChecks, false);
  assert.equal(j.data, '0xef44bdf2');
  assert.equal(j.deployment, undefined);
  const d = parseDeployment(JSON.stringify({ kernel: tx.kernel, chipId: 2, kernelFactory: '0x' + '44'.repeat(20), circuits: '0x' + '55'.repeat(20), fab: null, sealedVM: '0x' + '66'.repeat(20), lens: '0x' + '77'.repeat(20) }));
  const k = JSON.parse(inputFile(tx, 0, false, d));
  assert.deepEqual(k.deployment, { kernelFactory: '0x' + '44'.repeat(20), circuits: '0x' + '55'.repeat(20), fab: '0x' + '00'.repeat(20), sealedVM: '0x' + '66'.repeat(20), lens: '0x' + '77'.repeat(20), chipId: '2' });
});

test('the full simulation needs a deployment with a KernelFactory, naming the same kernel', () => {
  const tx = { from: '0x' + '11'.repeat(20), to: '0x' + '22'.repeat(20), value: 0n, data: '0xef44bdf2', kernel: '0x' + '33'.repeat(20) };
  const d = (o: object) => parseDeployment(JSON.stringify(o));
  assert.throws(() => checkDeployment(null, tx, false), /--deployment is required/);
  assert.doesNotThrow(() => checkDeployment(null, tx, true), 'the create-only self-test needs none');
  const session2 = { sealedVM: '0x' + '66'.repeat(20), fab: '0x' + '67'.repeat(20), kernelFactory: '0x' + '44'.repeat(20), lens: '0x' + '77'.repeat(20) };
  assert.throws(() => checkDeployment(d({ kernel: null }), tx, false), (e: Error) => e instanceof NotDeployed && /signing session 2 is not deployed yet/.test(e.message));
  assert.throws(() => checkDeployment(d({ ...session2, lens: null, kernel: tx.kernel, chipId: 1 }), tx, false), /records no core \(the KernelFactory and the Lens\)/);
  assert.throws(() => checkDeployment(d({ ...session2, kernel: '0x' + '99'.repeat(20), chipId: 1 }), tx, false), UsageError);
  assert.doesNotThrow(() => checkDeployment(d({ ...session2, kernel: tx.kernel, chipId: 1 }), tx, false));
  assert.throws(() => parseDeployment('{"kernel":"0x' + '33'.repeat(20) + '"}'), /names a kernel but not its chipId/);
  assert.throws(() => parseDeployment('{"kernelFactory":5}'), /kernelFactory must be an address string or null/);
  assert.throws(() => parseDeployment('{"chipId":-1}'), /chipId must be a whole number/);
  assert.throws(() => parseDeployment('{"chainId":1}'), /not 196/);
  assert.equal(parseDeployment('{"someNewKey":[1,2]}').kernel, null, 'keys the tools do not use are ignored');
  // the real file deploy/rehearse.sh writes is accepted as it is
  const sample = '{"forkBlock": null, "deployer": "0x84cE7bAe1b788C7aD985D57721cA428b401aE34D", "commit": "47d4a85c3a5268adce80ecc684418bffbe5a94a9", "splitter": "0xfd73b7bc92cda68ec57799987fd3449ba5dadd88", "circuits": "0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b", "transistors": "0xC372dc307eFE4B551c866A79F582D692A373960A", "keeperTank": "0xAfed3eC2196BDc8F5a933D8f280c945f0D2D826e", "teamRegistry": "0x6f1a330b7FfAc901205704EACA8e46ee4091F3A2", "probeCircuitId": 1, "sealedVM": "0x3410db75fd8127837207f80db7cfd68441b43006", "fab": "0x19c248cf463c1e167121e52b77aba7ec68cbe47b", "kernelFactory": "0xdcac8c47af534dc0cde30f60056bce7d63a79afe", "lens": "0xaaa75144304cf81cc7cf513f434e00980d1803ad", "chipId": 2, "kernel": "0x99B767ceaF6c87BaB2f750963F17103240013951", "manifestHash": "0xfe8b7a49a7d0f9a75d0684b88587648284fc586f936035f8831cb6d34060e209", "deployerNonceAfter": 11, "deployerBalanceAfter": "0.519538355380475733"}';
  const r = parseDeployment(sample);
  assert.equal(r.kernel, '0x99b767ceaf6c87bab2f750963f17103240013951');
  assert.equal(r.chipId, 2n);
  assert.equal(r.teamRegistry, '0x6f1a330b7ffac901205704eaca8e46ee4091f3a2');
  assert.equal(r.format, 'flat');
});

test('deployments/xlayer.json, the nested mainnet record, is read; its missing session 2 is named', () => {
  const live = readFileSync(new URL('../../../deployments/xlayer.json', import.meta.url), 'utf8');
  const d = parseDeployment(live, 'deployments/xlayer.json');
  assert.equal(d.format, 'nested');
  assert.equal(d.deployer, '0x84ce7bae1b788c7ad985d57721ca428b401ae34d');
  assert.equal(d.keeper, '0x7444ec2a06d3c1070203b76c2c3eee998317c4ff');
  assert.match(String(d.teamRegistry), /^0x[0-9a-f]{40}$/);
  assert.match(String(d.circuits), /^0x[0-9a-f]{40}$/);
  // as long as signing session 2 is not recorded, its parts are named as missing
  const o = JSON.parse(live);
  const expectMissing = ['evaluator', 'core', 'flagship'].filter((k) => o[k] === undefined);
  assert.deepEqual(missingParts(d).map((m) => m.part), expectMissing);
  // after session 2, the same file names everything launch-check needs
  const after = parseDeployment(
    JSON.stringify({
      ...o,
      evaluator: { commit: 'x', sealedVM: '0x19c248cf463c1e167121e52b77aba7ec68cbe47b', fab: '0xdcac8c47af534dc0cde30f60056bce7d63a79afe', txs: [] },
      core: { commit: 'x', kernelFactory: '0xaaa75144304cf81cc7cf513f434e00980d1803ad', kernelImpl: '0x72e6EbdB444831c9511c6D1DBF07A7f68993EDF1', lens: '0xee63eb34f4b7a16a188d3d14075b9bb6a8aa5ea2', txs: [] },
      flagship: { commit: 'x', chip: 'Flow Governor', chipId: 2, kernel: '0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356', netlistKeccak256: '0x', manifestHash: '0x', allowancePayee: o.issuance.keeperTank, txs: [] },
    }),
  );
  assert.deepEqual(missingParts(after), []);
  assert.equal(sessionTwoRefusal(after), null);
  assert.equal(after.kernel, '0xb722a4bde4efee08be938e2103d7a44c498dd356');
  assert.equal(after.chipId, 2n);
  assert.equal(after.kernelImpl, '0x72e6ebdb444831c9511c6d1dbf07a7f68993edf1');
  assert.throws(() => parseDeployment(JSON.stringify({ ...o, core: 'x' })), /core must be an object/);
  assert.throws(() => parseDeployment(JSON.stringify({ ...o, issuance: { ...o.issuance, circuits: '0x12' } })), /issuance\.circuits: "0x12" is not a 20-byte hex address/);
});

// ───────────────────────────── the program, on the real OB launch ─────────────────────────────

const SIM = fileURLToPath(new URL('../sim', import.meta.url));
const hasForge = spawnSync('forge', ['--version']).status === 0 && existsSync(SIM + '/lib/forge-std/src/Test.sol');
const skip = process.env.OFFLINE === '1' ? 'OFFLINE=1' : !hasForge ? 'forge or sim/lib/forge-std is not installed' : false;
const ob = JSON.parse(readFileSync(new URL('./fixtures/ob-launch.json', import.meta.url), 'utf8')).transaction;
const CLI = fileURLToPath(new URL('../simulate.ts', import.meta.url));

const simulate = (extra: readonly string[]): Promise<{ code: number | null; out: string }> =>
  new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [CLI, '--from', ob.from, '--to', ob.to, '--value', ob.value, '--data', ob.input, '--kernel', '0xC12fBf15Df59800f39F2Ebb34c9CBDce150Ae404', ...extra], { stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (out += d));
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, out }));
  });

test('the real OB launch, replayed at the block before it with the kernel steps skipped: the real token, exit code 2', { skip, timeout: 300_000 }, async () => {
  const r = await simulate(['--block', '71350519', '--skip-kernel-checks']);
  assert.equal(r.code, 2, r.out);
  assert.match(r.out, /token\s+0x995546dFdf93BEF59C35742aB5f4762fbcB8eEEe/);
  assert.match(r.out, /vault\s+0xeC7732C9dCF978C8a97E6c44499331757D240365/);
  assert.match(r.out, /gas used\s+3499861/, 'the gasUsed of the real receipt');
  assert.match(r.out, /VERDICT: INCOMPLETE/);
  assert.doesNotMatch(r.out, /VERDICT: PASS/);
});

test('the same launch as a full simulation without a deployment file is refused before forge runs: exit code 2', async () => {
  const r = await simulate(['--block', '71350519']);
  assert.equal(r.code, 2, r.out);
  assert.match(r.out, /--deployment is required/);
  assert.doesNotMatch(r.out, /VERDICT: PASS/);
});

test('wrong arguments are exit code 2 and never a PASS', async () => {
  const run = (args: string[]): Promise<{ code: number | null; out: string }> =>
    new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [CLI, ...args], { stdio: ['ignore', 'pipe', 'pipe'] });
      let out = '';
      child.stdout.on('data', (d) => (out += d));
      child.stderr.on('data', (d) => (out += d));
      child.on('error', reject);
      child.on('close', (code) => resolve({ code, out }));
    });
  for (const args of [[], ['--from', ob.from], ['--from', ob.from, '--to', ob.to, '--value', '0', '--data', ob.input, '--kernel', ob.from, '--block', 'latest']]) {
    const r = await run(args);
    assert.equal(r.code, 2, args.join(' '));
    assert.doesNotMatch(r.out, /VERDICT: PASS/);
  }
});
