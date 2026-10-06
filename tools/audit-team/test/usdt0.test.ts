// Kernel v2 (USD₮0 quote): v2 kernels are kernels to the audit, and USD₮0 sent from a team wallet to a kernel or its
// vault is a FLAG (kernel-usdt0), whether the wallet sent it itself (a transfer, any contract call that moves it, a
// user operation) or another account executed the wallet's EIP-3009 authorisation (an x402 payment) or allowance.
// Offline: a chain made of tables (fake-chain.ts).
//
// The wallets here are synthetic table addresses, not Covenant's wallets. No real wallet pays anything, on any chain:
// the audit's detector is fed table rows. (Covenant's rule: no team wallet may ever pay revenue into a kernel that
// buys the team's token; self-payment is forbidden.)

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { addressWord, word } from '../../launch-check/hex.ts';
import { parseDeployment } from '../../launch-check/deployment.ts';
import { runAudit, type AuditResult, type Row } from '../audit.ts';
import { Chain, type Receipt } from '../chain.ts';
import { classify, usdt0CallParties, type Context } from '../classify.ts';
import { TOPIC, selectorOf, withDeployment, type Known, type Wallet } from '../known.ts';
import { renderMarkdown, verdictLines } from '../report.ts';
import { UO_TOPIC, classifyUserOp, decodeUserOpEvent } from '../userops.ts';
import { FakeChain, known, topicAddress } from './fake-chain.ts';

const HEAD = 5_000;
const USDT0 = '0x779ded0c9e1022225f8e0630b35a9b54be713736';
const TEAM = '0x00000000000000000000000000000000000c0de1'; // a synthetic "team wallet" of the table chain
const FACILITATOR = '0x00000000000000000000000000000000000fac17'; // an unrelated account that executes authorisations
const SHOP = '0x00000000000000000000000000000000000005b0'; // an unrelated recipient (another x402 seller)
const FACTORY_V2 = '0x00000000000000000000000000000000c0fe0015';
const KERNEL_V2 = '0x00000000000000000000000000000000c0fe0011';
const VAULT_V2 = '0x00000000000000000000000000000000c0fe00b2';
const TOKEN_V2 = '0x00000000000000000000000000000000c0fe00c2';
const FACTORY_BLOCK = 3_000;

const wallets: Wallet[] = [{ address: TEAM, role: 'test wallet (synthetic)' }];
const transferLog = (from: string, to: string, amount: bigint) => ({ address: USDT0, topics: [TOPIC.transfer, topicAddress(from), topicAddress(to)], data: '0x' + word(amount) });
const call = (signature: string, ...words: string[]): string => selectorOf(signature) + words.join('');
const twa = (from: string, to: string, amount: bigint): string =>
  call('transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)', addressWord(from), addressWord(to), word(amount), word(0), word(9_999_999_999), word(7), word(27), word(1), word(2));

/** A chain on which a KernelFactoryV2 exists from FACTORY_BLOCK, with one v2 kernel (bound, with its vault). */
function world(): { chain: FakeChain; cfg: Known } {
  const chain = new FakeChain(HEAD);
  chain.code.set(USDT0, '0x60');
  chain.view(FACTORY_V2, 'isKernel(address)', (data) => '0x' + word(data.slice(-40) === KERNEL_V2.slice(2) ? 1 : 0));
  chain.codeFrom.set(FACTORY_V2, FACTORY_BLOCK);
  chain.view(KERNEL_V2, 'vault()', '0x' + addressWord(VAULT_V2));
  chain.view(KERNEL_V2, 'token()', '0x' + addressWord(TOKEN_V2));
  chain.codeFrom.set(KERNEL_V2, FACTORY_BLOCK + 10);
  chain.ignixTokens.set(TOKEN_V2, { creator: '0x00000000000000000000000000000000000000c1', vault: VAULT_V2 });
  chain.code.set(VAULT_V2, '0x60');
  chain.code.set(SHOP, '0x');
  return { chain, cfg: known({ usdt0: USDT0, kernelFactoryV2: FACTORY_V2 }) };
}

async function audit(chain: FakeChain, cfg: Known, ws: readonly Wallet[] = wallets): Promise<AuditResult> {
  const c = new Chain({ rpc: chain.rpc(), minIntervalMs: 0, cachePath: null });
  await c.open();
  return runAudit(c, cfg, ws);
}
const rowsOf = (r: AuditResult): Row[] => r.wallets.flatMap((w) => w.rows);
const count = (r: AuditResult, id: string): number => r.rules.find((x) => x.id === id)?.count ?? -1;

test('the first block with code is found by the search over eth_getCode, for any creation block', async () => {
  for (const at of [1, 2, 9, 10, 11, 99, 1_234, 2_999, 3_000, 4_999, 5_000]) {
    const chain = new FakeChain(HEAD);
    chain.code.set(FACTORY_V2, '0x60');
    chain.codeFrom.set(FACTORY_V2, at);
    const c = new Chain({ rpc: chain.rpc(), minIntervalMs: 0, cachePath: null });
    await c.open();
    assert.equal(await c.firstCodeBlock(FACTORY_V2), at, `created at ${at}`);
  }
  const chain = new FakeChain(HEAD);
  const c = new Chain({ rpc: chain.rpc(), minIntervalMs: 0, cachePath: null });
  await c.open();
  assert.equal(await c.firstCodeBlock(FACTORY_V2), null, 'no code at the audit block');
});

test('a clean wallet: the USD₮0 scan runs from the KernelFactoryV2 creation and finds nothing; CLEAN', async () => {
  const { chain, cfg } = world();
  const r = await audit(chain, cfg);
  assert.equal(r.exitCode, 0, r.incomplete.join('; '));
  assert.deepEqual(r.usdt0Scan, { scanned: true, from: FACTORY_BLOCK, to: HEAD, found: 0 });
  assert.equal(count(r, 'kernel-usdt0'), 0);
  const lines = verdictLines(r);
  assert.ok(lines.some((l) => /^PASS\s+0\s+USD₮0 sent from a team wallet to a kernel or to its vault/.test(l)));
  assert.ok(lines.some((l) => /^COVERED\s+0\s+USD₮0 transfer\(s\) out of the team wallets in transactions they did not send/.test(l) && l.includes(`blocks ${FACTORY_BLOCK}..${HEAD}`)));
});

test('the wallet sends USD₮0 to a v2 kernel (one the KernelFactoryV2 created): FLAG kernel-usdt0', async () => {
  const { chain, cfg } = world();
  chain.add(4_000, { from: TEAM, to: USDT0, input: call('transfer(address,uint256)', addressWord(KERNEL_V2), word(500_000)), logs: [transferLog(TEAM, KERNEL_V2, 500_000n)] });
  const r = await audit(chain, cfg);
  assert.equal(r.exitCode, 1);
  assert.equal(count(r, 'kernel-usdt0'), 1);
  const [row] = rowsOf(r);
  assert.deepEqual(row.flags, ['kernel-usdt0']);
  assert.equal(row.targetLabel, 'USD₮0', 'USD₮0 is a known target, not an unknown one');
  assert.match(row.classification, /USD₮0 SENT FROM THE WALLET TO A KERNEL \(0\.5 USD₮0 to Covenant kernel \(per the KernelFactoryV2\)\)/);
  assert.equal(r.usdt0Scan?.found, 0, 'the wallet\'s own transaction is not listed twice');
  assert.match(verdictLines(r).join('\n'), /^FLAG\s+1\s+USD₮0 sent from a team wallet to a kernel/m);
});

test('the call is flagged even when it reverted, and USD₮0 to the kernel\'s vault is flagged too', async () => {
  const { chain, cfg } = world();
  chain.add(4_000, { from: TEAM, to: USDT0, input: call('transfer(address,uint256)', addressWord(KERNEL_V2), word(1)), reverted: true });
  chain.add(4_001, { from: TEAM, to: USDT0, input: call('transfer(address,uint256)', addressWord(VAULT_V2), word(2_000_000)), logs: [transferLog(TEAM, VAULT_V2, 2_000_000n)] });
  const r = await audit(chain, cfg);
  assert.equal(count(r, 'kernel-usdt0'), 2);
  assert.equal(r.rules.find((x) => x.id === 'kernel-usdt0')?.reverted, 1);
  const [a, b] = rowsOf(r);
  assert.match(a.classification, /THE WALLET CALLED A USD₮0 TRANSFER INTO A KERNEL .*\[REVERTED: it had no effect\]/);
  assert.match(b.classification, /2 USD₮0 to vault of kernel 0x0000\.\.\.0011/);
});

test('USD₮0 moved into the kernel through another contract (an aggregator, say) is seen in the receipt', async () => {
  const { chain, cfg } = world();
  const ROUTERISH = '0x00000000000000000000000000000000000a660e';
  chain.code.set(ROUTERISH, '0x60');
  chain.add(4_000, { from: TEAM, to: ROUTERISH, input: '0x12345678', logs: [transferLog(TEAM, KERNEL_V2, 3_000_000n)] });
  const r = await audit(chain, cfg);
  assert.equal(count(r, 'kernel-usdt0'), 1);
  assert.equal(rowsOf(r)[0].unknownTarget, true, 'the aggregator itself is still an unknown target (a warning)');
});

test('an x402 payment to the kernel (the wallet\'s EIP-3009 authorisation, executed by a facilitator): listed and FLAGGED', async () => {
  const { chain, cfg } = world();
  // the team wallet never sends a transaction; the facilitator submits its authorisation
  chain.add(4_200, { from: FACILITATOR, to: USDT0, input: twa(TEAM, KERNEL_V2, 500_000n), logs: [transferLog(TEAM, KERNEL_V2, 500_000n)] });
  const r = await audit(chain, cfg);
  assert.equal(r.wallets[0].transactionCount, 0, 'no nonce of the wallet was used');
  assert.equal(r.exitCode, 1);
  assert.equal(count(r, 'kernel-usdt0'), 1);
  const [row] = rowsOf(r);
  assert.equal(row.kind, 'usdt0Transfer');
  assert.equal(row.block, 4_200);
  assert.deepEqual(row.flags, ['kernel-usdt0']);
  assert.match(row.classification, /^0\.5 USD₮0 moved from the wallet by a transaction it did not send \(an EIP-3009 authorisation, such as an x402 payment, or an allowance\) INTO Covenant kernel/);
  assert.equal(r.usdt0Scan?.found, 1);
  const md = renderMarkdown(r);
  assert.match(md, /\| 4200 \| .* \| \(none\) \| .* \| \(USD₮0 transfer, sent by another account\) \| 0 \(USD₮0 above\) \|/);
  assert.match(md, /Tokens moved out of a wallet by other accounts\. The one exception is USD₮0/);
});

test('an x402 payment to someone else is listed and not flagged; a payment before the KernelFactoryV2 existed is not scanned', async () => {
  const { chain, cfg } = world();
  chain.add(2_000, { from: FACILITATOR, to: USDT0, input: twa(TEAM, SHOP, 100_000n), logs: [transferLog(TEAM, SHOP, 100_000n)] });
  chain.add(4_300, { from: FACILITATOR, to: USDT0, input: twa(TEAM, SHOP, 250_000n), logs: [transferLog(TEAM, SHOP, 250_000n)] });
  // a transfer TO the team wallet (it was paid) is not a payment by it
  chain.add(4_301, { from: FACILITATOR, to: USDT0, input: twa(SHOP, TEAM, 9n), logs: [transferLog(SHOP, TEAM, 9n)] });
  const r = await audit(chain, cfg);
  assert.equal(r.exitCode, 0, r.incomplete.join('; '));
  const rows = rowsOf(r);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].block, 4_300);
  assert.deepEqual(rows[0].flags, []);
  assert.equal(rows[0].targetLabel, 'a USD₮0 recipient that is not a kernel');
  assert.match(rows[0].classification, /^0\.25 USD₮0 moved from the wallet by a transaction it did not send/);
});

test('a smart wallet\'s user operation that moves USD₮0 into the kernel is FLAGGED', () => {
  const EP = '0x0000000071727de22e5e9d8baf0edac6f37da032';
  const hash = '0x' + 'ab'.repeat(32);
  const uoe = { address: EP, topics: [UO_TOPIC.userOperationEvent, hash, topicAddress(TEAM), topicAddress('0x0000000000000000000000000000000000000000')], data: '0x' + word(1) + word(1) + word(0) + word(0) };
  const receipt: Receipt = { status: '0x1', gasUsed: '0x1', contractAddress: null, logs: [{ address: EP, topics: [UO_TOPIC.beforeExecution], data: '0x' }, transferLog(TEAM, KERNEL_V2, 700_000n), uoe] };
  const op = decodeUserOpEvent({ ...uoe, blockNumber: 4_000, transactionHash: '0x' + '01'.repeat(32), logIndex: 2 }, 'EntryPoint v0.7');
  const ctx: Context = { targets: new Map([[KERNEL_V2, { kind: 'kernel', label: 'Covenant kernel v2' }]]), ignixTokens: new Set(), manager: '0x96b51c57e5346d0c0198899243cf851d1e23c309', transistors: null, kernelsKnown: true, usdt0: USDT0 };
  const c = classifyUserOp(op, receipt, ctx, TEAM, null);
  assert.deepEqual(c.flags, ['kernel-usdt0']);
  assert.match(c.classification, /USD₮0 SENT FROM THE WALLET TO A KERNEL \(0\.7 USD₮0 to Covenant kernel v2\)/);
  // the same receipt without USD₮0 configured: the rule is not applied
  assert.deepEqual(classifyUserOp(op, receipt, { ...ctx, usdt0: null }, TEAM, null).flags, []);
});

test('USD₮0 transfer calls: payer and recipient are read from the calldata', () => {
  assert.deepEqual(usdt0CallParties(call('transfer(address,uint256)', addressWord(KERNEL_V2), word(1))), { from: null, to: KERNEL_V2 });
  assert.deepEqual(usdt0CallParties(call('transferFrom(address,address,uint256)', addressWord(TEAM), addressWord(KERNEL_V2), word(1))), { from: TEAM, to: KERNEL_V2 });
  assert.deepEqual(usdt0CallParties(twa(TEAM, KERNEL_V2, 1n)), { from: TEAM, to: KERNEL_V2 });
  assert.equal(usdt0CallParties(call('approve(address,uint256)', addressWord(KERNEL_V2), word(1))), null);
  assert.equal(usdt0CallParties('0xa9059cbb'), null, 'too short');
  // a kernel v1 is a kernel too: USD₮0 sent to it stays there for ever, and is flagged the same way
  const ctx: Context = { targets: new Map([[KERNEL_V2, { kind: 'kernel', label: 'kernel' }], [USDT0, { kind: 'other', label: 'USD₮0' }]]), ignixTokens: new Set(), manager: '0x96b51c57e5346d0c0198899243cf851d1e23c309', transistors: null, kernelsKnown: true, usdt0: USDT0 };
  const tx = { hash: '0x' + '02'.repeat(32), from: TEAM, to: USDT0, nonce: 0, value: '0x0', input: call('transfer(address,uint256)', addressWord(KERNEL_V2), word(1)), blockNumber: 1, timestamp: 1, transactionIndex: 0, type: '0x2' };
  assert.deepEqual(classify(tx as never, { status: '0x1', gasUsed: '0x1', contractAddress: null, logs: [transferLog(TEAM, KERNEL_V2, 1n)] }, ctx).flags, ['kernel-usdt0']);
});

test('the deployment file brings the v2 kernel and the KernelFactoryV2; without usdt0 the audit is incomplete', async () => {
  const d = parseDeployment(
    JSON.stringify({ chainId: 196, deployer: TEAM, coreV2: { kernelFactory: FACTORY_V2, lens: '0x00000000000000000000000000000000c0fe0019', quote: USDT0, quoteShift: 33 }, flagshipV2: { kernel: KERNEL_V2, chipId: 5 } }),
    'test',
  );
  const k = withDeployment(known({ usdt0: USDT0 }), d);
  assert.equal(k.kernelFactoryV2, FACTORY_V2);
  assert.equal(k.lensV2, '0x00000000000000000000000000000000c0fe0019');
  assert.deepEqual(k.kernels, [KERNEL_V2]);
  assert.throws(() => withDeployment(known({ kernelFactoryV2: '0x00000000000000000000000000000000c0fe0099' }), d), /covenant\.kernelFactoryV2 is 0x0+c0fe0099, the deployment file test says/);

  const { chain } = world();
  const r = await audit(chain, known({ kernelFactoryV2: FACTORY_V2 }));
  assert.equal(r.exitCode, 2);
  assert.match(r.incomplete.join('\n'), /a KernelFactoryV2 is configured but usdt0 is not/);
  assert.match(verdictLines(r).join('\n'), /^NOT COVERED {7}USD₮0 moved out of the team wallets by other accounts: usdt0 is not configured/m);
});
