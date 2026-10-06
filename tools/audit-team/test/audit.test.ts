// The audit end to end on a chain made of tables (fake-chain.ts): each rule, the warning, the cases in
// which a rule cannot be decided, EIP-7702 authorisations, the cap, retries and the cache. Offline.

import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { addressWord, word } from '../../launch-check/hex.ts';
import { authorizationHash } from '../../launch-check/rlp.ts';
import { launch, testSigner } from '../../launch-check/test/helpers.ts';
import { runAudit, type AuditResult, type Row } from '../audit.ts';
import { Chain } from '../chain.ts';
import { TOPIC, selectorOf, type Known, type Wallet } from '../known.ts';
import { renderMarkdown, toJson, verdictLines } from '../report.ts';
import { FakeChain, MANAGER, ROUTER, WOKB, TAPEOUT, ZERO, known, topicAddress } from './fake-chain.ts';

const W = '0x84ce7bae1b788c7ad985d57721ca428b401ae34d'; // the wallet under audit
const KEEPER = '0x00000000000000000000000000000000000ee9e4';
const KERNEL = '0x00000000000000000000000000000000c0fe0001';
const VAULT = '0x00000000000000000000000000000000c0fe00a1';
const CVREF = '0x00000000000000000000000000000000c0feeeee';
const TRANSISTORS = '0x00000000000000000000000000000000c0fe0003';
const TOKEN_X = '0x1111111111111111111111111111111111eeeeee'; // someone else's IGNIX token
const AGGREGATOR = '0x7c5bee2a8091c3ef39072f64f18fac913060aeaf';
const STRANGER = '0x857963fdb7340ade3cd39d3e5ba2e0ae515896f0';
const HEAD = 5_000;

const wallets: Wallet[] = [{ address: W, role: 'Deployer' }];
const call = (signature: string, args: string = ''): string => selectorOf(signature) + args;

const tradeLog = (token: string, trader: string, isBuy: boolean) => ({ address: MANAGER, topics: [TOPIC.trade, topicAddress(token), topicAddress(trader)], data: '0x' + word(isBuy ? 1 : 0) + word(1).repeat(7) });
const transferLog = (token: string, from: string, to: string) => ({ address: token, topics: [TOPIC.transfer, topicAddress(from), topicAddress(to)], data: '0x' + word(5) });
const approvalLog = (token: string, owner: string, spender: string) => ({ address: token, topics: [TOPIC.approval, topicAddress(owner), topicAddress(spender)], data: '0x' + word(5) });
const singleLog = (emitter: string, operator: string, from: string, to: string) => ({ address: emitter, topics: [TOPIC.transferSingle, topicAddress(operator), topicAddress(from), topicAddress(to)], data: '0x' + word(1) + word(10) });

/** A chain with the Covenant contracts in place: a kernel bound to CVREF, its vault, the transistors. */
function world(): { chain: FakeChain; cfg: Known } {
  const chain = new FakeChain(HEAD);
  chain.ignixTokens.set(CVREF, { creator: W, vault: VAULT });
  chain.ignixTokens.set(TOKEN_X, { creator: STRANGER, vault: '0x00000000000000000000000000000000000000b1' });
  chain.view(KERNEL, 'vault()', '0x' + addressWord(VAULT));
  chain.view(KERNEL, 'token()', '0x' + addressWord(CVREF));
  chain.code.set(AGGREGATOR, '0x60');
  chain.code.set(TRANSISTORS, '0x60');
  chain.code.set(TOKEN_X, '0x60');
  chain.code.set(CVREF, '0x60');
  chain.code.set(VAULT, '0x60');
  return { chain, cfg: known({ kernels: [KERNEL], transistors: TRANSISTORS }) };
}

async function audit(chain: FakeChain, cfg: Known, ws: readonly Wallet[] = wallets, opts: { maxNonces?: number; cachePath?: string | null } = {}): Promise<AuditResult> {
  const c = new Chain({ rpc: chain.rpc(), minIntervalMs: 0, cachePath: opts.cachePath ?? null });
  await c.open();
  const r = await runAudit(c, cfg, ws, { maxNonces: opts.maxNonces });
  c.save();
  return r;
}

const rowsOf = (r: AuditResult): Row[] => r.wallets.flatMap((w) => w.rows);
const flagsOf = (r: AuditResult): string[] => rowsOf(r).map((x) => x.flags.join('+') || (x.unknownTarget ? 'unknown' : 'ok'));
const count = (r: AuditResult, id: string): number => r.rules.find((x) => x.id === id)?.count ?? -1;

test('a wallet that never sent a transaction is clean: zero rows, exit code 0', async () => {
  const { chain, cfg } = world();
  const r = await audit(chain, cfg);
  assert.equal(r.exitCode, 0);
  assert.deepEqual(rowsOf(r), []);
  assert.equal(r.wallets[0].transactionCount, 0);
  for (const rule of r.rules) assert.equal(rule.count, 0);
  const lines = verdictLines(r);
  assert.equal(lines.filter((l) => l.startsWith('PASS')).length, 9);
  assert.match(lines.at(-1) as string, /^VERDICT: CLEAN\. 0 transaction\(s\) of 1 declared wallet\(s\)/);
  assert.match(renderMarkdown(r), /No transaction has ever been sent by this wallet\./);
  // unconfigured Covenant addresses do not matter when there is nothing to classify
  const bare = await audit(new FakeChain(HEAD), known());
  assert.equal(bare.exitCode, 0);
});

test('the life the team wallets are meant to have is clean', async () => {
  const { chain, cfg } = world();
  cfg.splitter = '0x00000000000000000000000000000000c0fe0009';
  cfg.other = { 'Covenant TeamRegistry': '0x00000000000000000000000000000000c0fe000a' };
  chain.add(10, { from: W, to: null, input: '0x6080' }); // a deployment
  chain.add(11, { from: W, to: cfg.splitter, input: call('ignite()'), value: 66n * 10n ** 14n });
  chain.add(12, { from: W, to: cfg.other['Covenant TeamRegistry'], input: call('declare(string)') });
  chain.add(13, { from: W, to: TRANSISTORS, input: call('mint(uint256,uint256)'), value: 10n ** 16n, logs: [singleLog(TRANSISTORS, W, ZERO, W)] });
  chain.add(14, { from: W, to: MANAGER, input: launch({ sender: W }).data, logs: [transferLog(CVREF, ZERO, MANAGER)] });
  chain.add(15, { from: W, to: KERNEL, input: call('bind(address)', addressWord(CVREF)) });
  chain.add(16, { from: W, to: KEEPER, value: 10n ** 17n }); // funding the keeper
  chain.add(20, { from: KEEPER, to: KERNEL, input: call('settle()'), logs: [tradeLog(CVREF, KERNEL, true), transferLog(CVREF, MANAGER, KERNEL)] });
  chain.add(21, { from: KEEPER, to: VAULT, input: call('claimFor(address,address)', addressWord(KERNEL) + addressWord(ZERO)) });
  chain.add(22, { from: W, to: TAPEOUT, input: call('createCPU(string,string,string,uint256,uint256)') });

  const r = await audit(chain, cfg, [...wallets, { address: KEEPER, role: 'Keeper' }]);
  assert.deepEqual(flagsOf(r), ['ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok']);
  assert.equal(r.exitCode, 0);
  assert.equal(r.unknownTargets, 0);
  const rows = rowsOf(r);
  assert.match(rows[0].classification, /^contract creation: deployed 0x[0-9a-f]{40}$/);
  assert.equal(rows[4].classification, 'createToken "CVREF", first buy 0');
  assert.equal(rows[4].selectorName, 'createToken');
  assert.equal(rows[5].classification, 'kernel: bind()');
  assert.match(rows[6].classification, /^to a declared team wallet: plain transfer$/);
  assert.equal(rows[8].classification, 'kernel: settle()');
  assert.equal(rows[9].classification, "kernel's vault: claimFor()");
  assert.equal(r.wallets[0].found, 8);
  assert.equal(r.wallets[1].found, 2);
});

test('each rule is raised by the transaction that breaks it', async () => {
  const { chain, cfg } = world();
  const cases: [string, Parameters<FakeChain['add']>[1], string][] = [
    ['buy on the curve', { from: W, to: MANAGER, input: call('buy(address,uint256,uint256)', addressWord(TOKEN_X)), value: 10n ** 17n }, 'ignix-call'],
    ['buyTo', { from: W, to: MANAGER, input: call('buyTo(address,uint256,uint256,address)') }, 'ignix-call'],
    ['sell', { from: W, to: MANAGER, input: call('sell(address,uint256,uint256)') }, 'ignix-call'],
    ['plain OKB sent to the Manager', { from: W, to: MANAGER, value: 1n }, 'ignix-call'],
    ['createToken with a first buy', { from: W, to: MANAGER, input: launch({ sender: W, p: { firstBuy: 4n * 10n ** 17n } }).data, value: 4n * 10n ** 17n }, 'first-buy'],
    ['createToken that does not decode', { from: W, to: MANAGER, input: launch({ sender: W }).data.slice(0, 300) }, 'first-buy'],
    ['router swap', { from: W, to: ROUTER, input: call('swapExactETHForTokensSupportingFeeOnTransferTokens(uint256,address[],address,uint256)'), value: 10n ** 17n }, 'dex-call'],
    ['WOKB deposit', { from: W, to: WOKB, input: call('deposit()'), value: 10n ** 17n }, 'dex-call'],
    ['approve on an IGNIX token', { from: W, to: TOKEN_X, input: call('approve(address,uint256)') }, 'ignix-token-call'],
    ['transfer of the team\'s own token', { from: W, to: CVREF, input: call('transfer(address,uint256)') }, 'ignix-token-call'],
    ['a sale through an aggregator', { from: W, to: AGGREGATOR, input: '0x0c307f76', logs: [transferLog(TOKEN_X, W, MANAGER), tradeLog(TOKEN_X, W, false)] }, 'ignix-activity'],
    ['a buy through an aggregator for someone else', { from: W, to: AGGREGATOR, input: '0x0c307f76', value: 10n ** 17n, logs: [tradeLog(TOKEN_X, STRANGER, true), transferLog(TOKEN_X, MANAGER, STRANGER)] }, 'ignix-activity'],
    ['an IGNIX token arriving in the wallet', { from: W, to: AGGREGATOR, input: '0x08298b5a', logs: [transferLog(TOKEN_X, AGGREGATOR, W)] }, 'ignix-activity'],
    ['an approval given inside another call', { from: W, to: AGGREGATOR, input: '0x08298b5a', logs: [approvalLog(TOKEN_X, W, AGGREGATOR)] }, 'ignix-activity'],
    ['OKB sent to a kernel', { from: W, to: KERNEL, value: 10n ** 16n }, 'kernel-value'],
    ['OKB sent to a kernel\'s vault', { from: W, to: VAULT, value: 10n ** 16n }, 'kernel-value'],
    ['a transistor transfer', { from: W, to: TRANSISTORS, input: call('safeTransferFrom(address,address,uint256,uint256,bytes)') }, 'transistor-transfer'],
    ['a transistor batch transfer', { from: W, to: TRANSISTORS, input: call('safeBatchTransferFrom(address,address,uint256[],uint256[],bytes)') }, 'transistor-transfer'],
    ['transistors moved by a marketplace', { from: W, to: AGGREGATOR, input: '0xaabbccdd', logs: [singleLog(TRANSISTORS, AGGREGATOR, W, STRANGER)] }, 'transistor-transfer'],
  ];
  cases.forEach(([, tx], i) => chain.add(100 + i, tx));
  const r = await audit(chain, cfg);
  const rows = rowsOf(r);
  cases.forEach(([name, , flag], i) => assert.deepEqual(rows[i].flags, [flag], name));
  assert.equal(r.exitCode, 1);
  assert.equal(count(r, 'ignix-call'), 4);
  assert.equal(count(r, 'first-buy'), 2);
  assert.equal(count(r, 'dex-call'), 2);
  assert.equal(count(r, 'ignix-token-call'), 2);
  assert.equal(count(r, 'ignix-activity'), 4);
  assert.equal(count(r, 'kernel-value'), 2);
  assert.equal(count(r, 'transistor-transfer'), 3);
  assert.match(rows[0].classification, /IgnixManager call other than createToken: buy\(\)/);
  assert.match(rows[4].classification, /createToken "CVREF" WITH A FIRST BUY of 0\.4 OKB/);
  assert.match(rows[5].classification, /could not be decoded/);
  assert.match(rows[10].classification, /THE WALLET SOLD IGNIX token/);
  const lines = verdictLines(r);
  assert.equal(lines.filter((l) => l.startsWith('FLAG')).length, 7);
  for (const l of lines.filter((x) => x.startsWith('FLAG') || x.startsWith('PASS'))) assert.match(l, /\(expected 0/);
  assert.match(lines.at(-1) as string, /^VERDICT: FLAGGED\. 7 rule\(s\) were broken by 19 finding\(s\)/);
  assert.equal(JSON.parse(toJson(r)).verdict, 'FLAGGED');
});

test('what must not be flagged is not', async () => {
  const { chain, cfg } = world();
  chain.add(10, { from: W, to: TRANSISTORS, input: call('mint(uint256,uint256)'), logs: [singleLog(TRANSISTORS, W, ZERO, W)] }); // a mint
  chain.add(11, { from: W, to: TRANSISTORS, input: call('burnFrom(address,uint256,uint256)'), logs: [singleLog(TRANSISTORS, W, W, ZERO)] }); // a burn
  chain.add(12, { from: W, to: KERNEL, input: call('settle()'), logs: [tradeLog(CVREF, KERNEL, true), transferLog(CVREF, MANAGER, KERNEL)] }); // the kernel's own buy
  chain.add(13, { from: W, to: STRANGER, value: 10n ** 17n }); // OKB to an address without code
  chain.add(14, { from: W, to: AGGREGATOR, input: '0x12345678', logs: [transferLog('0x00000000000000000000000000000000000000cc', W, STRANGER)] }); // some other ERC-20
  const r = await audit(chain, cfg);
  assert.deepEqual(flagsOf(r), ['ok', 'ok', 'ok', 'unknown', 'unknown']);
  assert.equal(r.exitCode, 0, 'unknown targets are a warning, not a flag');
  assert.equal(r.unknownTargets, 2);
  assert.match(rowsOf(r)[3].classification, /unknown target \(an address without code\): plain transfer/);
  assert.match(verdictLines(r).join('\n'), /^WARN {11}2 {2}transactions to targets that are not in the known list \(a warning, not a flag\)$/m);
});

test('a reverted transaction is still listed and flagged, and said to have had no effect', async () => {
  const { chain, cfg } = world();
  chain.add(10, { from: W, to: MANAGER, input: call('buy(address,uint256,uint256)'), value: 1n, reverted: true });
  const r = await audit(chain, cfg);
  assert.deepEqual(rowsOf(r)[0].flags, ['ignix-call']);
  assert.match(rowsOf(r)[0].classification, /\[REVERTED: it had no effect\]$/);
  assert.match(verdictLines(r)[0], /^FLAG {11}1 {2}calls to IgnixManager other than createToken \(expected 0; 1 of them reverted\)/);
});

test('a rule that cannot be decided says NOT CHECKED, never PASS, and the exit code is 2', async () => {
  // no kernel configured, and value went to a contract that is not in the known list: it could be a kernel
  const a = new FakeChain(HEAD);
  a.code.set(AGGREGATOR, '0x60');
  a.add(10, { from: W, to: AGGREGATOR, input: '0x12345678', value: 10n ** 16n });
  const ra = await audit(a, known());
  assert.equal(ra.exitCode, 2);
  const kernelLine = verdictLines(ra).find((l) => l.includes('native value sent to a kernel')) as string;
  assert.match(kernelLine, /^NOT CHECKED {7}native value sent to a kernel or to its vault \(expected 0\): no kernel and no KernelFactory is configured/);
  assert.match(verdictLines(ra).join('\n'), /VERDICT: INCOMPLETE\. Nothing was flagged in what was examined, but the audit could not be completed, so this is NOT a clean result/);
  assert.doesNotMatch(verdictLines(ra).join('\n'), /VERDICT: CLEAN/);

  // the same transaction with a kernel configured elsewhere: the target is positively not our kernel
  const rb = await audit(a, known({ kernels: [KERNEL] })).catch((e) => e as Error);
  assert.ok(rb instanceof Error && /kernel .* did not answer vault\(\) and token\(\)/.test(rb.message), 'a configured kernel that does not answer stops the audit');

  // value to an address without code can be decided without knowing the kernels
  const c = new FakeChain(HEAD);
  c.add(10, { from: W, to: STRANGER, value: 10n ** 16n });
  const rc = await audit(c, known());
  assert.equal(rc.exitCode, 0);
  assert.match(verdictLines(rc).find((l) => l.includes('native value sent to a kernel')) as string, /^PASS .*\[no kernel is configured yet; decided because no transaction sent value to an unlisted contract\]$/);

  // transistors not configured, and something that looks like an ERC-1155 transfer
  const d = new FakeChain(HEAD);
  d.code.set(TRANSISTORS, '0x60');
  d.add(10, { from: W, to: TRANSISTORS, input: call('safeTransferFrom(address,address,uint256,uint256,bytes)') });
  d.add(11, { from: W, to: AGGREGATOR, input: '0x12345678', logs: [singleLog('0x00000000000000000000000000000000000000dd', AGGREGATOR, W, STRANGER)] });
  d.code.set(AGGREGATOR, '0x60');
  const rd = await audit(d, known());
  assert.equal(rd.exitCode, 2);
  assert.match(verdictLines(rd).find((l) => l.includes('transfers of Covenant transistors')) as string, /^NOT CHECKED .*covenant\.transistors is not configured in addresses\.json, and 2 transaction\(s\) look like ERC-1155 transfers/);
});

test('a kernel that is not in the list is recognised through the KernelFactory', async () => {
  const FACTORY = '0x00000000000000000000000000000000c0fe0005';
  const chain = new FakeChain(HEAD);
  chain.view(FACTORY, 'isKernel(address)', (data) => '0x' + word(data.endsWith(KERNEL.slice(2)) ? 1 : 0));
  chain.view(KERNEL, 'vault()', '0x' + addressWord(ZERO));
  chain.view(KERNEL, 'token()', '0x' + addressWord(ZERO));
  chain.code.set(AGGREGATOR, '0x60');
  chain.add(10, { from: W, to: KERNEL, value: 10n ** 16n });
  chain.add(11, { from: W, to: AGGREGATOR, input: '0x12345678', value: 10n ** 16n });
  const r = await audit(chain, known({ kernelFactory: FACTORY }));
  assert.deepEqual(rowsOf(r)[0].flags, ['kernel-value']);
  assert.equal(rowsOf(r)[0].targetLabel, 'Covenant kernel (per the KernelFactory)');
  assert.deepEqual(rowsOf(r)[1].undecided, [], 'with the factory configured, an unlisted contract is known not to be a kernel');
  assert.equal(count(r, 'kernel-value'), 1);
});

test('a contract the wallet deployed is named when it is called later', async () => {
  const chain = new FakeChain(HEAD);
  chain.add(10, { from: W, to: null, input: '0x6080' });
  const { createAddress } = await import('../../launch-check/rlp.ts');
  const deployed = createAddress(W, 0);
  chain.code.set(deployed, '0x60');
  chain.add(11, { from: W, to: deployed, input: call('declare(string)') });
  const r = await audit(chain, known());
  assert.match(rowsOf(r)[1].classification, /^unknown target \(a contract deployed by 0x84ce\.\.\.e34d at nonce 0\): declare\(\)|^unknown target \(a contract deployed by 0x84ce\.\.\.e34d at nonce 0\): function /);
  assert.equal(rowsOf(r)[1].unknownTarget, true);
  assert.equal(r.exitCode, 0);
});

test('a vault of an IGNIX token is named', async () => {
  const chain = new FakeChain(HEAD);
  const vault = '0x00000000000000000000000000000000000000b1';
  chain.ignixTokens.set(TOKEN_X, { creator: W, vault });
  chain.view(vault, 'TOKEN()', '0x' + addressWord(TOKEN_X));
  chain.add(10, { from: W, to: vault, input: call('claim(address)', addressWord(ZERO)) });
  const r = await audit(chain, known());
  assert.equal(rowsOf(r)[0].targetLabel, 'IGNIX vault of token 0x1111...eeee');
  assert.equal(rowsOf(r)[0].selectorName, 'claim');
  assert.equal(rowsOf(r)[0].unknownTarget, true);
});

test('a nonce used by an EIP-7702 authorisation is explained, and makes the wallet not a plain account', async () => {
  const signer = testSigner('audit-team test: a wallet that delegates (not a real key)');
  const delegate = '0xe40ccb2d94975c51bff0c004efdfd9b3a5796fa4';
  const chain = new FakeChain(HEAD);
  chain.add(10, { from: signer.address, to: STRANGER, value: 1n });
  const nonce = chain.useNonce(signer.address, 20);
  const auth = { chainId: '0xc4', address: delegate, nonce: '0x' + nonce.toString(16), r: '', s: '', yParity: '' };
  const sig = signer.sign(authorizationHash(auth)).slice(2);
  auth.r = '0x' + sig.slice(0, 64);
  auth.s = '0x' + sig.slice(64, 128);
  auth.yParity = sig.slice(128) === '1b' ? '0x0' : '0x1';
  chain.add(20, { from: STRANGER, to: signer.address, authorizationList: [auth] }); // a relayer carries it
  chain.add(30, { from: signer.address, to: STRANGER, value: 1n });
  chain.code.set(signer.address, '0xef0100' + delegate.slice(2));

  const r = await audit(chain, known(), [{ address: signer.address, role: 'Keeper' }]);
  const rows = rowsOf(r);
  assert.equal(rows.length, 3);
  assert.deepEqual(rows.map((x) => x.kind), ['transaction', 'authorization', 'transaction']);
  assert.match(rows[1].classification, /EIP-7702 AUTHORISATION: the wallet delegated its code to 0xe40ccb2d94975c51bff0c004efdfd9b3a5796fa4 \(carried by a transaction from 0x857963fd/);
  assert.equal(r.wallets[0].transactionCount, 3);
  assert.equal(r.wallets[0].found, 2);
  assert.deepEqual(r.wallets[0].unexplained, []);
  assert.equal(count(r, 'delegation'), 2, 'the authorisation, and the code now at the address');
  assert.equal(count(r, 'unexplained-nonce'), 0);
  assert.equal(r.exitCode, 1);
  assert.match(verdictLines(r).join('\n'), /has code at block 5000 \(EIP-7702 delegation to 0xe40ccb2d94975c51bff0c004efdfd9b3a5796fa4\)/);
});

test('a nonce that nothing explains is a finding, never silently accepted', async () => {
  const chain = new FakeChain(HEAD);
  chain.add(10, { from: W, to: STRANGER, value: 1n });
  chain.useNonce(W, 20); // the count rises, but block 20 holds no transaction of W and no authorisation
  chain.add(20, { from: STRANGER, to: W, value: 1n });
  const r = await audit(chain, known());
  assert.deepEqual(r.wallets[0].unexplained, [1]);
  assert.equal(count(r, 'unexplained-nonce'), 1);
  assert.equal(r.exitCode, 1);
  assert.match(verdictLines(r).join('\n'), /^INCOMPLETE {5}1 {2}transaction\(s\) found for the 2 nonce\(s\)/m);
});

test('--max-nonces looks at the first nonces only and can never give a clean result', async () => {
  const chain = new FakeChain(HEAD);
  for (let i = 0; i < 8; i++) chain.add(100 + 10 * i, { from: W, to: STRANGER, value: 1n });
  const r = await audit(chain, known(), wallets, { maxNonces: 3 });
  assert.equal(r.wallets[0].transactionCount, 8);
  assert.equal(r.wallets[0].audited, 3);
  assert.equal(r.wallets[0].found, 3);
  assert.deepEqual(rowsOf(r).map((x) => x.nonce), [0, 1, 2]);
  assert.equal(r.exitCode, 2);
  assert.match(r.incomplete.join(' '), /only the first 3 of 8 nonces were audited/);
  assert.match(verdictLines(r).join('\n'), /^INCOMPLETE {5}3 {2}transaction\(s\) found for the 8 nonce\(s\).*\[only the first 3 nonces were audited\]$/m);
});

test('rate-limit errors are retried; batches never exceed ten calls', async () => {
  const { chain, cfg } = world();
  for (let i = 0; i < 25; i++) chain.add(100 + 7 * i, { from: W, to: STRANGER, value: 1n });
  chain.flaky.set('eth_getTransactionCount', 3);
  chain.flaky.set('eth_getTransactionReceipt', 2);
  const c = new Chain({ rpc: chain.rpc(), minIntervalMs: 0, cachePath: null });
  await c.open();
  const r = await runAudit(c, cfg, wallets);
  assert.equal(r.wallets[0].found, 25);
  assert.ok(c.stats.retries >= 2, `${c.stats.retries} retries`);
  // FakeChain.rpc() throws on a batch above ten, so reaching this line proves the limit was respected
  assert.ok(c.stats.calls > 100);
});

test('a second run reads the cache; a third finds only what is new', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'audit-team-'));
  try {
    const cachePath = join(dir, 'chain-196.json');
    const { chain, cfg } = world();
    for (let i = 0; i < 12; i++) chain.add(100 + 37 * i, { from: W, to: i === 5 ? MANAGER : STRANGER, value: 1n });
    const run = async (): Promise<{ r: AuditResult; calls: number; hits: number }> => {
      const c = new Chain({ rpc: chain.rpc(), minIntervalMs: 0, cachePath });
      await c.open();
      const r = await runAudit(c, cfg, wallets);
      c.save();
      return { r, calls: c.stats.calls, hits: c.stats.cacheHits };
    };
    const first = await run();
    const second = await run();
    assert.deepEqual(rowsOf(second.r), rowsOf(first.r));
    assert.equal(first.r.wallets[0].found, 12);
    assert.ok(second.calls < first.calls / 4, `second run: ${second.calls} calls, first: ${first.calls}`);
    assert.ok(second.hits >= 24, 'blocks and receipts came from the cache');

    // the chain grows and the wallet acts again: only the new part is searched
    chain.head = HEAD + 2_000;
    chain.add(HEAD + 1_500, { from: W, to: STRANGER, value: 1n });
    const third = await run();
    assert.equal(third.r.wallets[0].found, 13);
    assert.equal(rowsOf(third.r).at(-1)?.block, HEAD + 1_500);
    assert.ok(third.calls < first.calls / 2, `third run: ${third.calls} calls`);

    // a remembered walk that no longer matches the chain is thrown away and the chain is walked again
    const file = JSON.parse(readFileSync(cachePath, 'utf8'));
    assert.equal(file.walks[W].total, 13);
    file.walks[W].total = 5;
    file.walks[W].blocks = file.walks[W].blocks.slice(0, 5);
    writeFileSync(cachePath, JSON.stringify(file));
    const fourth = await run();
    assert.equal(fourth.r.wallets[0].found, 13);
    assert.deepEqual(rowsOf(fourth.r), rowsOf(third.r));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the wrong chain is refused', async () => {
  const chain = new FakeChain(HEAD);
  chain.chainId = 1;
  await assert.rejects(audit(chain, known()), /chain 1, not 196/);
});

test('the report: a markdown table per wallet, a JSON document, and what the method cannot see', async () => {
  const { chain, cfg } = world();
  chain.add(10, { from: W, to: MANAGER, input: launch({ sender: W, p: { firstBuy: 10n ** 17n } }).data, value: 10n ** 17n });
  chain.add(11, { from: W, to: STRANGER, value: 123n * 10n ** 15n });
  const r = await audit(chain, cfg);
  const md = renderMarkdown(r);
  assert.match(md, /\| block \| time \(UTC\) \| nonce \| target \| function \| value \(OKB\) \| classification \| transaction \|/);
  assert.match(md, /\| 10 \| 2023-11-14 22:13:30 \| 0 \| `0x96B51c57e5346D0C0198899243cf851D1E23C309` IgnixManager \| `0xef44bdf2` createToken \| 0\.1 \| createToken "CVREF" WITH A FIRST BUY of 0\.1 OKB \*\*\[FLAG first-buy\]\*\* \|/);
  assert.match(md, /\| 11 \| .* \| 1 \| `0x857963fdB7340aDe3cd39D3e5BA2e0ae515896F0` unknown target \| \(none\) \| 0\.123 \|/);
  assert.match(md, /## What this method cannot see/);
  assert.match(md, /Calls made by contracts on a wallet's behalf/);
  assert.match(md, /Wallets that were never declared/);
  const j = JSON.parse(toJson(r));
  assert.equal(j.block, HEAD);
  assert.equal(j.wallets[0].transactions.length, 2);
  assert.deepEqual(j.wallets[0].transactions[0].flags, ['first-buy']);
  assert.equal(j.wallets[0].transactions[0].valueWei, '100000000000000000');
  assert.equal(j.cannotSee.length, 3);
  assert.equal(j.rules.length, 9);
});

// ───────────────────────────── the on-chain TeamRegistry ─────────────────────────────

/** `at(i)`'s answer: (address wallet, string role, uint256 timestamp). */
const atAnswer = (wallet: string, role: string, timestamp: number): string => {
  const bytes = Buffer.from(role, 'utf8').toString('hex');
  return '0x' + addressWord(wallet) + word(96) + word(timestamp) + word(bytes.length / 2) + bytes.padEnd(Math.ceil(bytes.length / 64) * 64, '0');
};

test('the TeamRegistry is read with count() and at(i): its wallets are audited with the declared ones', async () => {
  const { mergeWallets, decodeAt, decodeCount } = await import('../registry.ts');
  const REGISTRY = '0x00000000000000000000000000000000c0fe000a';
  const { chain, cfg } = world();
  chain.view(REGISTRY, 'count()', '0x' + word(2));
  chain.view(REGISTRY, 'at(uint256)', (data) => {
    const i = Number(BigInt('0x' + data.slice(10)));
    return i === 0 ? atAnswer(W, 'deployer', 1_791_000_000) : i === 1 ? atAnswer(KEEPER, 'keeper: settle only', 1_791_000_600) : null;
  });
  chain.add(10, { from: W, to: REGISTRY, input: call('invite(address)', addressWord(KEEPER)) });
  chain.add(11, { from: KEEPER, to: REGISTRY, input: call('declare(string)') });
  chain.add(20, { from: KEEPER, to: KERNEL, input: call('settle()') });
  const known2 = { ...cfg, deployer: W, teamRegistry: REGISTRY };

  const c = new Chain({ rpc: chain.rpc(), minIntervalMs: 0, cachePath: null });
  await c.open();
  const { withRegistry } = await import('../registry.ts');
  const { wallets: ws, view } = await withRegistry(c, known2, wallets); // docs/WALLETS.md declares only W
  assert.deepEqual(ws.map((w) => w.address), [W, KEEPER]);
  assert.equal(ws[0].role, 'Deployer; TeamRegistry #0: deployer');
  assert.equal(ws[1].role, 'TeamRegistry #1: keeper: settle only');
  assert.deepEqual(view?.onlyInRegistry, [KEEPER]);
  assert.deepEqual(view?.onlyInDoc, []);
  assert.equal(view?.entry0IsDeployer, true);
  const r = await runAudit(c, known2, ws, { registry: view });
  assert.equal(r.exitCode, 0);
  assert.deepEqual(rowsOf(r).map((x) => x.classification), ['Covenant TeamRegistry: invite()', 'Covenant TeamRegistry: declare()', 'kernel: settle()']);
  const lines = verdictLines(r).join('\n');
  assert.match(lines, /^NOTE {11}2 {2}wallet\(s\) listed in the TeamRegistry 0x00000000000000000000000000000000C0Fe000a \(entry 0 is the deployer\); all of them were audited$/m);
  assert.match(lines, /^WARN {11}1 {2}wallet\(s\) listed in the TeamRegistry but not declared in docs\/WALLETS\.md \(a warning, not a flag\): 0x00000000000000000000000000000000000Ee9e4$/m);
  assert.match(lines, /^NOTE {11}0 {2}wallet\(s\) declared in docs\/WALLETS\.md \(or as the deployer\) but not listed in the TeamRegistry/m);
  const md = renderMarkdown(r);
  assert.match(md, /## TeamRegistry\n\n\| entry \| wallet \| role \| declared \(UTC\) \|\n\|---\|---\|---\|---\|\n\| 0 \| `0x84cE7bAe1b788C7aD985D57721cA428b401aE34D` \| deployer \| 2026-10-03 /);
  assert.equal(JSON.parse(toJson(r)).teamRegistry.entries.length, 2);

  // a registry whose entry 0 is not the deployer is not the Covenant registry: the audit is incomplete
  const wrong = mergeWallets(wallets, { address: REGISTRY, entries: [{ index: 0, wallet: STRANGER, role: 'deployer', timestamp: 1 }] }, W);
  assert.equal(wrong.view?.entry0IsDeployer, false);
  assert.deepEqual(wrong.view?.onlyInDoc, [W]);
  const c2 = new Chain({ rpc: chain.rpc(), minIntervalMs: 0, cachePath: null });
  await c2.open();
  const r2 = await runAudit(c2, known2, wrong.wallets, { registry: wrong.view });
  assert.equal(r2.exitCode, 2);
  assert.match(r2.incomplete.join(' '), /entry 0 of the TeamRegistry .* is 0x857963fd.*, not the deployer 0x84ce.*: covenant\.teamRegistry is not the Covenant registry/);

  // the deployer is audited even when the table does not declare it
  assert.deepEqual(mergeWallets([], null, W, KEEPER).wallets, [
    { address: W, role: 'deployer (addresses / deployment file)' },
    { address: KEEPER, role: 'keeper (addresses / deployment file)' },
  ]);

  // strict decoding
  assert.equal(decodeCount('0x' + word(3)), 3);
  assert.throws(() => decodeCount('0x'), /0 bytes; 32 expected/);
  assert.throws(() => decodeCount('0x' + word(10_000)), /not a team registry/);
  assert.deepEqual(decodeAt(atAnswer(KEEPER, 'k', 5), 1), { index: 1, wallet: KEEPER, role: 'k', timestamp: 5 });
  assert.throws(() => decodeAt(atAnswer(KEEPER, 'k', 5) + '00', 1), /not the encoding of \(address, string, uint256\)/);
  assert.throws(() => decodeAt('0x' + word(1n << 200n) + atAnswer(KEEPER, 'k', 5).slice(66), 1), /not an address/);
  assert.throws(() => decodeAt(atAnswer(KEEPER, 'x'.repeat(65), 5), 1), /at most 64/);

  // a registry address that is not a registry stops the audit
  const c3 = new Chain({ rpc: chain.rpc(), minIntervalMs: 0, cachePath: null });
  await c3.open();
  await assert.rejects(withRegistry(c3, { ...known2, teamRegistry: AGGREGATOR }, wallets), /TeamRegistry\.count\(\) at .* reverted/);
});
