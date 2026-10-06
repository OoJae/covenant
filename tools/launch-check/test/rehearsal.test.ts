// Launch day, rehearsed against the REAL Covenant contracts on a local fork of X Layer.
//
//   REHEARSE=1 node --test tools/launch-check/test/rehearsal.test.ts        (about 4 to 6 minutes)
//
// 1. deploy/rehearse.sh deploys, on its own local anvil fork (impersonating the real deployer; no key), every
//    Covenant contract that deployments/xlayer.json does not already record on chain, working in its own
//    scratch copy of the contracts, and writes the addresses to deploy/rehearsal.json (this test restores that
//    file afterwards, since deploy/launch-kernel.sh reads it). It is run with test/rehearsal/anvil first on PATH,
//    so the anvil node it starts OUTLIVES the script: this test then uses exactly the fork rehearse.sh deployed
//    on (on its own port; killed at the end).
// 2. On that fork only: the IGNIX platform signer is replaced in storage by a throwaway test signer
//    (the technique of contracts/probes/test/ProbeBase.sol, slot 5), and a createToken transaction is built
//    and "signed by the platform" for the deployer, the launcher of the rehearsal's kernel, with the kernel as
//    the Directed vault's recipient. Its calldata is what a wallet would show.
// 3. launch-check.ts and simulate.ts, given the deployment file, must PASS on it: with the flat rehearsal file,
//    with the nested format of deployments/xlayer.json completed by the rehearsal's session 2, and with the
//    transaction given as eth_sendTransaction parameters (--tx). The real deployments/xlayer.json, while it
//    lacks session 2, must be refused.
// 4. Each field is corrupted one at a time (re-signed by the platform when the platform would sign it):
//    launch-check must refuse each, naming the check; simulate must refuse the ones it can see.
// 5. The transaction is sent TO THE LOCAL FORK ONLY: it creates the token simulate predicted; an unrelated
//    address binds the kernel; both commands then refuse the same transaction; audit-team, run against the
//    fork with the deployment file, reads the TeamRegistry and finds the deployer's history clean.
//
// The transcript of every command is written to $REHEARSAL_TRANSCRIPT (default: a file in the OS temp
// directory, printed as a diagnostic). Skipped unless REHEARSE=1, and when anvil, forge or forge-std is missing.

import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { appendFileSync, copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { MANAGER, selectorOf } from '../decode.ts';
import { parseDeployment, type Deployment } from '../deployment.ts';
import { addressWord, show, word } from '../hex.ts';
import { kernel as kernelCalls } from '../kernel-abi.ts';
import { PLATFORM, launch, testSigner, type LaunchOptions } from './helpers.ts';

const REPO = fileURLToPath(new URL('../../../', import.meta.url));
const SIM = fileURLToPath(new URL('../sim', import.meta.url));
const WRAPPER_DIR = fileURLToPath(new URL('./rehearsal', import.meta.url));
const LAUNCH_CHECK = fileURLToPath(new URL('../launch-check.ts', import.meta.url));
const SIMULATE = fileURLToPath(new URL('../simulate.ts', import.meta.url));
const AUDIT = fileURLToPath(new URL('../../audit-team/audit-team.ts', import.meta.url));
const ROUTER = '0x182a927119d56008d921126764bf884221b10f59';
const USDT0 = '0x779ded0c9e1022225f8e0630b35a9b54be713736';
const FOUNDER_ROOT = '0x' + '77'.repeat(32);

const which = (cmd: string): string | null => {
  const r = spawnSync('/usr/bin/env', ['which', cmd], { encoding: 'utf8' });
  return r.status === 0 ? r.stdout.trim() : null;
};
const REAL_ANVIL = which('anvil');
const skip =
  process.env.REHEARSE !== '1'
    ? 'set REHEARSE=1 to run (it runs deploy/rehearse.sh, about 4 to 6 minutes)'
    : !REAL_ANVIL
      ? 'anvil is not installed'
      : !which('forge') || !existsSync(SIM + '/lib/forge-std/src/Test.sol')
        ? 'forge or sim/lib/forge-std is not installed'
        : false;

let keepDir = '';
/** deploy/rehearsal.json as it was before this test ran rehearse.sh, restored at the end (null: it did not exist). */
let savedPlan: string | null | undefined;
const PLAN = join(REPO, 'deploy/rehearsal.json');
let url = '';
let id = 0;
let transcript = '';

const log = (s: string): void => {
  if (transcript) appendFileSync(transcript, s.endsWith('\n') ? s : s + '\n');
};

async function rpc<T = string>(method: string, params: unknown[] = []): Promise<T> {
  const res = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }) });
  const j = (await res.json()) as { result?: T; error?: { message: string } };
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result as T;
}
const call = (to: string, data: string): Promise<string> => rpc('eth_call', [{ to, data }, 'latest']);
const callSig = (to: string, signature: string, args: string = ''): Promise<string> => call(to, selectorOf(signature) + args);
const asAddress = (ret: string): string => '0x' + ret.slice(-40);

/** Sends a transaction on the LOCAL fork (rehearse.sh's anvil impersonates any sender) and waits for it. */
async function send(tx: { from: string; to: string; data?: string; value?: string }): Promise<{ status: string; logs: { address: string; topics: string[]; data: string }[] }> {
  assert.match(url, /^http:\/\/127\.0\.0\.1:\d+$/, 'transactions are only ever sent to the local fork');
  const hash = await rpc('eth_sendTransaction', [{ gas: '0x1c9c380', ...tx }]);
  for (let i = 0; i < 200; i++) {
    const r = await rpc<any>('eth_getTransactionReceipt', [hash]);
    if (r) return r;
    await new Promise((res) => setTimeout(res, 100));
  }
  throw new Error('no receipt from the local node');
}

const runProcess = (cmd: string, args: readonly string[], env: NodeJS.ProcessEnv = process.env, cwd: string = REPO): Promise<{ code: number | null; out: string }> =>
  new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'], env, cwd });
    let out = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (out += d));
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, out }));
  });
const runTool = async (script: string, args: readonly string[], title: string): Promise<{ code: number | null; out: string }> => {
  const r = await runProcess(process.execPath, [script, ...args]);
  log(`\n$ ${title}\n${r.out}(exit code ${r.code})\n`);
  return r;
};

const freePort = (): Promise<number> =>
  new Promise((resolve) => {
    const s = createServer();
    s.listen(0, '127.0.0.1', () => {
      const p = (s.address() as { port: number }).port;
      s.close(() => resolve(p));
    });
  });

after(() => {
  if (!keepDir) return;
  const pidFile = join(keepDir, 'anvil.pid');
  if (existsSync(pidFile)) {
    try {
      process.kill(Number(readFileSync(pidFile, 'utf8').trim()));
    } catch {
      // already gone
    }
  }
  rmSync(keepDir, { recursive: true, force: true });
  restorePlan();
});

function restorePlan(): void {
  if (savedPlan === undefined) return;
  if (savedPlan === null) rmSync(PLAN, { force: true });
  else writeFileSync(PLAN, savedPlan);
  savedPlan = undefined;
}

const failedLabels = (out: string): string[] => out.split('\n').filter((l) => l.startsWith('FAIL  ')).map((l) => l.slice(6).replace(/: .*$/, ''));

test('launch day against the real contracts of deploy/rehearse.sh: PASS, every corruption refused, then the real launch', { skip, timeout: 1_800_000 }, async (t) => {
  keepDir = mkdtempSync(join(tmpdir(), 'launch-check-rehearsal-'));
  transcript = process.env.REHEARSAL_TRANSCRIPT ?? join(tmpdir(), `launch-check-rehearsal-${Date.now()}.txt`);
  writeFileSync(transcript, `launch-check rehearsal against the real contracts, ${new Date().toISOString()}\n`);
  t.diagnostic(`transcript: ${transcript}`);

  // ── 1. deploy what is not on chain yet with deploy/rehearse.sh; its anvil outlives it
  savedPlan = existsSync(PLAN) ? readFileSync(PLAN, 'utf8') : null;
  const port = await freePort();
  url = `http://127.0.0.1:${port}`;
  const env = { ...process.env, PATH: `${WRAPPER_DIR}:${process.env.PATH}`, PORT: String(port), REAL_ANVIL: REAL_ANVIL as string, KEEP_DIR: keepDir };
  const started = Date.now();
  const rehearse = await runProcess('bash', [join(REPO, 'deploy/rehearse.sh')], env);
  log(`\n$ PORT=${port} deploy/rehearse.sh   (${Math.round((Date.now() - started) / 1000)} s)\n${rehearse.out.split('\n').filter((l) => !/^\s*$/.test(l)).slice(-40).join('\n')}\n(exit code ${rehearse.code}; last 40 lines)\n`);
  assert.equal(rehearse.code, 0, rehearse.out);
  assert.equal(await rpc('eth_chainId'), '0xc4', 'the node rehearse.sh deployed on is still running');
  const deploymentFile = join(keepDir, 'deployment.json');
  copyFileSync(PLAN, deploymentFile);
  restorePlan();
  const d: Deployment = parseDeployment(readFileSync(deploymentFile, 'utf8'), deploymentFile);
  for (const k of ['deployer', 'kernel', 'kernelFactory', 'kernelImpl', 'circuits', 'transistors', 'fab', 'sealedVM', 'lens', 'teamRegistry'] as const) assert.ok(d[k], `the deployment names ${k}`);
  const deployer = d.deployer as string;
  const kernel = d.kernel as string;
  assert.ok(((await rpc<string>('eth_getCode', [kernel, 'latest'])).length - 2) / 2 > 0, 'the kernel exists on the fork');
  const env0 = kernelCalls(kernel).envelope();
  assert.equal(env0.decode(await call(kernel, env0.data)).launcher, deployer, "the rehearsal kernel's launcher is the deployer");

  // ── 2. fork-only: the platform signer is replaced by the throwaway test signer (ProbeBase.sol, slot 5)
  await rpc('anvil_setStorageAt', [MANAGER, '0x5', '0x' + addressWord(PLATFORM.address)]);
  assert.equal(asAddress(await callSig(MANAGER, 'signer()')), PLATFORM.address);
  const poolFee = BigInt(await callSig(MANAGER, 'POOL_FEE()'));
  const launchFactory = asAddress(await callSig(MANAGER, 'LAUNCH_FACTORY()'));
  const registry = asAddress(await callSig(MANAGER, 'REGISTRY()'));
  const directed = asAddress(await callSig(registry, 'factoryOf(uint16)', word(3)));
  const chainNow = BigInt((await rpc<{ timestamp: string }>('eth_getBlockByNumber', ['latest', false])).timestamp);
  const wall = BigInt(Math.floor(Date.now() / 1000));
  const now = chainNow > wall ? chainNow : wall;
  log(`\nfork: ${url}; platform signer replaced by ${PLATFORM.address}; POOL_FEE ${poolFee}; LAUNCH_FACTORY ${launchFactory}; Directed factory ${directed}; now ${now}\n`);

  /** createToken calldata as ignix.bot would sign it for `sender`, with the kernel as recipient unless changed. */
  const make = (o: LaunchOptions = {}): string =>
    launch({ now, poolFee, launchFactory, sender: deployer, ...o, call: { vaultData: '0x' + addressWord(kernel), factory: directed, deadline: now + 3600n, ...o.call } }).data;
  const good = make();
  const dataFile = (name: string, data: string): string => {
    const f = join(keepDir, `${name}.txt`);
    writeFileSync(f, data + '\n');
    return '@' + f;
  };
  const argsFor = (o: { data: string; from?: string; to?: string; value?: string; kernel?: string; name: string }): string[] => [
    '--deployment',
    deploymentFile,
    '--from',
    show(o.from ?? deployer),
    '--to',
    show(o.to ?? MANAGER),
    '--value',
    o.value ?? '0',
    '--data',
    dataFile(o.name, o.data),
    ...(o.kernel ? ['--kernel', show(o.kernel)] : []),
    '--rpc',
    url,
  ];

  // ── 3. the good launch: both commands pass
  const check = await runTool(LAUNCH_CHECK, argsFor({ data: good, name: 'good' }), 'launch-check (the good launch)');
  assert.equal(check.code, 0, check.out);
  assert.match(check.out, /^VERDICT: PASS\. All \d+ checks passed\./m);
  for (const line of [
    `PASS  vault recipient is the kernel: ${show(kernel)}`,
    `PASS  kernel's envelope launcher is --from: ${show(deployer)}`,
    `PASS  kernel holds its chip (Circuits.ownerOf(kernel.chipId()) is the kernel): chip ${d.chipId} is owned by ${show(kernel)}`,
    `PASS  kernel was created by the Covenant KernelFactory (isKernel): isKernel = true at ${show(d.kernelFactory as string)}`,
    `PASS  platform signature is valid for this launcher and this calldata: signed by ${show(PLATFORM.address)}`,
    'PASS  Circuits is a processor created by the TapeOut factory: isCPU = true',
  ]) {
    assert.ok(check.out.includes(line), line);
  }
  // the same, with the nested format of deployments/xlayer.json (the live record, completed by the rehearsed
  // session 2) and with the transaction as the eth_sendTransaction parameters a page hook captures
  const liveRecord = JSON.parse(readFileSync(join(REPO, 'deployments/xlayer.json'), 'utf8'));
  const nestedFile = join(keepDir, 'xlayer-after-session-2.json');
  writeFileSync(
    nestedFile,
    JSON.stringify({
      ...liveRecord,
      evaluator: liveRecord.evaluator ?? { sealedVM: d.sealedVM, fab: d.fab, txs: [] },
      core: liveRecord.core ?? { kernelFactory: d.kernelFactory, kernelImpl: d.kernelImpl, lens: d.lens, txs: [] },
      flagship: liveRecord.flagship ?? { chipId: Number(d.chipId), kernel: d.kernel, txs: [] },
    }),
  );
  const txFile = join(keepDir, 'tx.json');
  writeFileSync(txFile, JSON.stringify({ from: show(deployer), to: show(MANAGER), value: '0x0', data: good, gas: '0x4c4b40' }));
  const nested = await runTool(LAUNCH_CHECK, ['--deployment', nestedFile, '--tx', '@' + txFile, '--rpc', url], 'launch-check --deployment <deployments/xlayer.json + rehearsed session 2> --tx @tx.json');
  assert.equal(nested.code, 0, nested.out);
  assert.match(nested.out, /^VERDICT: PASS\. All \d+ checks passed\./m);
  if (!liveRecord.evaluator || !liveRecord.core || !liveRecord.flagship) {
    const before = await runTool(LAUNCH_CHECK, ['--deployment', join(REPO, 'deployments/xlayer.json'), '--tx', '@' + txFile, '--rpc', url], 'launch-check --deployment deployments/xlayer.json (session 2 not recorded yet)');
    assert.equal(before.code, 1, before.out);
    assert.match(before.out, /^launch-check refuses: signing session 2 is not deployed yet: /m);
  }

  const sim = await runTool(SIMULATE, ['--deployment', nestedFile, '--tx', '@' + txFile, '--rpc', url], 'simulate --deployment <deployments/xlayer.json + rehearsed session 2> --tx @tx.json (the good launch)');
  assert.equal(sim.code, 0, sim.out);
  assert.match(sim.out, /VERDICT: PASS\./);
  assert.match(sim.out, /the kernel belongs to the deployment/);
  assert.match(sim.out, /kernel\.bind\(token\) succeeded, called by an unrelated address/);
  assert.match(sim.out, /kernel\.settle\(\) wrote a record one epoch later/);
  assert.match(sim.out, /inflow \(wei\)\s+30000000000000000/, '3% of the 1 OKB an outsider bought');
  const predicted = /token\s+(0x[0-9a-fA-F]{40})/.exec(sim.out)?.[1].toLowerCase();
  assert.ok(predicted);
  assert.equal(BigInt(await callSig(kernel, 'token()')), 0n, 'the simulation changed nothing on the node it forked');

  // ── 4. the refusal matrix
  const other = testSigner('launch-check rehearsal: another wallet (not a real key)').address;
  const sig = 'platform signature is valid for this launcher and this calldata';
  const matrix: { field: string; tx: { data: string; from?: string; to?: string; value?: string; kernel?: string }; launchCheck: string[]; sim?: RegExp }[] = [
    { field: 'to: the router instead of the Manager', tx: { data: good, to: ROUTER }, launchCheck: ['to is the IgnixManager proxy', sig] },
    { field: 'selector: buyTo instead of createToken', tx: { data: '0x9415aa2a' + good.slice(10) }, launchCheck: ['function selector is createToken', 'calldata decodes as createToken arguments'] },
    { field: 'templateId 0 (re-signed)', tx: { data: make({ call: { templateId: 0 } }) }, launchCheck: ['templateId is 3 (Directed vault)', 'vault factory argument is the registered template factory'] },
    { field: 'vault recipient: the deployer (re-signed)', tx: { data: make({ call: { vaultData: '0x' + addressWord(deployer) } }) }, launchCheck: ['vault recipient is the kernel'], sim: /^FAIL  sim: the vault RECIPIENT is not the kernel$/m },
    { field: 'quote: an ERC-20 (re-signed)', tx: { data: make({ p: { quote: USDT0 } }) }, launchCheck: ['quote is native OKB (the zero address)'] },
    { field: 'venue 0 (re-signed)', tx: { data: make({ call: { venue: 0 } }) }, launchCheck: ['venue is 1 (Uniswap V2)'] },
    { field: 'curve fees 50 / 100 (re-signed)', tx: { data: make({ p: { buyFeeBps: 50 } }) }, launchCheck: ['curve fees are 100 / 100 bps'] },
    { field: 'tax 100 / 100 (re-signed)', tx: { data: make({ p: { taxBuyBps: 100, taxSellBps: 100 } }) }, launchCheck: ['buy tax and sell tax are the expected values'] },
    { field: 'protection 1 day (re-signed)', tx: { data: make({ call: { graduationProtectionSecs: 86_400n } }) }, launchCheck: ['protection period is the expected value'] },
    { field: 'firstBuy 0.4 OKB, value 0.4 OKB (re-signed)', tx: { data: make({ p: { firstBuy: 4n * 10n ** 17n } }), value: '0.4okb' }, launchCheck: ['firstBuy is 0 (no team buy)', 'msg.value is the listing fee alone'], sim: /^FAIL  sim: tokens were sold inside createToken \(a first buy\)$/m },
    { field: 'value 1 wei above the listing fee', tx: { data: good, value: '1' }, launchCheck: ['msg.value is the listing fee alone'] },
    { field: 'anti-snipe 50% for 30 min (re-signed)', tx: { data: make({ p: { snipeStartBps: 5000, snipeMins: 30 } }) }, launchCheck: ['anti-snipe is off (snipeStartBps 0)'], sim: /^FAIL  sim: anti-snipe is on \(the kernel skips buys while it is\)$/m },
    { field: 'founder round (re-signed)', tx: { data: make({ p: { founderBps: 500, founderSecs: 86_400, founderRoot: FOUNDER_ROOT } }) }, launchCheck: ['no founder round (founderBps 0, founderSecs 0, no founder root)'], sim: /^FAIL  sim: a founder round is open$/m },
    { field: 'deadline 2 minutes away (re-signed)', tx: { data: make({ call: { deadline: now + 120n } }) }, launchCheck: ['signature deadline has at least 3 minutes left'] },
    { field: 'one byte of the salt mis-copied (not re-signed)', tx: { data: good.slice(0, 2 + 8 + 64 * 8 + 64 * 3) + '12' + good.slice(2 + 8 + 64 * 8 + 64 * 3 + 2) }, launchCheck: [sig] },
    { field: 'extra bytes after the arguments', tx: { data: good + 'c0ffee' }, launchCheck: ['calldata carries nothing beyond its arguments'] },
    { field: '--from: another wallet (re-signed for it)', tx: { data: make({ sender: other }), from: other }, launchCheck: ["kernel's envelope launcher is --from"], sim: /^FAIL  sim: the kernel's envelope launcher is not the sender of createToken$/m },
    { field: '--from: another wallet presenting the deployer\'s signature', tx: { data: good, from: other }, launchCheck: [sig, "kernel's envelope launcher is --from"] },
  ];
  const results: string[] = [];
  for (const m of matrix) {
    const r = await runTool(LAUNCH_CHECK, argsFor({ ...m.tx, name: 'case' }), `launch-check (${m.field})`);
    assert.equal(r.code, 1, `${m.field}: refused\n${r.out}`);
    assert.match(r.out, /DO NOT SIGN this transaction\./);
    const got = failedLabels(r.out);
    // decoding failures make every dependent check NOT CHECKED: only the leading ones are pinned for that case
    if (m.field.startsWith('selector')) assert.deepEqual(got.slice(0, 2), m.launchCheck, m.field);
    else assert.deepEqual(got, m.launchCheck, m.field);
    let simVerdict = '';
    if (m.sim) {
      const s = await runTool(SIMULATE, argsFor({ ...m.tx, name: 'case' }), `simulate (${m.field})`);
      assert.equal(s.code, 1, `${m.field}: the simulation refuses\n${s.out}`);
      assert.match(s.out, m.sim, m.field);
      assert.match(s.out, /DO NOT SIGN/);
      simVerdict = (/^FAIL  (.*)$/m.exec(s.out)?.[1] ?? '').trim();
    }
    results.push(`| ${m.field} | ${got.length > 2 && m.field.startsWith('selector') ? got.slice(0, 2).join('; ') + `; and ${got.length - 2} dependent checks NOT CHECKED` : got.join('; ')} | ${simVerdict || 'not run'} |`);
  }
  // a kernel that is not the deployment's: --kernel names the Fab (a contract, not a kernel)
  const wrongKernel = await runTool(LAUNCH_CHECK, argsFor({ data: good, kernel: d.fab as string, name: 'case' }), 'launch-check (--kernel: a contract that is not a kernel)');
  assert.equal(wrongKernel.code, 1);
  for (const label of ['vault recipient is the kernel', 'kernel is the one the deployment / expected-values file names', 'kernel was created by the Covenant KernelFactory (isKernel)']) {
    assert.ok(failedLabels(wrongKernel.out).includes(label), label);
  }
  results.push(`| --kernel: the Fab, not a kernel | ${failedLabels(wrongKernel.out).join('; ')} | simulate refuses before forge: --kernel is not the deployment's kernel (exit code 2) |`);
  const wrongKernelSim = await runTool(SIMULATE, argsFor({ data: good, kernel: d.fab as string, name: 'case' }), 'simulate (--kernel: a contract that is not a kernel)');
  assert.equal(wrongKernelSim.code, 2);
  log('\nREFUSAL MATRIX\n| corrupted field | launch-check FAIL lines | simulate |\n|---|---|---|\n' + results.join('\n') + '\n');

  // ── 5. the real transaction, on the local fork only
  const receipt = await send({ from: deployer, to: MANAGER, data: good, value: '0x0' });
  assert.equal(receipt.status, '0x1', 'createToken succeeded on the local fork');
  const created = receipt.logs.find((l) => l.address.toLowerCase() === MANAGER && l.topics.length === 4) as { topics: string[] };
  const token = '0x' + created.topics[1].slice(26);
  assert.equal(token, predicted, 'the token address simulate printed');
  const vault = asAddress(await callSig(MANAGER, 'vaultOf(address)', addressWord(token)));
  assert.equal(asAddress(await callSig(vault, 'RECIPIENT()')), kernel.toLowerCase(), 'the vault pays the kernel');
  const binder = testSigner('launch-check rehearsal: an unrelated binder (not a real key)').address;
  await rpc('anvil_setBalance', [binder, '0x' + (10n ** 18n).toString(16)]);
  assert.equal((await send({ from: binder, to: kernel, data: selectorOf('bind(address)') + addressWord(token) })).status, '0x1', 'anyone may bind a token the launcher created');
  assert.equal(asAddress(await callSig(kernel, 'token()')), token);
  assert.equal(asAddress(await callSig(d.kernelFactory as string, 'kernelOf(address)', addressWord(token))), kernel.toLowerCase());
  log(`\nsent on the local fork: createToken -> token ${token}, vault ${vault}; bind by ${binder}: ok\n`);

  const again = await runTool(LAUNCH_CHECK, argsFor({ data: good, name: 'good' }), 'launch-check (the same transaction after the launch)');
  assert.equal(again.code, 1);
  assert.ok(again.out.includes(`FAIL  kernel is not bound yet (token() is the zero address): ${show(token)}`));
  const simAgain = await runTool(SIMULATE, argsFor({ data: good, name: 'good' }), 'simulate (the same transaction after the launch)');
  assert.equal(simAgain.code, 1);
  assert.match(simAgain.out, /^FAIL  sim: /m);

  // ── audit-team against the fork: the registry lists the deployer; its history (the deployment) is clean
  const audit = await runTool(AUDIT, ['--deployment', deploymentFile, '--rpc', url, '--no-cache', '--out', join(keepDir, 'audit'), '--quiet'], 'audit-team (on the fork, with the deployment file)');
  assert.match(audit.out, /wallet\(s\) listed in the TeamRegistry .* \(entry 0 is the deployer\)/);
  assert.match(audit.out, /^PASS {11}0 {2}createToken with a first buy/m);
  assert.match(audit.out, /^PASS {11}0 {2}native value sent to a kernel or to its vault/m);
  assert.notEqual(audit.code, 1, 'nothing the deployer did is flagged');
  t.diagnostic(`transcript: ${transcript}`);
});
