// The checks themselves: a launch that satisfies every rule passes, and each way of getting it wrong
// fails the check that names it. Offline: the chain is a table (helpers.ts).

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { createRpc } from '../../../packages/chain/src/index.ts';
import { UsageError, parseExpected, parseFlags, readData } from '../args.ts';
import { readChain } from '../chain.ts';
import { DEFAULT_EXPECTED, calldataLines, chainLines, formatLine, got, missing, verdict, type Expected, type Line, type TxInput } from '../checks.ts';
import { MANAGER, encodeCreateToken, launchDigest } from '../decode.ts';
import { addressWord, formatDuration, formatOkb, parseAddress, parseValue, visible } from '../hex.ts';
import { ENVELOPE_FIELDS, GLOBALS_FIELDS, encodeStruct } from '../kernel-abi.ts';
import { pickCircuits, run } from '../launch-check.ts';
import { CHIP_ID, CIRCUITS, ENVELOPE, FAB, GLOBALS, KERNEL, KERNEL_FACTORY, LAUNCHER, LAUNCH_FACTORY, PLATFORM, POOL_FEE, SEALED_VM, TRANSISTORS, goodWorld, launch, serve, setCall, testSigner, type LaunchOptions, type World } from './helpers.ts';

const NOW = 1_791_150_000n;
/** What a deployment file supplies (see deployment.ts). */
const EXPECTED: Expected = { ...DEFAULT_EXPECTED, circuits: CIRCUITS, kernelFactory: KERNEL_FACTORY, fab: FAB, sealedVM: SEALED_VM, chipId: CHIP_ID };

const txOf = (data: string, over: Partial<TxInput> = {}): TxInput => ({ from: LAUNCHER, to: MANAGER, value: 0n, data, kernel: KERNEL, ...over });
const failed = (lines: readonly Line[]): string[] => lines.filter((l) => l.kind === 'check' && !l.ok).map((l) => l.label);
const good = (o: LaunchOptions = {}) => launch({ now: NOW, ...o });

async function full(o: LaunchOptions = {}, tx: Partial<TxInput> = {}, change: (w: World) => void = () => {}, expected: Expected = EXPECTED) {
  const world = goodWorld(NOW);
  change(world);
  const server = await serve(world);
  try {
    const { data } = good(o);
    const input = txOf(data, tx);
    return await run(input, expected, pickCircuits(expected, undefined), [server.url], NOW);
  } finally {
    await server.close();
  }
}

test('a launch that satisfies every rule passes every check', async () => {
  const report = await full();
  assert.deepEqual(failed(report.lines), []);
  assert.equal(report.ok, true);
  assert.equal(report.failed, 0);
  assert.ok(report.passed >= 32, `${report.passed} checks ran`);
  for (const label of ['kernel was created by the Covenant KernelFactory (isKernel)', "kernel's globals name the deployment's KernelFactory, Fab, SealedVM", "kernel's chip is the deployment's chip"]) {
    assert.ok(report.lines.some((l) => l.kind === 'check' && l.ok && l.label === label), label);
  }
  for (const l of report.lines) if (l.kind === 'check') assert.match(formatLine(l), /^PASS  /);
});

test('each wrong calldata field fails the check that names it, and only calldata checks', () => {
  const cases: [string, LaunchOptions, Partial<TxInput>, string[]][] = [
    ['a first buy', { p: { firstBuy: 4n * 10n ** 17n } }, { value: 4n * 10n ** 17n }, ['firstBuy is 0 (no team buy)', 'msg.value is the listing fee alone']],
    ['value above the listing fee', {}, { value: 1n }, ['msg.value is the listing fee alone']],
    ['anti-snipe on', { p: { snipeStartBps: 5000, snipeMins: 30 } }, {}, ['anti-snipe is off (snipeStartBps 0)']],
    ['a founder round', { p: { founderBps: 500, founderSecs: 86400, founderRoot: '0x' + '77'.repeat(32) } }, {}, ['no founder round (founderBps 0, founderSecs 0, no founder root)']],
    ['a founder root alone', { p: { founderRoot: '0x' + '77'.repeat(32) } }, {}, ['no founder round (founderBps 0, founderSecs 0, no founder root)']],
    ['another recipient', { call: { vaultData: '0x' + addressWord(LAUNCHER) } }, {}, ['vault recipient is the kernel']],
    ['a malformed vaultData', { call: { vaultData: '0x' + addressWord(KERNEL) + '00'.repeat(32) } }, {}, ['vault recipient is the kernel']],
    ['another template', { call: { templateId: 0 } }, {}, ['templateId is 3 (Directed vault)']],
    ['an ERC-20 quote', { p: { quote: '0xa8ddb5cd96b5222afe198316e9a57caa642850d5' } }, {}, ['quote is native OKB (the zero address)']],
    ['venue 0', { call: { venue: 0 } }, {}, ['venue is 1 (Uniswap V2)']],
    ['1% tax', { p: { taxBuyBps: 100, taxSellBps: 100 } }, {}, ['buy tax and sell tax are the expected values']],
    ['one-sided tax', { p: { taxSellBps: 0 } }, {}, ['buy tax and sell tax are the expected values']],
    ['a one-day protection period', { call: { graduationProtectionSecs: 86400n } }, {}, ['protection period is the expected value']],
    ['a wrong curve fee', { p: { buyFeeBps: 50 } }, {}, ['curve fees are 100 / 100 bps']],
    ['another target', {}, { to: '0x182a927119d56008d921126764bf884221b10f59' }, ['to is the IgnixManager proxy']],
  ];
  for (const [name, o, tx, want] of cases) {
    const { data } = good(o);
    const { lines } = calldataLines(txOf(data, tx), EXPECTED);
    assert.deepEqual(failed(lines), want, name);
  }
});

test('a listing fee is accepted when the value pays exactly it, and is shown', () => {
  const { data } = good({ p: { listingFee: 10n ** 16n } });
  const { lines } = calldataLines(txOf(data, { value: 10n ** 16n }), EXPECTED);
  assert.deepEqual(failed(lines), []);
  assert.ok(lines.some((l) => l.kind === 'info' && l.label.startsWith('listing fee') && l.value.startsWith('0.01 OKB')));
});

test('calldata that is not createToken fails, and every dependent check says it was not performed', () => {
  const { data } = good();
  for (const bad of ['0x9415aa2a' + data.slice(10), data.slice(0, 300), '0x']) {
    const { lines, call } = calldataLines(txOf(bad), EXPECTED);
    assert.equal(call, null);
    const f = lines.filter((l) => l.kind === 'check' && !l.ok);
    assert.ok(f.length >= 13, 'every check that needs the arguments failed');
    assert.ok(f.filter((l) => l.value === 'NOT CHECKED').length >= 12);
    for (const l of f) if (l.value === 'NOT CHECKED') assert.match(formatLine(l), /^FAIL  .*could not be performed: the calldata did not decode/);
    assert.equal(verdict(lines).ok, false);
  }
});

test('extra bytes after the arguments fail the canonical-encoding check', () => {
  const { data } = good();
  const { lines } = calldataLines(txOf(data + 'c0ffee'), EXPECTED);
  assert.deepEqual(failed(lines), ['calldata carries nothing beyond its arguments']);
});

test('name and ticker are shown for the human, with invisible characters made visible', () => {
  const { data } = good({ p: { name: 'Covenant​Reference', symbol: 'CVRЕF' } }); // zero-width space; Cyrillic E
  const { lines } = calldataLines(txOf(data), EXPECTED);
  const name = lines.find((l) => l.label.startsWith('name'));
  const ticker = lines.find((l) => l.label.startsWith('ticker'));
  assert.equal(name?.kind, 'info');
  assert.match(String(name?.value), /Covenant\\u200bReference/);
  assert.match(String(ticker?.value), /CVR\\u0415F/);
  assert.match(String(ticker?.value), /outside printable ASCII/);
  // with expected values they become checks
  const strict = calldataLines(txOf(data), { ...EXPECTED, name: 'Covenant Reference', symbol: 'CVREF' }).lines;
  assert.deepEqual(failed(strict), ['name is the expected name', 'ticker is the expected ticker']);
  const exact = calldataLines(txOf(good().data), { ...EXPECTED, name: 'Covenant Reference', symbol: 'CVREF' }).lines;
  assert.deepEqual(failed(exact), []);
});

test('the kernel named in the deployment / expected-values file must be the --kernel', () => {
  const { data } = good();
  assert.deepEqual(failed(calldataLines(txOf(data), { ...EXPECTED, kernel: KERNEL }).lines), []);
  assert.deepEqual(failed(calldataLines(txOf(data), { ...EXPECTED, kernel: LAUNCHER }).lines), ['kernel is the one the deployment / expected-values file names']);
});

test('each wrong chain fact fails the check that names it', async () => {
  const zero = '0x' + '00'.repeat(32);
  const cases: [string, (w: World) => void, string[]][] = [
    ['kernel without code', (w) => w.code.delete(KERNEL), ['kernel address has code']],
    ['kernel already bound', (w) => setCall(w, KERNEL, 'token()', '0x' + addressWord('0x995546dfdf93bef59c35742ab5f4762fbcb8eeee')), ['kernel is not bound yet (token() is the zero address)']],
    ['another launcher in the envelope', (w) => setCall(w, KERNEL, 'envelope()', encodeStruct(ENVELOPE_FIELDS, { ...ENVELOPE, launcher: '0xc12fbf15df59800f39f2ebb34c9cbdce150ae404' })), ["kernel's envelope launcher is --from"]],
    ['chip owned by someone else', (w) => setCall(w, CIRCUITS, 'ownerOf(uint256)', '0x' + addressWord(LAUNCHER)), ['kernel holds its chip (Circuits.ownerOf(kernel.chipId()) is the kernel)']],
    ['chip does not exist', (w) => setCall(w, CIRCUITS, 'ownerOf(uint256)', null), ['kernel holds its chip (Circuits.ownerOf(kernel.chipId()) is the kernel)']],
    ['kernel wired to another manager', (w) => setCall(w, KERNEL, 'globals()', encodeStruct(GLOBALS_FIELDS, { ...GLOBALS, manager: '0x126f5088cf077944933f5741fb71a6cc40f2942a' })), ['kernel is wired to the IgnixManager proxy']],
    ['kernel wired to another processor', (w) => setCall(w, KERNEL, 'globals()', encodeStruct(GLOBALS_FIELDS, { ...GLOBALS, circuits: '0x00000000000000000000000000000000c0fe00ff' })), ["Circuits address is the kernel's own processor"]],
    ['Circuits not a TapeOut processor', (w) => setCall(w, '0x1f09daefa827f02cbb40967cc91b259763760761', 'isCPU(address)', zero), ['Circuits is a processor created by the TapeOut factory']],
    ['another chain', (w) => (w.chainId = 1n), ['RPC endpoint is X Layer (chain id 196)', 'platform signature is valid for this launcher and this calldata']],
    ['signer rotated', (w) => setCall(w, MANAGER, 'signer()', '0x' + addressWord(LAUNCHER)), ['platform signature is valid for this launcher and this calldata']],
    ['pool fee changed after signing', (w) => setCall(w, MANAGER, 'POOL_FEE()', '0x' + (500).toString(16).padStart(64, '0')), ['platform signature is valid for this launcher and this calldata']],
    ['template factory rotated', (w) => setCall(w, '0xce65471a6c6950e17f4b527b20b0af8a8f905311', 'factoryOf(uint16)', '0x' + addressWord(LAUNCHER)), ['vault factory argument is the registered template factory']],
    ['launches paused', (w) => setCall(w, MANAGER, 'pausedUntil(uint256)', '0x' + (NOW + 3600n).toString(16).padStart(64, '0')), ['launches are not paused on the Manager']],
    ['a kernel the KernelFactory did not create', (w) => setCall(w, KERNEL_FACTORY, 'isKernel(address)', zero), ['kernel was created by the Covenant KernelFactory (isKernel)']],
    ['a kernel wired to another Fab', (w) => setCall(w, KERNEL, 'globals()', encodeStruct(GLOBALS_FIELDS, { ...GLOBALS, fab: '0x00000000000000000000000000000000c0fe00f6' })), ["kernel's globals name the deployment's KernelFactory, Fab, SealedVM"]],
    ['a kernel built by another factory', (w) => setCall(w, KERNEL, 'globals()', encodeStruct(GLOBALS_FIELDS, { ...GLOBALS, factory: '0x00000000000000000000000000000000c0fe00f5' })), ["kernel's globals name the deployment's KernelFactory, Fab, SealedVM"]],
    ['another chip than the deployment says', (w) => {
      setCall(w, KERNEL, 'chipId()', '0x' + (CHIP_ID + 1n).toString(16).padStart(64, '0'));
      setCall(w, CIRCUITS, 'ownerOf(uint256)', '0x' + addressWord(KERNEL));
      setCall(w, KERNEL, 'globals()', encodeStruct(GLOBALS_FIELDS, { ...GLOBALS, chipId: CHIP_ID + 1n }));
    }, ["kernel's chip is the deployment's chip"]],
    ['chain clock past the deadline', (w) => (w.timestamp = NOW + 1801n), ['signature deadline has at least 3 minutes left']],
    ['two minutes left', (w) => (w.timestamp = NOW + 1800n - 120n), ['signature deadline has at least 3 minutes left']],
  ];
  for (const [name, change, want] of cases) {
    const world = goodWorld(NOW);
    change(world);
    const server = await serve(world);
    try {
      const { data, call } = good();
      const tx = txOf(data);
      const rpc = createRpc([server.url]);
      const facts = await readChain(rpc, tx, call, got(CIRCUITS), NOW, KERNEL_FACTORY);
      assert.deepEqual(failed(chainLines(tx, call, EXPECTED, facts)), want, name);
    } finally {
      await server.close();
    }
  }
});

test('exactly three minutes left passes; one second less fails', async () => {
  for (const [left, ok] of [[180n, true], [179n, false]] as const) {
    const world = goodWorld(NOW);
    world.timestamp = NOW + 1800n - left;
    const server = await serve(world);
    try {
      const { data, call } = good();
      const tx = txOf(data);
      const facts = await readChain(createRpc([server.url]), tx, call, got(CIRCUITS), NOW, KERNEL_FACTORY);
      const line = chainLines(tx, call, EXPECTED, facts).find((l) => l.label.startsWith('signature deadline'));
      assert.equal(line?.ok, ok);
      assert.match(String(line?.value), ok ? /^3 min left/ : /^2 min 59 s left/);
    } finally {
      await server.close();
    }
  }
});

test('the later of the chain clock and the local clock decides the deadline', async () => {
  const world = goodWorld(NOW); // chain says plenty of time
  const server = await serve(world);
  try {
    const { data, call } = good();
    const tx = txOf(data);
    const facts = await readChain(createRpc([server.url]), tx, call, got(CIRCUITS), NOW + 1750n, KERNEL_FACTORY); // this machine says 50 s left
    assert.deepEqual(failed(chainLines(tx, call, EXPECTED, facts)), ['signature deadline has at least 3 minutes left']);
  } finally {
    await server.close();
  }
});

test('the signature check ties the calldata to --from', async () => {
  // the platform signed for LAUNCHER; another wallet presents the same calldata
  const other = '0xc12fbf15df59800f39f2ebb34c9cbdce150ae404';
  const report = await full({}, { from: other });
  assert.deepEqual(failed(report.lines), ['platform signature is valid for this launcher and this calldata', "kernel's envelope launcher is --from"]);
  // a signature by someone who is not the platform
  const forged = await full({ signer: testSigner('launch-check tests: not the platform (not a real key)') });
  assert.deepEqual(failed(forged.lines), ['platform signature is valid for this launcher and this calldata']);
  // one byte of the calldata mis-copied (the salt)
  const world = goodWorld(NOW);
  const server = await serve(world);
  try {
    const { call } = good();
    const tampered = encodeCreateToken({ ...call, p: { ...call.p, salt: '0x' + '12' + '11'.repeat(31) } });
    const r = await run(txOf(tampered), EXPECTED, got(CIRCUITS), [server.url], NOW);
    assert.deepEqual(failed(r.lines), ['platform signature is valid for this launcher and this calldata']);
  } finally {
    await server.close();
  }
  assert.equal(launchDigest(good().call, { chainId: 196, manager: MANAGER, sender: LAUNCHER, poolFee: POOL_FEE, launchFactory: LAUNCH_FACTORY }).length, 32);
  assert.match(PLATFORM.address, /^0x[0-9a-f]{40}$/);
});

test('a check that cannot be performed is a failure and says why', async () => {
  // no Circuits address at all
  const none = await full({}, {}, () => {}, { ...EXPECTED, circuits: null });
  const f = none.lines.filter((l) => l.kind === 'check' && !l.ok);
  assert.ok(f.length >= 4);
  for (const l of f) {
    assert.equal(l.value, 'NOT CHECKED');
    assert.match(String(l.detail), /could not be performed: no Circuits address was given/);
  }
  assert.equal(none.ok, false);

  // no deployment file: the KernelFactory is unknown, so the kernel's origin cannot be checked
  const bare = await full({}, {}, () => {}, { ...EXPECTED, kernelFactory: null, fab: null, sealedVM: null, chipId: null });
  assert.deepEqual(failed(bare.lines), ['kernel was created by the Covenant KernelFactory (isKernel)']);
  assert.match(formatLine(bare.lines.find((l) => l.label.startsWith('kernel was created')) as Line), /NOT CHECKED .*no KernelFactory address was given: pass --deployment/);
  assert.equal(bare.ok, false);

  // the kernel does not answer envelope() the way the snapshot says (one extra word)
  const drift = await full({}, {}, (w) => setCall(w, KERNEL, 'envelope()', encodeStruct(ENVELOPE_FIELDS, { ...ENVELOPE }) + '00'.repeat(32)));
  assert.deepEqual(failed(drift.lines), ["kernel's envelope launcher is --from"]);
  assert.match(String(drift.lines.find((l) => l.label === "kernel's envelope launcher is --from")?.detail), /could not be performed: kernel\.envelope\(\) returned 480 bytes; 448 expected \(the ABI differs/);

  // the node fails
  const broken = await full({}, {}, (w) => w.broken.add('eth_call'));
  assert.equal(broken.ok, false);
  const notChecked = broken.lines.filter((l) => l.kind === 'check' && l.value === 'NOT CHECKED');
  assert.ok(notChecked.length >= 9, `${notChecked.length} checks could not be performed`);
  for (const l of notChecked) assert.match(formatLine(l), /^FAIL  /);
  // eth_getCode still works in this world, so the two "has code" checks may pass; nothing that needs eth_call may
  const needsCall = /not bound|envelope launcher|wired to|own processor|created by the TapeOut factory|holds its chip|chipId\(\) and globals|signature is valid|paused|registered|KernelFactory|globals name|deployment's chip/;
  const callChecks = broken.lines.filter((l) => l.kind === 'check' && needsCall.test(l.label));
  assert.equal(callChecks.length, 13);
  for (const l of callChecks) assert.equal(l.ok, false, `${l.label} must not say PASS`);
});

test('an unreachable node fails every chain check and never says PASS for one', async () => {
  const { data } = good();
  const report = await run(txOf(data), EXPECTED, got(CIRCUITS), ['http://127.0.0.1:9']);
  assert.equal(report.ok, false);
  const chain = report.lines.filter((l) => l.kind === 'check' && /RPC endpoint|deadline|signature is valid|registered|paused|kernel|Circuits/.test(l.label) && !l.label.startsWith('vault recipient'));
  assert.ok(chain.length >= 12);
  for (const l of chain) assert.equal(l.ok, false, l.label);
});

test('--circuits and the expected-values file must agree', () => {
  assert.deepEqual(pickCircuits({ ...DEFAULT_EXPECTED, circuits: CIRCUITS }, undefined), got(CIRCUITS));
  assert.deepEqual(pickCircuits({ ...DEFAULT_EXPECTED }, CIRCUITS), got(CIRCUITS));
  assert.deepEqual(pickCircuits({ ...DEFAULT_EXPECTED, circuits: CIRCUITS }, CIRCUITS), got(CIRCUITS));
  assert.equal(pickCircuits({ ...DEFAULT_EXPECTED, circuits: CIRCUITS }, KERNEL).ok, false);
  assert.equal(pickCircuits({ ...DEFAULT_EXPECTED }, undefined).ok, false);
  assert.deepEqual(missing<string>('x'), { ok: false, error: 'x' });
});

test('the expected transistor contract is compared when the file names it', async () => {
  const okReport = await full({}, {}, () => {}, { ...EXPECTED, transistors: TRANSISTORS });
  assert.deepEqual(failed(okReport.lines), []);
  const bad = await full({}, {}, () => {}, { ...EXPECTED, transistors: KERNEL });
  assert.deepEqual(failed(bad.lines), ["Circuits' transistor contract is the expected one"]);
});

test('expected.cvref.json states the reference token and is accepted', () => {
  const text = readFileSync(new URL('../expected.cvref.json', import.meta.url), 'utf8');
  const e = parseExpected(text);
  // the file pins the native OKB quote: a launch it describes is checked against kernel v1 only
  assert.deepEqual(e, { taxBuyBps: 300, taxSellBps: 300, protectionSecs: 8_640_000, name: null, symbol: null, kernel: null, circuits: null, transistors: null, kernelFactory: null, fab: null, sealedVM: null, chipId: null, generation: 'v1', quote: '0x0000000000000000000000000000000000000000', quoteShift: null });
  const raw = JSON.parse(text);
  assert.equal(raw.templateId, 3);
  assert.equal(raw.venue, 1);
  assert.equal(raw.quote, '0x0000000000000000000000000000000000000000');
  assert.equal(raw.kernel, null);
  assert.deepEqual(raw.processor, { circuits: null, transistors: null });
});

test('an expected-values file cannot relax a fixed rule, and a misspelt key is refused', () => {
  for (const bad of ['{"firstBuy":"1"}', '{"templateId":0}', '{"venue":0}', '{"snipeStartBps":5000}', '{"founderBps":100}', '{"quote":"0xa8ddb5cd96b5222afe198316e9a57caa642850d5"}', '{"chainId":1}', '{"manager":"0x126f5088cf077944933f5741fb71a6cc40f2942a"}', '{"taxBuyBp":300}', '{"taxBuyBps":"300"}', '{"taxBuyBps":1001}', '{"processor":{"circuit":null}}', '{"kernel":"0x123"}', '[]', 'not json']) {
    assert.throws(() => parseExpected(bad), UsageError, bad);
  }
  assert.deepEqual(parseExpected('{"taxBuyBps":500,"taxSellBps":200,"protectionSecs":86400,"name":"A","symbol":"B"}'), { ...DEFAULT_EXPECTED, taxBuyBps: 500, taxSellBps: 200, protectionSecs: 86400, name: 'A', symbol: 'B' });
});

test('command-line values are parsed exactly', () => {
  assert.equal(parseValue('0'), 0n);
  assert.equal(parseValue('400000000000000000'), 4n * 10n ** 17n);
  assert.equal(parseValue('0x58d15e176280000'), 4n * 10n ** 17n);
  assert.equal(parseValue('0.4okb'), 4n * 10n ** 17n);
  assert.equal(parseValue('0.4 OKB'), 4n * 10n ** 17n);
  assert.equal(parseValue('1okb'), 10n ** 18n);
  assert.equal(parseValue('0.000000000000000001okb'), 1n);
  for (const bad of ['0.4', '1e18', '-1', '0.0000000000000000001okb', 'okb', '']) assert.throws(() => parseValue(bad), /not a wei amount/, bad);
  assert.equal(formatOkb(4n * 10n ** 17n), '0.4');
  assert.equal(formatOkb(0n), '0');
  assert.equal(formatOkb(85n * 10n ** 18n + 1n), '85.000000000000000001');
  assert.equal(formatDuration(8_640_000n), '100 d');
  assert.equal(formatDuration(0n), '0 s');
  assert.equal(formatDuration(3725n), '1 h 2 min 5 s');
  assert.equal(visible('a​b\\'), 'a\\u200bb\\\\');

  assert.equal(parseAddress('0x84cE7bAe1b788C7aD985D57721cA428b401aE34D'), LAUNCHER);
  assert.equal(parseAddress(LAUNCHER), LAUNCHER);
  assert.throws(() => parseAddress('0x84cE7bAe1b788C7aD985D57721cA428b401aE34d'), /wrong EIP-55 checksum/, 'last letter case changed');
  assert.throws(() => parseAddress('0x84ce7bae1b788c7ad985d57721ca428b401ae3'), /not a 20-byte hex address/);

  assert.equal(readData(' 0xEF44 bdf2\n'), '0xef44bdf2');
  assert.equal(readData('ef44bdf2'), '0xef44bdf2');
  assert.throws(() => readData('0xef4'), UsageError);
  assert.throws(() => readData('createToken(...)'), /not hex/);
  assert.throws(() => readData('@/nonexistent/file'), /cannot read/);

  const flags = parseFlags(['--from', 'a', '--json', '--rpc=http://x'], { from: 'value', json: 'flag', rpc: 'value' });
  assert.deepEqual([...flags], [['from', 'a'], ['json', 'true'], ['rpc', 'http://x']]);
  assert.throws(() => parseFlags(['--from'], { from: 'value' }), /needs a value/);
  assert.throws(() => parseFlags(['--form', 'a'], { from: 'value' }), /unknown option --form/);
  assert.throws(() => parseFlags(['--from', 'a', '--from', 'b'], { from: 'value' }), /given twice/);
  assert.throws(() => parseFlags(['stray'], { from: 'value' }), /unexpected argument/);
});
