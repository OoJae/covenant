// Kernel v2 (USD₮0 quote), rehearsed end to end against the REAL contracts on a local fork of X Layer.
//
//   REHEARSE=1 node --test tools/launch-check/test/rehearsal-v2.test.ts        (about 8 to 12 minutes)
//
// 1. deploy/rehearse-v2.sh deploys KernelFactoryV2, LensV2 and the Flow Governor's v2 kernel (a new chip taped out
//    through the live Fab) on its own anvil fork, impersonating the real deployer (no key), in its own scratch copy,
//    and writes its plan to a scratch file (never deploy/rehearsal-v2.json). test/rehearsal/anvil is first on PATH,
//    so the node outlives the script and this test uses that same fork.
// 2. On that fork only, the IGNIX platform signer is replaced (slot 5, as contracts/probes/test/ProbeBase.sol does)
//    and a USD₮0-quoted Directed launch is built for the deployer with the v2 kernel as recipient.
// 3. launch-check and simulate PASS on it (flat plan file; deployments/xlayer.json completed with coreV2 and
//    flagshipV2). The refusal matrix for the new quote: each change is refused, naming the check.
// 4. The launch is sent TO THE LOCAL FORK ONLY; an unrelated address binds; both tools then refuse it.
// 5. An unrelated buyer buys 10 USD₮0 on the curve and an unrelated payer sends the kernel 0.5 USD₮0 (simulated
//    x402 revenue; no team wallet pays anything). One epoch later the keeper (services/keeper, dry run) plans the
//    settle through the live KeeperTank, and the KeeperTank settles the v2 kernel and refunds the keeper from the
//    v2 chip's own allowance (burned transistors x mint price x 85%), once an unrelated address has called
//    Splitter.pull() on the fork (mint proceeds reach the tank only through it).
// 6. audit-team runs against the fork with the completed deployment file: it knows the v2 kernel, scans USD₮0 out
//    of the team wallets from the KernelFactoryV2's creation, and flags nothing.
//
// The transcript is written to $REHEARSAL_TRANSCRIPT (default: a file in the OS temp directory). Skipped unless
// REHEARSE=1, and when anvil, forge, forge-std or the keeper's dependencies are missing.

import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { USDT0 } from '../checks.ts';
import { MANAGER, selectorOf } from '../decode.ts';
import { parseDeployment } from '../deployment.ts';
import { keccak256 } from '../../../packages/chain/src/keccak.ts';
import { addressWord, bytesToHex, show, word } from '../hex.ts';
import { PLATFORM, launch, testSigner, type LaunchOptions } from './helpers.ts';

const REPO = fileURLToPath(new URL('../../../', import.meta.url));
const SIM = fileURLToPath(new URL('../sim', import.meta.url));
const WRAPPER_DIR = fileURLToPath(new URL('./rehearsal', import.meta.url));
const LAUNCH_CHECK = fileURLToPath(new URL('../launch-check.ts', import.meta.url));
const SIMULATE = fileURLToPath(new URL('../simulate.ts', import.meta.url));
const AUDIT = fileURLToPath(new URL('../../audit-team/audit-team.ts', import.meta.url));
const KEEPER = join(REPO, 'services/keeper/src/index.ts');
const WOKB = '0xe538905cf8410324e03a5a23c1c177a474d59b2b';
const RATE_POOL = '0xe3be6a0137f1b0602fc1a4841686f43b340a5082'; // the USD₮0/WOKB pool: an unrelated USD₮0 holder
const FOUNDER_ROOT = '0x' + '77'.repeat(32);

const which = (cmd: string): string | null => {
  const r = spawnSync('/usr/bin/env', ['which', cmd], { encoding: 'utf8' });
  return r.status === 0 ? r.stdout.trim() : null;
};
const REAL_ANVIL = which('anvil');
const skip =
  process.env.REHEARSE !== '1'
    ? 'set REHEARSE=1 to run (it runs deploy/rehearse-v2.sh, about 8 to 12 minutes)'
    : !REAL_ANVIL
      ? 'anvil is not installed'
      : !which('forge') || !existsSync(SIM + '/lib/forge-std/src/Test.sol')
        ? 'forge or sim/lib/forge-std is not installed'
        : !existsSync(join(REPO, 'services/keeper/node_modules/viem'))
          ? 'services/keeper has no node_modules (pnpm install)'
          : false;

let keepDir = '';
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
const topicOf = (sig: string): string => bytesToHex(keccak256(new TextEncoder().encode(sig)));

interface ReceiptLite {
  status: string;
  gasUsed: string;
  logs: { address: string; topics: string[]; data: string }[];
}
/** Sends a transaction on the LOCAL fork (the rehearsal's anvil impersonates any sender) and waits for it. */
async function send(tx: { from: string; to: string; data?: string; value?: string }): Promise<ReceiptLite> {
  assert.match(url, /^http:\/\/127\.0\.0\.1:\d+$/, 'transactions are only ever sent to the local fork');
  const hash = await rpc('eth_sendTransaction', [{ gas: '0x1c9c380', ...tx }]);
  for (let i = 0; i < 200; i++) {
    const r = await rpc<ReceiptLite | null>('eth_getTransactionReceipt', [hash]);
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
const runTool = async (script: string, args: readonly string[], title: string, env: NodeJS.ProcessEnv = process.env): Promise<{ code: number | null; out: string }> => {
  const r = await runProcess(process.execPath, [script, ...args], env);
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
});

const failedLabels = (out: string): string[] => out.split('\n').filter((l) => l.startsWith('FAIL  ')).map((l) => l.slice(6).replace(/: .*$/, ''));

test('kernel v2 on a fork: the wrapper\'s rehearsal, launch-check and simulate in USD₮0 mode, the refusal matrix, bind, the keeper and the tank, the audit', { skip, timeout: 3_600_000 }, async (t) => {
  keepDir = mkdtempSync(join(tmpdir(), 'launch-check-rehearsal-v2-'));
  transcript = process.env.REHEARSAL_TRANSCRIPT ?? join(tmpdir(), `launch-check-rehearsal-v2-${Date.now()}.txt`);
  writeFileSync(transcript, `kernel v2 rehearsal against the real contracts, ${new Date().toISOString()}\n`);
  t.diagnostic(`transcript: ${transcript}`);

  // ── 1. deploy kernel v2 with deploy/rehearse-v2.sh; its anvil outlives it. The plan goes to a scratch file.
  const port = await freePort();
  url = `http://127.0.0.1:${port}`;
  const payee = testSigner('kernel v2 rehearsal: an unrelated allowance payee (not a real key)').address;
  const plan = join(keepDir, 'plan-v2.json');
  const env = { ...process.env, PATH: `${WRAPPER_DIR}:${process.env.PATH}`, PORT: String(port), REAL_ANVIL: REAL_ANVIL as string, KEEP_DIR: keepDir, REHEARSAL_OUT: plan, ALLOWANCE_PAYEE: payee };
  const started = Date.now();
  const rehearse = await runProcess('bash', [join(REPO, 'deploy/rehearse-v2.sh')], env);
  log(`\n$ PORT=${port} REHEARSAL_OUT=<scratch> deploy/rehearse-v2.sh   (${Math.round((Date.now() - started) / 1000)} s)\n${rehearse.out.split('\n').filter((l) => !/^\s*$/.test(l)).slice(-30).join('\n')}\n(exit code ${rehearse.code}; last 30 lines)\n`);
  assert.equal(rehearse.code, 0, rehearse.out);
  assert.equal(await rpc('eth_chainId'), '0xc4', 'the node rehearse-v2.sh deployed on is still running');
  const flat = parseDeployment(readFileSync(plan, 'utf8'), plan);
  const deployer = flat.deployer as string;
  const kernel = flat.kernelV2 as string;
  const kernelV1 = flat.kernel as string;
  assert.ok(kernel && flat.kernelFactoryV2 && flat.lensV2 && flat.chipIdV2 !== null, 'the plan names the v2 deployment');
  assert.equal(flat.quoteShiftV2, 33n);
  assert.equal(asAddress(await callSig(kernel, 'quote()')), USDT0);

  const live = JSON.parse(readFileSync(join(REPO, 'deployments/xlayer.json'), 'utf8'));
  const nestedFile = join(keepDir, 'xlayer-after-session-3.json');
  writeFileSync(
    nestedFile,
    JSON.stringify({
      ...live,
      coreV2: { kernelFactory: flat.kernelFactoryV2, kernelImpl: flat.kernelImplV2, lens: flat.lensV2, quote: USDT0, quoteShift: 33, txs: [] },
      flagshipV2: { chipId: Number(flat.chipIdV2), kernel, allowancePayee: payee, txs: [] },
    }),
  );
  const tank = live.issuance.keeperTank as string;
  const keeperWallet = (live.keeper as string).toLowerCase();

  // ── 2. fork-only: the platform signer is replaced by the throwaway test signer
  await rpc('anvil_setStorageAt', [MANAGER, '0x5', '0x' + addressWord(PLATFORM.address)]);
  const poolFee = BigInt(await callSig(MANAGER, 'POOL_FEE()'));
  const launchFactory = asAddress(await callSig(MANAGER, 'LAUNCH_FACTORY()'));
  const registry = asAddress(await callSig(MANAGER, 'REGISTRY()'));
  const directed = asAddress(await callSig(registry, 'factoryOf(uint16)', word(3)));
  const chainNow = BigInt((await rpc<{ timestamp: string }>('eth_getBlockByNumber', ['latest', false])).timestamp);
  const wall = BigInt(Math.floor(Date.now() / 1000));
  const now = chainNow > wall ? chainNow : wall;
  /** A USD₮0-quoted Directed launch as ignix.bot would sign it for `sender`, with the v2 kernel as recipient. */
  const make = (o: LaunchOptions = {}): string =>
    launch({ now, poolFee, launchFactory, sender: deployer, ...o, p: { quote: USDT0, graduation: 8_000_000_000n, ...o.p }, call: { vaultData: '0x' + addressWord(kernel), factory: directed, deadline: now + 3600n, ...o.call } }).data;
  const good = make();
  const dataFile = (data: string): string => {
    const f = join(keepDir, `data-${++id}.txt`);
    writeFileSync(f, data + '\n');
    return '@' + f;
  };
  const argsFor = (o: { data: string; from?: string; value?: string; deployment?: string }): string[] => [
    '--deployment',
    o.deployment ?? nestedFile,
    '--from',
    show(o.from ?? deployer),
    '--to',
    show(MANAGER),
    '--value',
    o.value ?? '0',
    '--data',
    dataFile(o.data),
    '--rpc',
    url,
  ];

  // ── 3. the good USD₮0 launch: both tools pass, with either deployment file format
  for (const dep of [nestedFile, plan]) {
    const check = await runTool(LAUNCH_CHECK, argsFor({ data: good, deployment: dep }), `launch-check (the good USD₮0 launch; ${dep === plan ? 'flat plan' : 'nested'})`);
    assert.equal(check.code, 0, check.out);
    assert.match(check.out, /^VERDICT: PASS\. All \d+ checks passed\./m);
    for (const line of [
      '      kernel generation: v2 (contracts/core-v2)',
      `PASS  vault recipient is the kernel: ${show(kernel)}`,
      `PASS  quote is USD₮0 (the v2 kernel's quote asset): ${show(USDT0)}`,
      `PASS  kernel was created by the Covenant KernelFactoryV2 (isKernel): isKernel = true at ${show(flat.kernelFactoryV2 as string)}`,
      `PASS  kernel quotes in USD₮0 with the 33-bit code shift (globals().quote, globals().quoteShift): quote ${show(USDT0)}, shift 33 bits`,
      `PASS  kernel holds its chip (Circuits.ownerOf(kernel.chipId()) is the kernel): chip ${flat.chipIdV2} is owned by ${show(kernel)}`,
      `PASS  platform signature is valid for this launcher and this calldata: signed by ${show(PLATFORM.address)}`,
    ]) {
      assert.ok(check.out.includes(line), line);
    }
  }
  const sim = await runTool(SIMULATE, argsFor({ data: good }), 'simulate (the good USD₮0 launch)');
  assert.equal(sim.code, 0, sim.out);
  assert.match(sim.out, /VERDICT: PASS\./);
  assert.match(sim.out, /kernel v2 \(contracts\/core-v2\): the launch is quoted in USD₮0/);
  assert.match(sim.out, /kernel v2, quote\s+0x779[dD]ed0c9e1022225f8[eE]0630b35a9b54b[eE]713736/);
  assert.match(sim.out, /an unrelated address bought 10 USDT0 on the curve/);
  assert.match(sim.out, /inflow \(USDT0 base units\)\s+300000/, '3% of the 10 USD₮0 an outsider bought');
  const predicted = /token\s+(0x[0-9a-fA-F]{40})/.exec(sim.out)?.[1].toLowerCase();
  assert.ok(predicted);

  // ── the refusal matrix for the new quote
  const other = testSigner('kernel v2 rehearsal: another wallet (not a real key)').address;
  const matrix: { field: string; tx: { data: string; from?: string; value?: string; deployment?: string }; launchCheck: string[]; sim?: RegExp }[] = [
    { field: 'USD₮0 launch, recipient = the v1 kernel (re-signed)', tx: { data: make({ call: { vaultData: '0x' + addressWord(kernelV1) } }) }, launchCheck: ['vault recipient is the kernel'], sim: /^FAIL  sim: the vault RECIPIENT is not the kernel$/m },
    { field: 'OKB launch, recipient = the v2 kernel (re-signed)', tx: { data: make({ p: { quote: '0x0000000000000000000000000000000000000000', graduation: 85n * 10n ** 18n } }) }, launchCheck: ['vault recipient is the kernel'], sim: /^FAIL  sim: the vault RECIPIENT is not the kernel$/m },
    { field: 'WOKB quote, recipient = the v2 kernel (re-signed)', tx: { data: make({ p: { quote: WOKB } }) }, launchCheck: ['vault recipient is the kernel', 'quote is native OKB (the zero address)'] },
    { field: 'the live deployments/xlayer.json (no v2 kernel recorded)', tx: { data: good, deployment: join(REPO, 'deployments/xlayer.json') }, launchCheck: ['vault recipient is the kernel', 'quote is native OKB (the zero address)'] },
    { field: 'msg.value 1 wei', tx: { data: good, value: '1' }, launchCheck: ['msg.value is 0 (a USD₮0 launch pays its listing fee in USD₮0)'], sim: /^FAIL  sim: createToken reverted: BadValue\(\)/m },
    { field: 'listing fee 1 USD₮0 without an allowance (re-signed)', tx: { data: make({ p: { listingFee: 1_000_000n } }) }, launchCheck: ['launcher can pay the USD₮0 listing fee (balance and allowance to the IgnixManager)'], sim: /^FAIL  sim: createToken reverted/m },
    { field: 'first buy 5 USD₮0 (re-signed)', tx: { data: make({ p: { firstBuy: 5_000_000n } }) }, launchCheck: ['firstBuy is 0 (no team buy)'], sim: /^FAIL  sim: createToken reverted/m },
    { field: 'anti-snipe 50% for 30 min (re-signed)', tx: { data: make({ p: { snipeStartBps: 5000, snipeMins: 30 } }) }, launchCheck: ['anti-snipe is off (snipeStartBps 0)'], sim: /^FAIL  sim: anti-snipe is on \(the kernel skips buys while it is\)$/m },
    { field: 'founder round (re-signed)', tx: { data: make({ p: { founderBps: 500, founderSecs: 86_400, founderRoot: FOUNDER_ROOT } }) }, launchCheck: ['no founder round (founderBps 0, founderSecs 0, no founder root)'], sim: /^FAIL  sim: a founder round is open$/m },
    { field: '--from: another wallet (re-signed for it)', tx: { data: make({ sender: other }), from: other }, launchCheck: ["kernel's envelope launcher is --from"], sim: /^FAIL  sim: the kernel's envelope launcher is not the sender of createToken$/m },
  ];
  await rpc('anvil_setBalance', [other, '0x' + (10n ** 18n).toString(16)]);
  const rows: string[] = [];
  for (const m of matrix) {
    const r = await runTool(LAUNCH_CHECK, argsFor(m.tx), `launch-check (${m.field})`);
    assert.equal(r.code, 1, `${m.field}: refused\n${r.out}`);
    assert.match(r.out, /DO NOT SIGN this transaction\./);
    assert.deepEqual(failedLabels(r.out), m.launchCheck, m.field);
    let simVerdict = 'not run';
    if (m.sim) {
      const s = await runTool(SIMULATE, argsFor(m.tx), `simulate (${m.field})`);
      assert.equal(s.code, 1, `${m.field}: the simulation refuses\n${s.out}`);
      assert.match(s.out, m.sim, m.field);
      simVerdict = (/^FAIL  (.*)$/m.exec(s.out)?.[1] ?? '').trim();
    }
    rows.push(`| ${m.field} | ${failedLabels(r.out).join('; ')} | ${simVerdict} |`);
  }
  log('\nREFUSAL MATRIX (USD₮0 quote)\n| change | launch-check FAIL lines | simulate |\n|---|---|---|\n' + rows.join('\n') + '\n');

  // ── 4. the real transaction, on the local fork only; an unrelated address binds
  const receipt = await send({ from: deployer, to: MANAGER, data: good, value: '0x0' });
  assert.equal(receipt.status, '0x1', 'createToken succeeded on the local fork');
  const created = receipt.logs.find((l) => l.address.toLowerCase() === MANAGER && l.topics.length === 4) as { topics: string[] };
  const token = '0x' + created.topics[1].slice(26);
  assert.equal(token, predicted, 'the token address simulate printed');
  const vault = asAddress(await callSig(MANAGER, 'vaultOf(address)', addressWord(token)));
  assert.equal(asAddress(await callSig(vault, 'QUOTE()')), USDT0, 'the vault is quoted in USD₮0');
  const binder = testSigner('kernel v2 rehearsal: an unrelated binder (not a real key)').address;
  await rpc('anvil_setBalance', [binder, '0x' + (10n ** 18n).toString(16)]);
  assert.equal((await send({ from: binder, to: kernel, data: selectorOf('bind(address)') + addressWord(token) })).status, '0x1', 'anyone may bind a token the launcher created');
  assert.equal(asAddress(await callSig(flat.kernelFactoryV2 as string, 'kernelOf(address)', addressWord(token))), kernel.toLowerCase());
  const again = await runTool(LAUNCH_CHECK, argsFor({ data: good }), 'launch-check (the same transaction after the launch)');
  assert.equal(again.code, 1);
  assert.ok(again.out.includes(`FAIL  kernel is not bound yet (token() is the zero address): ${show(token)}`));
  const simAgain = await runTool(SIMULATE, argsFor({ data: good }), 'simulate (the same transaction after the launch)');
  assert.equal(simAgain.code, 1);

  // ── 5. unrelated trading and unrelated revenue; one epoch; the keeper; the KeeperTank
  const buyer = testSigner('kernel v2 rehearsal: an unrelated buyer (not a real key)').address;
  const payer = testSigner('kernel v2 rehearsal: an unrelated x402 payer (not a real key)').address;
  for (const a of [buyer, payer, RATE_POOL]) await rpc('anvil_setBalance', [a, '0x' + (10n ** 18n).toString(16)]);
  const transfer = (to: string, amount: bigint): string => selectorOf('transfer(address,uint256)') + addressWord(to) + word(amount);
  assert.equal((await send({ from: RATE_POOL, to: USDT0, data: transfer(buyer, 20_000_000n) })).status, '0x1', 'an unrelated holder funds the buyer');
  assert.equal((await send({ from: RATE_POOL, to: USDT0, data: transfer(payer, 1_000_000n) })).status, '0x1', 'and the payer');
  assert.equal((await send({ from: buyer, to: USDT0, data: selectorOf('approve(address,uint256)') + addressWord(MANAGER) + word(10_000_000n) })).status, '0x1');
  assert.equal((await send({ from: buyer, to: MANAGER, data: selectorOf('buy(address,uint256,uint256)') + addressWord(token) + word(10_000_000n) + word(0) })).status, '0x1', 'the unrelated buyer buys 10 USD₮0');
  assert.equal((await send({ from: payer, to: USDT0, data: transfer(kernel, 500_000n) })).status, '0x1', 'the unrelated payer pays the kernel 0.5 USD₮0');
  await rpc('evm_increaseTime', [960]);
  await rpc('evm_mine', []);
  assert.equal(BigInt(await callSig(kernel, 'epochNow()')), 1n);

  const keeperEnv = { ...process.env, KERNELS: kernel, TANK: tank, KEEPER_ADDRESS: keeperWallet, RPC_URLS: url, CHAIN_ID: '196', STATE_FILE: 'none', DRY_RUN: '1' };
  const keeper = await runTool(KEEPER, ['--once', '--dry-run'], 'services/keeper --once --dry-run (KERNELS = the v2 kernel, TANK = the live KeeperTank)', keeperEnv);
  assert.equal(keeper.code, 0, keeper.out);
  const events = keeper.out.split('\n').filter((l) => l.startsWith('{')).map((l) => JSON.parse(l) as Record<string, unknown>);
  assert.ok(events.some((e) => e.event === 'kernel_ok' && String(e.kernel).toLowerCase() === kernel.toLowerCase() && String(e.chipId) === String(flat.chipIdV2)), 'the keeper accepts the v2 kernel');
  const plannedSettle = events.find((e) => e.event === 'dry_run') as Record<string, unknown> | undefined;
  assert.ok(plannedSettle, keeper.out);
  assert.equal(plannedSettle.via, 'tank', 'through the KeeperTank');
  assert.equal(plannedSettle.tankFailure, null, 'the tank path itself simulates without a revert');
  const done = events.find((e) => e.event === 'done') as { outcomes: { kind: string }[] };
  assert.deepEqual(done.outcomes.map((o) => o.kind), ['dry_run']);

  const chip = BigInt(flat.chipIdV2 as bigint);
  const burned = BigInt(await callSig(tank, 'burnedOf(uint256)', word(chip)));
  const mintPrice = BigInt(await callSig(tank, 'mintPrice()'));
  const allowance = BigInt(await callSig(tank, 'allowanceOf(uint256)', word(chip)));
  const toppedUp = BigInt(await callSig(tank, 'toppedUp(uint256)', word(chip)));
  assert.equal(burned, 1952n, 'the Flow Governor burned 1,888 NAND + 64 LATCH transistors at its tape-out');
  assert.equal(allowance, (burned * mintPrice * 8500n) / 10_000n + toppedUp, 'the v2 chip has its own allowance: burned x mint price x 85% (+ top-ups)');
  // A refund needs OKB in the tank. Mint proceeds wait in the Transistors contract until anyone calls Splitter.pull()
  // (85% to the tank). On mainnet at the time of writing the tank held 0 OKB: a settle through it then pays no refund.
  // Here an unrelated address pulls first, on the fork only.
  const tankBefore = BigInt(await rpc('eth_getBalance', [tank, 'latest']));
  const puller = testSigner('kernel v2 rehearsal: an unrelated caller of Splitter.pull (not a real key)').address;
  await rpc('anvil_setBalance', [puller, '0x' + (10n ** 18n).toString(16)]);
  assert.equal((await send({ from: puller, to: live.issuance.splitter as string, data: selectorOf('pull()') })).status, '0x1', 'Splitter.pull() (anyone may call it)');
  const tankFunded = BigInt(await rpc('eth_getBalance', [tank, 'latest']));
  assert.ok(tankFunded > tankBefore, 'the pull moved mint proceeds into the tank');
  const spentBefore = BigInt(await callSig(tank, 'spent(uint256)', word(chip)));
  const keeperBefore = BigInt(await rpc('eth_getBalance', [keeperWallet, 'latest']));
  const settled = await send({ from: keeperWallet, to: tank, data: selectorOf('settleAndRefund(address)') + addressWord(kernel) });
  assert.equal(settled.status, '0x1', 'KeeperTank.settleAndRefund settles the v2 kernel');
  const refundedTopic = topicOf('Refunded(uint256,address,address,uint256,uint256)');
  const refunded = settled.logs.find((l) => l.address.toLowerCase() === tank.toLowerCase() && l.topics[0] === refundedTopic);
  assert.ok(refunded, 'the tank emitted Refunded');
  assert.equal(BigInt(refunded.topics[1]), chip, 'for the v2 chip');
  assert.equal('0x' + refunded.topics[2].slice(26), kernel.toLowerCase());
  const paid = BigInt('0x' + refunded.data.slice(66, 130));
  const spentAfter = BigInt(await callSig(tank, 'spent(uint256)', word(chip)));
  assert.equal(spentAfter - spentBefore, paid, 'the refund is charged to the v2 chip\'s own allowance');
  assert.ok(paid > 0n, 'the keeper is refunded once the tank holds OKB');
  assert.ok(paid <= allowance - spentBefore);
  assert.equal(BigInt(await callSig(kernel, 'count()')), 1n, 'one record');
  const record = await callSig(kernel, 'records(uint32)', word(1));
  const inflow = BigInt('0x' + record.slice(2 + 7 * 64, 2 + 8 * 64));
  assert.equal(inflow, 300_000n + 500_000n, 'inflow = the buy tax claimed from the vault + the revenue paid to the kernel (USD₮0 base units)');
  const keeperAfter = BigInt(await rpc('eth_getBalance', [keeperWallet, 'latest']));
  log(`\nKeeperTank.settleAndRefund(v2 kernel) on the fork: tank ${tankBefore} wei before Splitter.pull(), ${tankFunded} after; gas ${BigInt(settled.gasUsed)}, refund ${paid} wei to the keeper (balance ${keeperBefore} -> ${keeperAfter}); chip ${chip}: burned ${burned}, mintPrice ${mintPrice}, allowance ${allowance}, spent ${spentBefore} -> ${spentAfter}; record 1 inflow ${inflow}\n`);

  // ── 6. audit-team against the fork, with the completed deployment file
  const audit = await runTool(AUDIT, ['--deployment', nestedFile, '--rpc', url, '--no-cache', '--out', join(keepDir, 'audit'), '--quiet'], 'audit-team (on the fork, deployment with kernel v2)');
  assert.match(audit.out, /^PASS\s+0\s+USD₮0 sent from a team wallet to a kernel or to its vault/m);
  assert.match(audit.out, /^PASS\s+0\s+native value sent to a kernel or to its vault/m);
  assert.match(audit.out, /^COVERED\s+0\s+USD₮0 transfer\(s\) out of the team wallets in transactions they did not send/m);
  assert.notEqual(audit.code, 1, 'nothing a team wallet did is flagged');
  t.diagnostic(`transcript: ${transcript}`);
});
