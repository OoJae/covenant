// Scheduling logic against a scripted chain. No network, no key.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { CALLDATA, settleAndRefundCalldata } from '../src/abi.ts';
import { ConfigError, RpcUnavailableError } from '../src/errors.ts';
import { Keeper } from '../src/keeper.ts';
import { makeRefundDecoder } from '../src/abi.ts';
import { DEFAULT_REFUNDED_EVENT } from '../src/config.ts';
import { RpcPool } from '../src/pool.ts';
import {
  DEFAULT_OPTIONS,
  FakeChain,
  KERNEL_A,
  KERNEL_B,
  TANK,
  WALLET,
  World,
  fakeSigner,
  harness,
  manualClock,
  memoryLogger,
} from './helpers/fake-chain.ts';

const kinds = (outcomes: Array<{ kind: string }>): string[] => outcomes.map((o) => o.kind);

test('no new epoch: nothing is simulated and nothing is sent', async () => {
  const h = harness();
  h.world.kernel(KERNEL_A).lastEpoch = 5; // equal to epochNow
  const out = await h.keeper.tick();
  assert.deepEqual(kinds(out), ['idle']);
  assert.equal(h.world.sent.length, 0);
  assert.equal(h.chains[0]?.calls['estimateGas'] ?? 0, 0);
  assert.equal(h.chains[0]?.calls['simulate'] ?? 0, 0);
  assert.equal(h.signer?.signed, 0);
});

test('a new epoch: one settle through the tank, with the specified gas limit and capped EIP-1559 fees', async () => {
  const h = harness();
  const out = await h.keeper.tick();
  assert.deepEqual(kinds(out), ['settled']);
  assert.equal(h.world.sent.length, 1);

  const tx = h.world.sent[0]!;
  assert.equal(tx.to.toLowerCase(), TANK.toLowerCase());
  assert.equal(tx.data, settleAndRefundCalldata(KERNEL_A));
  assert.equal(tx.value, 0n);
  assert.equal(tx.chainId, 196);
  assert.equal(tx.type, 'eip1559');
  assert.equal(tx.nonce, 7);
  // estimate 5,000,000 * 1.25 = 6,250,000; minSettleGas 10,000,000 * 1.1 = 11,000,000; the larger wins.
  assert.equal(tx.gas, 11_000_000n);
  // base fee 0.02 gwei, tip 0.001 gwei: maxFee = min(cap 0.1 gwei, 2 * 0.02 + 0.001) = 0.041 gwei.
  assert.equal(tx.maxFeePerGas, 41_000_000n);
  assert.equal(tx.maxPriorityFeePerGas, 1_000_000n);

  // Estimated first, then simulated at the exact limit, then sent.
  assert.equal(h.chains[0]?.calls['estimateGas'], 1);
  assert.equal(h.chains[0]?.calls['simulate'], 1);

  const settled = h.log.find('settled');
  assert.equal(settled.length, 1);
  const f = settled[0]!.fields;
  assert.equal(f['kernel'], KERNEL_A);
  assert.equal(f['epoch'], 5);
  assert.equal(f['txHash'], tx.hash);
  assert.equal(f['gasUsed'], 4_200_000n);
  assert.equal(f['refundWei'], 123_000_000_000_000n);
  assert.equal(f['via'], 'tank');
  assert.equal(f['record'], 1);
  assert.equal(f['gasCostWei'], 4_200_000n * 21_000_000n);
  assert.equal(f['netCostWei'], 4_200_000n * 21_000_000n - 123_000_000_000_000n);
  assert.equal(h.world.kernel(KERNEL_A).lastEpoch, 5);
});

test('gas limit follows estimate * 1.25 when that exceeds minSettleGas * 1.1', async () => {
  const h = harness();
  h.world.estimate = 12_000_000n;
  await h.keeper.tick();
  assert.equal(h.world.sent[0]?.gas, 15_000_000n);
});

test('gas limit rounds up', async () => {
  const h = harness();
  h.world.estimate = 9_999_999n; // * 1.25 = 12,499,998.75
  h.world.kernel(KERNEL_A).minSettleGas = 1n;
  await h.keeper.tick();
  assert.equal(h.world.sent[0]?.gas, 12_499_999n);
});

test('the refund is absent from the line when no log matches the configured event', async () => {
  const h = harness();
  h.world.refundWei = null; // a tank that declares its event differently
  const out = await h.keeper.tick();
  assert.equal(out[0]?.kind, 'settled');
  assert.equal(h.log.find('settled')[0]?.fields['refundWei'], null);
  assert.equal(h.log.find('settled')[0]?.fields['netCostWei'], null);
  assert.equal(h.log.find('refund_event_not_found').length, 1);
});

test('an exhausted allowance still settles: the tank logs a refund of zero', async () => {
  const h = harness();
  h.world.tankRemainingWei = 50_000_000_000_000n; // less than one refund
  assert.deepEqual(kinds(await h.keeper.tick()), ['settled']);
  assert.equal(h.log.find('settled')[0]?.fields['refundWei'], 50_000_000_000_000n);

  h.world.kernel(KERNEL_A).epochNow = 6;
  assert.deepEqual(kinds(await h.keeper.tick()), ['settled']);
  const second = h.log.find('settled')[1]!.fields;
  assert.equal(second['refundWei'], 0n);
  assert.equal(second['netCostWei'], second['gasCostWei']);
  assert.equal(second['via'], 'tank');
  assert.equal(h.log.find('refund_event_not_found').length, 0, 'a zero refund is still a decoded event');
});

test('never more than one settle per kernel per epoch: a pending transaction is not repeated', async () => {
  const h = harness();
  h.world.autoMine = false;
  assert.deepEqual(kinds(await h.keeper.tick()), ['pending']);
  assert.equal(h.world.sent.length, 1);
  for (let i = 0; i < 5; i++) {
    assert.deepEqual(kinds(await h.keeper.tick()), ['already_sent']);
  }
  assert.equal(h.world.sent.length, 1);
  assert.equal(h.signer?.signed, 1);
});

test('never more than one settle per kernel per epoch: not even after the transaction vanished from the pool', async () => {
  const h = harness();
  h.world.autoMine = false;
  await h.keeper.tick();
  h.world.pool.clear(); // dropped by the node
  h.clock.advance(10 * 60_000); // long past the stuck threshold, still the same epoch
  assert.deepEqual(kinds(await h.keeper.tick()), ['already_sent']);
  assert.equal(h.world.sent.length, 1);
});

test('never more than one settle per kernel per epoch: an on-chain revert is reported, not retried', async () => {
  const h = harness();
  h.world.mineReverts = true;
  assert.deepEqual(kinds(await h.keeper.tick()), ['reverted']);
  assert.equal(h.log.find('settle_reverted').length, 1);
  h.world.mineReverts = false;
  assert.deepEqual(kinds(await h.keeper.tick()), ['already_sent']);
  assert.equal(h.world.sent.length, 1);
});

test('the next epoch gets its own settle, with the next nonce', async () => {
  const h = harness();
  await h.keeper.tick();
  assert.deepEqual(kinds(await h.keeper.tick()), ['idle']);
  h.world.kernel(KERNEL_A).epochNow = 6;
  assert.deepEqual(kinds(await h.keeper.tick()), ['settled']);
  assert.equal(h.world.sent.length, 2);
  assert.deepEqual(h.world.sent.map((t) => t.nonce), [7, 8]);
});

test('a failing simulation sends nothing; once it passes, exactly one settle goes out', async () => {
  const h = harness({ directFallback: false });
  h.world.kernel(KERNEL_A).settleRevert = 'evaluator failed';
  for (let i = 0; i < 3; i++) {
    const out = await h.keeper.tick();
    assert.deepEqual(kinds(out), ['simulation_failed']);
  }
  assert.equal(h.world.sent.length, 0);
  assert.equal(h.signer?.signed, 0);
  // The same failure in the same epoch is logged once, not on every poll.
  assert.equal(h.log.find('settle_simulation_failed').length, 1);

  h.world.kernel(KERNEL_A).settleRevert = null;
  assert.deepEqual(kinds(await h.keeper.tick()), ['settled']);
  assert.deepEqual(kinds(await h.keeper.tick()), ['idle']);
  assert.equal(h.world.sent.length, 1);
});

test('tank path reverts, direct path works: the direct settle is sent', async () => {
  const h = harness();
  h.world.tankRevert = 'caller barred';
  const out = await h.keeper.tick();
  assert.deepEqual(kinds(out), ['settled']);
  const tx = h.world.sent[0]!;
  assert.equal(tx.to.toLowerCase(), KERNEL_A.toLowerCase());
  assert.equal(tx.data, CALLDATA.settle);
  const line = h.log.find('settle_sent')[0]!.fields;
  assert.equal(line['via'], 'direct');
  assert.match(String(line['tankFailure']), /caller barred/);
  assert.equal(h.log.find('settled')[0]?.fields['refundWei'], null);
  assert.equal(h.log.find('refund_event_not_found').length, 0);
});

test('with DIRECT_FALLBACK off a reverting tank path sends nothing', async () => {
  const h = harness({ directFallback: false });
  h.world.tankRevert = 'caller barred';
  assert.deepEqual(kinds(await h.keeper.tick()), ['simulation_failed']);
  assert.equal(h.world.sent.length, 0);
});

test('both paths revert: nothing is sent and both reasons are reported', async () => {
  const h = harness();
  h.world.kernel(KERNEL_A).settleRevert = 'evaluator failed';
  const out = await h.keeper.tick();
  assert.equal(out[0]?.kind, 'simulation_failed');
  assert.match(String(h.log.find('settle_simulation_failed')[0]?.fields['reason']), /tank: evaluator failed \| direct: evaluator failed/);
  assert.equal(h.world.sent.length, 0);
});

test('no tank configured: settle() is called on the kernel', async () => {
  const h = harness({ tank: null });
  assert.deepEqual(kinds(await h.keeper.tick()), ['settled']);
  const tx = h.world.sent[0]!;
  assert.equal(tx.to.toLowerCase(), KERNEL_A.toLowerCase());
  assert.equal(tx.data, CALLDATA.settle);
});

test('dry run: simulates, reports what it would send, never signs or sends', async () => {
  const h = harness({ dryRun: true });
  const out = await h.keeper.tick();
  assert.deepEqual(kinds(out), ['dry_run']);
  assert.equal(h.world.sent.length, 0);
  assert.equal(h.signer?.signed, 0);
  assert.equal(h.chains[0]?.calls['sendRaw'] ?? 0, 0);
  assert.equal(h.chains[0]?.calls['simulate'], 1);

  const line = h.log.find('dry_run')[0]!.fields;
  assert.equal(line['wouldSend'], true);
  assert.equal(line['kernel'], KERNEL_A);
  assert.equal(line['epoch'], 5);
  assert.equal(line['via'], 'tank');
  assert.equal(String(line['to']).toLowerCase(), TANK.toLowerCase());
  assert.equal(line['data'], settleAndRefundCalldata(KERNEL_A));
  assert.equal(line['gasLimit'], 11_000_000n);
  assert.equal(line['maxFeePerGasWei'], 41_000_000n);
  assert.equal(line['nonce'], 7);

  // The same epoch is reported once, however often it is polled.
  await h.keeper.tick();
  await h.keeper.tick();
  assert.equal(h.log.find('dry_run').length, 1);
  h.world.kernel(KERNEL_A).epochNow = 6;
  await h.keeper.tick();
  assert.equal(h.log.find('dry_run').length, 2);
  assert.equal(h.world.sent.length, 0);
});

test('dry run works without any signer', async () => {
  const h = harness({ dryRun: true }, { signer: false });
  assert.deepEqual(kinds(await h.keeper.tick()), ['dry_run']);
  assert.equal(h.world.sent.length, 0);
});

test('live mode refuses to start without a signer', () => {
  const world = new World();
  const log = memoryLogger();
  const clock = manualClock();
  assert.throws(
    () =>
      new Keeper(DEFAULT_OPTIONS, {
        pool: new RpcPool([new FakeChain(world)], { log, sleep: clock.sleep }),
        signer: null,
        from: WALLET,
        log,
        now: clock.now,
        sleep: clock.sleep,
        decodeRefund: makeRefundDecoder(DEFAULT_REFUNDED_EVENT),
      }),
    ConfigError,
  );
});

test('base fee plus tip above MAX_FEE_GWEI: nothing is sent', async () => {
  const h = harness();
  h.world.baseFee = 100_000_000n; // 0.1 gwei base + 0.001 tip > 0.1 cap
  assert.deepEqual(kinds(await h.keeper.tick()), ['fee_above_cap']);
  assert.equal(h.world.sent.length, 0);
  assert.equal(h.chains[0]?.calls['estimateGas'] ?? 0, 0);
  h.world.baseFee = 20_000_000n;
  assert.deepEqual(kinds(await h.keeper.tick()), ['settled']);
});

test('maxFeePerGas never exceeds MAX_FEE_GWEI', async () => {
  const h = harness();
  h.world.baseFee = 60_000_000n; // 2 * 0.06 + 0.001 = 0.121 gwei would exceed the 0.1 gwei cap
  await h.keeper.tick();
  assert.equal(h.world.sent[0]?.maxFeePerGas, 100_000_000n);
  assert.equal(h.world.sent[0]?.maxPriorityFeePerGas, 1_000_000n);
});

test('a gas limit above MAX_GAS_LIMIT is not sent', async () => {
  const h = harness({ maxGasLimit: 10_000_000n });
  assert.deepEqual(kinds(await h.keeper.tick()), ['gas_above_cap']);
  assert.equal(h.world.sent.length, 0);
});

test('a wallet that cannot pay for the gas limit sends nothing', async () => {
  const h = harness();
  h.world.balances.set(WALLET.toLowerCase(), 1_000n);
  assert.deepEqual(kinds(await h.keeper.tick()), ['insufficient_balance']);
  assert.equal(h.world.sent.length, 0);
  assert.equal(h.log.find('insufficient_balance').length, 1);
});

test('an RPC error switches endpoint and the settle still goes out', async () => {
  const h = harness({}, { rpcs: 2 });
  h.chains[0]!.failNext('*', 1000);
  const out = await h.keeper.tick();
  assert.deepEqual(kinds(out), ['settled']);
  assert.equal(h.world.sent.length, 1);
  const err = h.log.find('rpc_error')[0]!.fields;
  assert.equal(err['rpc'], 'fake-a');
  assert.equal(err['next'], 'fake-b');
  assert.ok((h.chains[1]!.calls['sendRaw'] ?? 0) >= 1);
});

test('every RPC down: the pass backs off, reports rpc_unavailable and sends nothing', async () => {
  const h = harness({ kernels: [KERNEL_A, KERNEL_B] }, { rpcs: 2 });
  h.world.addKernel(KERNEL_B, { epochNow: 3, lastEpoch: 2 });
  h.chains[0]!.failNext('*', 1000);
  h.chains[1]!.failNext('*', 1000);
  const out = await h.keeper.tick();
  // The first kernel exhausts the retries; the second is not made to wait through them again.
  assert.deepEqual(kinds(out), ['rpc_unavailable', 'rpc_unavailable']);
  assert.equal(h.world.sent.length, 0);
  // Three rounds over two endpoints, with exponential backoff between rounds.
  assert.deepEqual(h.clock.slept, [1000, 2000]);
  assert.equal(h.log.find('rpc_backoff').length, 2);
  assert.equal(h.chains[0]!.calls['epochs'], 3);
  assert.equal(h.chains[1]!.calls['epochs'], 3);
});

test('a broadcast whose answer was lost is repeated with the same bytes: still one transaction', async () => {
  const h = harness({}, { rpcs: 2 });
  h.chains[0]!.acceptThenFail = 1;
  const out = await h.keeper.tick();
  assert.deepEqual(kinds(out), ['settled']);
  assert.equal(h.world.sent.length, 1);
  assert.equal(h.signer?.signed, 1);
  assert.equal(h.chains[0]!.calls['sendRaw'], 1);
  assert.equal(h.chains[1]!.calls['sendRaw'], 1);
});

test('"nonce too low" on a retried broadcast of bytes that were already mined is a success, not a failure', async () => {
  const h = harness({}, { rpcs: 2 });
  h.world.minedSaysNonceTooLow = true;
  h.chains[0]!.acceptThenFail = 1; // the first endpoint takes and mines it, then the answer is lost
  const out = await h.keeper.tick();
  assert.deepEqual(kinds(out), ['settled']);
  assert.equal(h.world.sent.length, 1);
  assert.equal(h.log.find('settle_nonce_too_low').length, 1);
  assert.equal(h.log.find('settled').length, 1);
  assert.equal(h.keeper.inflightHash, null);
});

test('"nonce too low" because another instance used the nonce: nothing is mined by us, nothing is left pending', async () => {
  const h = harness();
  // Between this keeper reading the nonce and broadcasting, another instance of the same wallet settles.
  h.world.beforeSend = () => {
    h.world.beforeSend = null;
    h.world.nonceLatest += 1;
    h.world.kernel(KERNEL_A).lastEpoch = 5;
  };
  const out = await h.keeper.tick();
  assert.deepEqual(out, [{ kind: 'send_failed', kernel: KERNEL_A, epoch: 5, reason: 'nonce_too_low' }]);
  assert.equal(h.world.sent.length, 0, 'the node never accepted our transaction');
  assert.equal(h.keeper.inflightHash, null);
  // It looked for its own receipt for a few seconds only, not for the whole receipt timeout.
  assert.ok(h.clock.slept.reduce((a, b) => a + b, 0) <= 5000);
  // The epoch is settled (by the other instance): idle from here on.
  assert.deepEqual(kinds(await h.keeper.tick()), ['idle']);
  assert.equal(h.signer?.signed, 1);
});

test('a kernel whose views revert is reported as not ready and nothing is sent', async () => {
  const h = harness();
  h.world.kernel(KERNEL_A).viewRevert = 'not bound';
  assert.deepEqual(kinds(await h.keeper.tick()), ['not_ready']);
  await h.keeper.tick();
  assert.equal(h.log.find('kernel_not_ready').length, 1);
  assert.equal(h.world.sent.length, 0);
});

test('two kernels are settled one after the other with consecutive nonces', async () => {
  const h = harness({ kernels: [KERNEL_A, KERNEL_B] });
  h.world.addKernel(KERNEL_B, { epochNow: 9, lastEpoch: 8, chipId: 43n });
  const out = await h.keeper.tick();
  assert.deepEqual(kinds(out), ['settled', 'settled']);
  assert.deepEqual(h.world.sent.map((t) => t.nonce), [7, 8]);
  assert.equal(h.world.sent[0]?.data, settleAndRefundCalldata(KERNEL_A));
  assert.equal(h.world.sent[1]?.data, settleAndRefundCalldata(KERNEL_B));
  const lines = h.log.find('settled').map((l) => [l.fields['kernel'], l.fields['epoch']]);
  assert.deepEqual(lines, [[KERNEL_A, 5], [KERNEL_B, 9]]);
});

test('one kernel failing does not stop the other', async () => {
  const h = harness({ kernels: [KERNEL_A, KERNEL_B] });
  h.world.addKernel(KERNEL_B, { epochNow: 9, lastEpoch: 8 });
  h.world.kernel(KERNEL_A).settleRevert = 'evaluator failed';
  assert.deepEqual(kinds(await h.keeper.tick()), ['simulation_failed', 'settled']);
  assert.equal(h.world.sent.length, 1);
  assert.equal(h.world.sent[0]?.data, settleAndRefundCalldata(KERNEL_B));
});

test('MIN_EPOCH_LAG=2 (backup keeper) steps in only after a whole epoch was missed', async () => {
  const h = harness({ minEpochLag: 2 });
  assert.deepEqual(kinds(await h.keeper.tick()), ['idle']); // lag 1: the primary is expected to act
  assert.equal(h.world.sent.length, 0);
  h.world.kernel(KERNEL_A).epochNow = 6; // lag 2
  assert.deepEqual(kinds(await h.keeper.tick()), ['settled']);
  assert.equal(h.world.sent.length, 1);
});

test('while its own transaction is pending the wallet sends nothing else', async () => {
  const h = harness({ kernels: [KERNEL_A, KERNEL_B] });
  h.world.addKernel(KERNEL_B, { epochNow: 9, lastEpoch: 8 });
  h.world.autoMine = false;
  const out = await h.keeper.tick();
  assert.deepEqual(kinds(out), ['pending', 'waiting']);
  assert.equal(h.world.sent.length, 1);

  // Once it is mined, the second kernel is served.
  h.world.mine(h.world.sent[0]!.hash);
  h.world.autoMine = true;
  const next = await h.keeper.tick();
  assert.deepEqual(kinds(next), ['idle', 'settled']);
  assert.equal(h.world.sent.length, 2);
  assert.deepEqual(h.world.sent.map((t) => t.nonce), [7, 8]);
  // The first transaction's line is written when its receipt is finally seen.
  assert.equal(h.log.find('settled').length, 2);
});

test('a stuck transaction is replaced in a later epoch at the same nonce with higher fees', async () => {
  const h = harness();
  h.world.autoMine = false;
  assert.deepEqual(kinds(await h.keeper.tick()), ['pending']);
  const first = h.world.sent[0]!;

  // Next epoch, but the transaction is not old enough to be called stuck: wait.
  h.world.kernel(KERNEL_A).epochNow = 6;
  assert.deepEqual(kinds(await h.keeper.tick()), ['waiting']);
  assert.equal(h.world.sent.length, 1);

  h.clock.advance(181_000);
  h.world.autoMine = true;
  assert.deepEqual(kinds(await h.keeper.tick()), ['settled']);
  assert.equal(h.world.sent.length, 2);
  const second = h.world.sent[1]!;
  assert.equal(second.nonce, first.nonce);
  assert.ok(second.maxFeePerGas * 1000n >= first.maxFeePerGas * 1125n, 'maxFeePerGas bumped by at least 12.5%');
  assert.ok(second.maxPriorityFeePerGas * 1000n >= first.maxPriorityFeePerGas * 1125n, 'tip bumped by at least 12.5%');
  assert.ok(second.maxFeePerGas <= 100_000_000n);
  assert.equal(h.log.find('settle_sent')[1]?.fields['replaces'], first.hash);
  // Only one of the two can exist on chain.
  assert.equal(h.world.receipts.size, 1);
});

test('a pending transaction from another instance of the same wallet: wait, do not pile on', async () => {
  const h = harness();
  h.world.foreignPending = 1;
  assert.deepEqual(kinds(await h.keeper.tick()), ['waiting']);
  assert.equal(h.world.sent.length, 0);
  assert.equal(h.log.find('waiting_for_pending_tx')[0]?.fields['reason'], 'foreign_tx_pending');

  // The other instance's settle landed.
  h.world.foreignPending = 0;
  h.world.nonceLatest = 8;
  h.world.kernel(KERNEL_A).lastEpoch = 5;
  assert.deepEqual(kinds(await h.keeper.tick()), ['idle']);
  assert.equal(h.world.sent.length, 0);
});

test('a foreign transaction stuck past the threshold is replaced at the lowest unmined nonce', async () => {
  const h = harness();
  h.world.foreignPending = 1;
  assert.deepEqual(kinds(await h.keeper.tick()), ['waiting']);
  h.clock.advance(60_000);
  assert.deepEqual(kinds(await h.keeper.tick()), ['waiting']);
  assert.equal(h.world.sent.length, 0);

  h.clock.advance(121_000); // 181 s in total: stuck
  assert.deepEqual(kinds(await h.keeper.tick()), ['settled']);
  const tx = h.world.sent[0]!;
  assert.equal(tx.nonce, 7, 'the nonce the stuck transaction holds');
  assert.ok(tx.maxFeePerGas > 41_000_000n, 'priced above a normal settle');
  assert.ok(tx.maxPriorityFeePerGas > 1_000_000n, 'tip above a normal settle');
  assert.ok(tx.maxFeePerGas <= 100_000_000n);
  assert.equal(h.world.foreignPending, 0, 'the stuck transaction was evicted');

  // Back to normal pricing afterwards.
  h.world.kernel(KERNEL_A).epochNow = 6;
  assert.deepEqual(kinds(await h.keeper.tick()), ['settled']);
  assert.equal(h.world.sent[1]?.nonce, 8);
  assert.equal(h.world.sent[1]?.maxFeePerGas, 41_000_000n);
});

test('preflight: a wrong chain id, a kernel without code, a non-kernel and a tank without code are configuration errors', async () => {
  {
    const h = harness();
    h.chains[0]!.chainOverride = 1;
    await assert.rejects(h.keeper.preflight(), (e: unknown) => e instanceof ConfigError && /serves chain 1, expected 196/.test(e.message));
  }
  {
    const h = harness();
    h.world.code.delete(KERNEL_A.toLowerCase());
    await assert.rejects(h.keeper.preflight(), (e: unknown) => e instanceof ConfigError && /no contract code/.test(e.message));
  }
  {
    const h = harness();
    h.world.kernels.delete(KERNEL_A.toLowerCase()); // code is there, chipId() is not
    await assert.rejects(h.keeper.preflight(), (e: unknown) => e instanceof ConfigError && /not a Covenant kernel/.test(e.message));
  }
  {
    const h = harness();
    h.world.code.delete(TANK.toLowerCase());
    await assert.rejects(h.keeper.preflight(), (e: unknown) => e instanceof ConfigError && /TANK/.test(e.message));
  }
  {
    const h = harness();
    await h.keeper.preflight();
    assert.equal(h.log.find('kernel_ok')[0]?.fields['chipId'], 42n);
  }
});

test('preflight: an unreachable chain is not a configuration error', async () => {
  const h = harness({}, { rpcs: 2 });
  h.chains[0]!.failNext('*', 1000);
  h.chains[1]!.failNext('*', 1000);
  await assert.rejects(h.keeper.preflight(), RpcUnavailableError);
});

test('preflight: one unreachable endpoint is tolerated', async () => {
  const h = harness({}, { rpcs: 2 });
  h.chains[0]!.failNext('*', 1000);
  await h.keeper.preflight();
  assert.equal(h.log.find('rpc_unreachable').length, 1);
});

test('the signer address must be the simulation address', () => {
  const world = new World();
  const log = memoryLogger();
  const clock = manualClock();
  assert.throws(
    () =>
      new Keeper(DEFAULT_OPTIONS, {
        pool: new RpcPool([new FakeChain(world)], { log, sleep: clock.sleep }),
        signer: fakeSigner(KERNEL_B),
        from: WALLET,
        log,
        now: clock.now,
        sleep: clock.sleep,
        decodeRefund: makeRefundDecoder(DEFAULT_REFUNDED_EVENT),
      }),
    ConfigError,
  );
});

test('heartbeat reports the balance and warns when it is low', async () => {
  const h = harness();
  await h.keeper.heartbeat(true);
  assert.equal(h.log.find('heartbeat')[0]?.fields['balanceWei'], 50_000_000_000_000_000n);
  assert.equal(h.log.find('low_balance').length, 0);
  h.world.balances.set(WALLET.toLowerCase(), 1_000_000_000_000_000n);
  await h.keeper.heartbeat(true);
  assert.equal(h.log.find('low_balance').length, 1);
  // Not forced and not due yet: silent.
  await h.keeper.heartbeat();
  assert.equal(h.log.find('heartbeat').length, 2);
});

test('heartbeat shows what the tank can still refund for each chip', async () => {
  const h = harness();
  await h.keeper.preflight(); // learns each kernel's chip id
  await h.keeper.tick();
  await h.keeper.heartbeat(true);
  const kernels = h.log.find('heartbeat')[0]?.fields['kernels'] as Array<Record<string, unknown>>;
  assert.deepEqual(kernels, [
    {
      kernel: KERNEL_A,
      epochNow: 5,
      lastEpoch: 4,
      sentEpoch: 5,
      tankRemainingWei: 1_000_000_000_000_000n - 123_000_000_000_000n,
    },
  ]);

  // Without a tank there is nothing to report.
  const direct = harness({ tank: null });
  await direct.keeper.preflight();
  await direct.keeper.heartbeat(true);
  const k = direct.log.find('heartbeat')[0]?.fields['kernels'] as Array<Record<string, unknown>>;
  assert.equal(k[0]?.['tankRemainingWei'], null);
});

test('across many polls and epochs the number of sends equals the number of epochs', async () => {
  const h = harness();
  const k = h.world.kernel(KERNEL_A);
  let sends = 0;
  for (let epoch = 5; epoch < 25; epoch++) {
    k.epochNow = epoch;
    for (let poll = 0; poll < 7; poll++) await h.keeper.tick();
    sends++;
    assert.equal(h.world.sent.length, sends);
    assert.equal(k.lastEpoch, epoch);
  }
  // One transaction per epoch, and never two for the same epoch.
  const epochs = h.log.find('settled').map((l) => l.fields['epoch']);
  assert.equal(new Set(epochs).size, epochs.length);
});
