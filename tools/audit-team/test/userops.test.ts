// A team wallet that is a smart wallet (EIP-7702 delegation to a known implementation, acting through ERC-4337):
// its code is not a finding, its user operations are found on the EntryPoint and audited from their own logs.
// Offline: a chain made of tables (fake-chain.ts), with eth_getLogs limited to 100 blocks like the public endpoint.

import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { addressWord, word } from '../../launch-check/hex.ts';
import { authorizationHash } from '../../launch-check/rlp.ts';
import { testSigner } from '../../launch-check/test/helpers.ts';
import { runAudit, type AuditResult, type Row } from '../audit.ts';
import { Chain, type Receipt } from '../chain.ts';
import { TOPIC, type Known } from '../known.ts';
import { renderMarkdown, toJson, verdictLines } from '../report.ts';
import { UO_TOPIC, decodeUserOpEvent, segmentOf } from '../userops.ts';
import { FakeChain, MANAGER, ZERO, known, topicAddress } from './fake-chain.ts';

const OKX_IMPL = '0xe40ccb2d94975c51bff0c004efdfd9b3a5796fa4';
const EP7 = '0x0000000071727de22e5e9d8baf0edac6f37da032';
const EP6 = '0x5ff137d4b0fdcd49dca30c7cf57e578a026d2789';
const BUNDLER = '0xaf3d82c239e211956fd38465692739ad61ebe052';
const REGISTRY_721 = '0x8004a169fb4a3325136eb29fa0ceb6d2e539a432';
const OTHER_SENDER = '0x1111111111111111111111111111111111111111';
const STRANGER = '0x857963fdb7340ade3cd39d3e5ba2e0ae515896f0';
const TOKEN_X = '0x1111111111111111111111111111111111eeeeee';
const TRANSISTORS = '0x00000000000000000000000000000000c0fe0003';
const KERNEL = '0x00000000000000000000000000000000c0fe0001';
const VAULT = '0x00000000000000000000000000000000c0fe00a1';
const CVREF = '0x00000000000000000000000000000000c0feeeee';
const HEAD = 5_000;

const agent = testSigner('audit-team test: an OKX Agentic Wallet (not a real key)');
const A = agent.address;

const beforeExec = { address: EP7, topics: [UO_TOPIC.beforeExecution], data: '0x' };
const uoe = (sender: string, hash: string, success = true, nonce = 0n) => ({
  address: EP7,
  topics: [UO_TOPIC.userOperationEvent, hash, topicAddress(sender), topicAddress(ZERO)],
  data: '0x' + word(nonce) + word(success ? 1 : 0) + word(376_643n) + word(376_643n),
});
const transfer = (token: string, from: string, to: string) => ({ address: token, topics: [TOPIC.transfer, topicAddress(from), topicAddress(to)], data: '0x' + word(5) });
const trade = (token: string, trader: string) => ({ address: MANAGER, topics: [TOPIC.trade, topicAddress(token), topicAddress(trader)], data: '0x' + word(1) + word(1).repeat(7) });
const single = (from: string, to: string) => ({ address: TRANSISTORS, topics: [TOPIC.transferSingle, topicAddress(from), topicAddress(from), topicAddress(to)], data: '0x' + word(1) + word(10) });
const H = (n: number): string => '0x' + word(0xe0a47642n * 1000n + BigInt(n));

function authorization(nonce: number) {
  const auth = { chainId: '0xc4', address: OKX_IMPL, nonce: '0x' + nonce.toString(16), r: '', s: '', yParity: '' };
  const sig = agent.sign(authorizationHash(auth)).slice(2);
  auth.r = '0x' + sig.slice(0, 64);
  auth.s = '0x' + sig.slice(64, 128);
  auth.yParity = sig.slice(128) === '1b' ? '0x0' : '0x1';
  return auth;
}

/** The registration, as on X Layer: the 7702 authorisation and the user operation in one bundle (a type-4 transaction). */
function world(): { chain: FakeChain; cfg: Known } {
  const chain = new FakeChain(HEAD);
  chain.code.set(EP7, '0x60');
  chain.code.set(REGISTRY_721, '0x60');
  chain.code.set(TRANSISTORS, '0x60');
  chain.code.set(TOKEN_X, '0x60');
  chain.ignixTokens.set(TOKEN_X, { creator: STRANGER, vault: '0x00000000000000000000000000000000000000b1' });
  const nonce = chain.useNonce(A, 1_000);
  chain.add(1_000, {
    from: BUNDLER,
    to: EP7,
    input: '0x765e827f',
    authorizationList: [authorization(nonce)],
    logs: [
      beforeExec,
      transfer(REGISTRY_721, ZERO, A), // the agent identity NFT minted to the wallet
      { address: REGISTRY_721, topics: ['0xf8e1a15aba9398e019f0b49df1a4fde98ee17ae345cb5f6b5e2c27f5033e8ce7'], data: '0x' + word(14683) },
      uoe(A, H(1)),
      // another sender's operation in the same bundle: its IGNIX trade is not the wallet's
      trade(TOKEN_X, OTHER_SENDER),
      transfer(TOKEN_X, MANAGER, OTHER_SENDER),
      uoe(OTHER_SENDER, H(2)),
    ],
  });
  chain.code.set(A, '0xef0100' + OKX_IMPL.slice(2));
  const cfg = known({
    transistors: TRANSISTORS,
    smartWallets: { [OKX_IMPL]: 'OKX SmartWalletEntry (verified on OKLink)' },
    entryPoints: [
      { address: EP7, label: 'EntryPoint v0.7' },
      { address: EP6, label: 'EntryPoint v0.6' },
    ],
  });
  return { chain, cfg };
}

async function audit(chain: FakeChain, cfg: Known, cachePath: string | null = null): Promise<{ r: AuditResult; c: Chain }> {
  const c = new Chain({ rpc: chain.rpc(), minIntervalMs: 0, cachePath });
  await c.open();
  const r = await runAudit(c, cfg, [{ address: A, role: 'Covenant Architect (OKX.AI agent wallet)' }]);
  c.save();
  return { r, c };
}
const rows = (r: AuditResult): Row[] => r.wallets.flatMap((w) => w.rows);
const count = (r: AuditResult, id: string): number => r.rules.find((x) => x.id === id)?.count ?? -1;

test('an OKX Agentic Wallet: its delegation is not a finding, and its registration user operation is listed and clean', async () => {
  const { chain, cfg } = world();
  const { r } = await audit(chain, cfg);
  const w = r.wallets[0];
  assert.deepEqual(w.smartWallet, { implementation: OKX_IMPL, label: 'OKX SmartWalletEntry (verified on OKLink)' });
  assert.equal(w.transactionCount, 1);
  assert.deepEqual(w.unexplained, []);
  assert.deepEqual(rows(r).map((x) => x.kind), ['authorization', 'userOperation']);
  const [auth, op] = rows(r);
  assert.match(auth.classification, /delegated its code to 0xe40ccb2d94975c51bff0c004efdfd9b3a5796fa4, a known smart-wallet implementation: OKX SmartWalletEntry/);
  assert.equal(op.userOpHash, H(1));
  assert.match(op.hash, /^0x[0-9a-f]{64}$/, 'the bundle transaction');
  assert.equal(op.valueWei, '');
  assert.deepEqual(op.flags, []);
  assert.match(op.classification, /^USER OPERATION 0x00000000\.\.\. through EntryPoint v0\.7, bundled by 0xaf3d\.\.\.e052: succeeded; 2 event\(s\) in its execution \(2 from 0x8004\.\.\.a432\)$/);
  assert.equal(count(r, 'delegation'), 0);
  assert.equal(count(r, 'ignix-activity'), 0, "the other sender's trade in the same bundle is not the wallet's");
  assert.equal(r.exitCode, 0);
  const lines = verdictLines(r).join('\n');
  assert.match(lines, /^COVERED {8}1 {2}user operation\(s\) of .* found through EntryPoint v0\.7 in blocks 1000\.\.5000 \(UserOperationEvent logs\); EntryPoint v0\.6 has no code on X Layer, so no operation can go through it$/m);
  assert.match(lines, /^COMPLETE {7}0 {2}transaction\(s\) and 1 authorisation\(s\) found for the 1 nonce\(s\) of /m);
  assert.match(lines, /^VERDICT: CLEAN\./m);
  const md = renderMarkdown(r);
  assert.match(md, /This address is a smart wallet: its code is the EIP-7702 designator to `0xe40CCb2d94975C51Bff0c004efdFD9B3a5796FA4`/i);
  assert.match(md, /\| 1000 \| .* \| op 0 \| `0x0000000071727De22E5E9d8BAf0edAc6f37da032` EntryPoint v0\.7 \(user operation\) \| \(user operation\) \| not visible \|/);
  assert.match(md, /the wallet's delegate code called directly by another account \(not through an EntryPoint\)/);
  const j = JSON.parse(toJson(r));
  assert.equal(j.wallets[0].userOperations.found, 1);
  assert.equal(j.wallets[0].transactions[1].userOpHash, H(1));
});

test('a user operation is audited from its own logs: an IGNIX trade and a transistor transfer are flagged; a kernel settle is not', async () => {
  const { chain, cfg } = world();
  cfg.kernels = [KERNEL];
  chain.view(KERNEL, 'vault()', '0x' + addressWord(VAULT));
  chain.view(KERNEL, 'token()', '0x' + addressWord(CVREF));
  chain.code.set(CVREF, '0x60');
  chain.ignixTokens.set(CVREF, { creator: STRANGER, vault: VAULT });
  // a settle through the wallet: the kernel's own curve buy is expected
  chain.add(2_000, { from: BUNDLER, to: EP7, input: '0x765e827f', logs: [beforeExec, { address: KERNEL, topics: ['0x' + 'ab'.repeat(32)], data: '0x' }, trade(CVREF, KERNEL), transfer(CVREF, MANAGER, KERNEL), uoe(A, H(3), true, 1n)] });
  // a transistor transfer in the validation phase, then a trade by the wallet in its execution
  chain.add(2_600, { from: BUNDLER, to: EP7, input: '0x765e827f', logs: [single(A, STRANGER), beforeExec, trade(TOKEN_X, A), transfer(TOKEN_X, MANAGER, A), uoe(A, H(4), true, 2n)] });
  // a failed operation
  chain.add(3_000, { from: BUNDLER, to: EP7, input: '0x765e827f', logs: [beforeExec, uoe(A, H(5), false, 3n)] });
  // a WOKB deposit through the wallet
  const WOKB = '0xe538905cf8410324e03a5a23c1c177a474d59b2b';
  chain.add(3_100, { from: BUNDLER, to: EP7, input: '0x765e827f', logs: [beforeExec, { address: WOKB, topics: ['0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c', topicAddress(A)], data: '0x' + word(1) }, uoe(A, H(6), true, 4n)] });
  const { r } = await audit(chain, cfg);
  const ops = rows(r).filter((x) => x.kind === 'userOperation');
  assert.deepEqual(ops.map((x) => x.userOpHash), [H(1), H(3), H(4), H(5), H(6)]);
  assert.deepEqual(ops[1].flags, [], 'a kernel buying on the curve inside a settle');
  assert.match(ops[1].classification, /a kernel bought on the curve \(expected in a settle\); events of Covenant kernel #1/);
  assert.deepEqual(new Set(ops[2].flags), new Set(['ignix-activity', 'transistor-transfer']));
  assert.match(ops[2].classification, /THE WALLET TRADED IGNIX token/);
  assert.match(ops[2].classification, /COVENANT TRANSISTORS MOVED to or from the wallet/);
  assert.equal(ops[3].reverted, true);
  assert.match(ops[3].classification, /FAILED \(its execution had no effect\)/);
  assert.deepEqual(ops[4].flags, ['dex-call']);
  assert.equal(r.exitCode, 1);
  const lines = verdictLines(r).join('\n');
  assert.match(lines, /^FLAG {11}1 {2}IGNIX trades or token movements .*: 0x[0-9a-f]{4}\.\.\.[0-9a-f]{4} user op 0x00000000\.\.\.$/m);
  assert.match(lines, /^COVERED {8}5 {2}user operation\(s\)/m);
});

test('the logs of a bundle are cut at the EntryPoint delimiters', () => {
  const receipt: Receipt = { status: '0x1', gasUsed: '0x1', contractAddress: null, logs: [single(A, STRANGER), beforeExec, transfer(TOKEN_X, A, STRANGER), uoe(OTHER_SENDER, H(7)), trade(TOKEN_X, A), uoe(A, H(8))] };
  const scan = (l: (typeof receipt.logs)[number], i: number) => ({ ...l, blockNumber: 1, transactionHash: '0x01', logIndex: i });
  const op = decodeUserOpEvent(scan(receipt.logs[5], 5), 'EntryPoint v0.7');
  const seg = segmentOf(receipt, op);
  assert.equal(seg.delimited, true);
  assert.deepEqual(seg.execution, [trade(TOKEN_X, A)], 'only the logs after the previous operation');
  assert.deepEqual(seg.validation, [single(A, STRANGER)]);
  const lone: Receipt = { ...receipt, logs: [transfer(TOKEN_X, A, STRANGER), uoe(A, H(9))] };
  const s2 = segmentOf(lone, decodeUserOpEvent(scan(lone.logs[1], 1), 'EntryPoint v0.7'));
  assert.equal(s2.delimited, false);
  assert.equal(s2.execution.length, 1, 'without a delimiter every earlier log is checked as the operation\'s own');
  assert.throws(() => decodeUserOpEvent(scan(trade(TOKEN_X, A), 0), 'x'), /not a UserOperationEvent/);
});

test('the scan covers the first activity to the audit block in 100-block chunks, and a rerun asks only for new blocks', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'audit-team-userops-'));
  try {
    const { chain, cfg } = world();
    const cachePath = join(dir, 'chain-196.json');
    const first = await audit(chain, cfg, cachePath);
    const logsQueries = (): number => chain.seen.filter((m) => m === 'eth_getLogs').length;
    assert.equal(logsQueries(), Math.ceil((HEAD - 1_000 + 1) / 100), 'blocks 1000..5000, EntryPoint v0.7 only (v0.6 has no code here)');
    assert.equal(first.r.wallets[0].userOps?.found, 1);
    const before = logsQueries();
    const second = await audit(chain, cfg, cachePath);
    assert.equal(logsQueries() - before, 1, 'only the blocks above the remembered safe head');
    assert.deepEqual(rows(second.r), rows(first.r));
    // a new operation later on is found
    chain.head = HEAD + 300;
    chain.add(HEAD + 250, { from: BUNDLER, to: EP7, input: '0x765e827f', logs: [beforeExec, uoe(A, H(10), true, 1n)] });
    const third = await audit(chain, cfg, cachePath);
    assert.equal(third.r.wallets[0].userOps?.found, 2);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('code that is not a known smart wallet is still a finding, and an unscanned wallet is never COMPLETE for its user operations', async () => {
  // a delegation to an implementation that is not in the list
  const { chain, cfg } = world();
  const unknownImpl = known({ ...cfg, smartWallets: {} });
  const r1 = (await audit(chain, unknownImpl)).r;
  assert.equal(count(r1, 'delegation'), 2, 'the code and the authorisation');
  assert.equal(r1.exitCode, 1);
  assert.match(rows(r1)[0].classification, /an UNKNOWN implementation/);
  // a contract
  const c = new FakeChain(HEAD);
  c.add(10, { from: A, to: STRANGER, value: 1n });
  c.code.set(A, '0x6080604052');
  c.code.set(EP7, '0x60');
  const r2 = (await audit(c, cfg)).r;
  assert.equal(count(r2, 'delegation'), 1);
  assert.match(verdictLines(r2).join('\n'), /\(it is a contract\)/);
  // no EntryPoint configured: the user operations are NOT covered and the audit is incomplete
  const { chain: c3, cfg: cfg3 } = world();
  const r3 = (await audit(c3, known({ ...cfg3, entryPoints: [] }))).r;
  assert.equal(r3.exitCode, 2);
  assert.match(verdictLines(r3).join('\n'), /^NOT COVERED {7}user operations of .*: no EntryPoint is configured in addresses\.json$/m);
  assert.match(verdictLines(r3).join('\n'), /VERDICT: INCOMPLETE/);
});
