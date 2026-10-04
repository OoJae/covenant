import assert from 'node:assert/strict';
import { test } from 'node:test';
import { CALLDATA, settleAndRefundCalldata } from '../src/abi.ts';
import { GuardError } from '../src/errors.ts';
import { assertSettleOnly, bumpedFloor, feesFor, gasLimitFor, settleTarget } from '../src/tx.ts';
import type { GuardRules, UnsignedSettleTx } from '../src/tx.ts';
import { KERNEL_A, KERNEL_B, TANK, WALLET } from './helpers/fake-chain.ts';

test('gasLimitFor: max(estimate * 1.25, minSettleGas * 1.1), rounded up', () => {
  assert.equal(gasLimitFor(8_000_000n, 1_000_000n), 10_000_000n);
  assert.equal(gasLimitFor(1_000_000n, 10_000_000n), 11_000_000n);
  assert.equal(gasLimitFor(1n, 0n), 2n); // ceil(1.25)
  assert.equal(gasLimitFor(0n, 1n), 2n); // ceil(1.1)
  assert.equal(gasLimitFor(10_000_000n, 11_363_636n), 12_500_000n); // both about equal: the larger wins
  assert.equal(gasLimitFor(10_000_000n, 11_363_637n), 12_500_001n);
});

test('feesFor: twice the base fee plus the tip, under the cap', () => {
  assert.deepEqual(feesFor(20_000_000n, 1_000_000n, 100_000_000n), {
    ok: true,
    maxFeePerGas: 41_000_000n,
    maxPriorityFeePerGas: 1_000_000n,
  });
  // Clamped to the cap while base fee + tip still fits.
  assert.deepEqual(feesFor(60_000_000n, 1_000_000n, 100_000_000n), {
    ok: true,
    maxFeePerGas: 100_000_000n,
    maxPriorityFeePerGas: 1_000_000n,
  });
  // Exactly at the cap is allowed.
  const edge = feesFor(99_000_000n, 1_000_000n, 100_000_000n);
  assert.equal(edge.ok, true);
  // One wei above is not.
  const over = feesFor(99_000_001n, 1_000_000n, 100_000_000n);
  assert.deepEqual(over, { ok: false, reason: 'fee_above_cap', baseFee: 99_000_001n, needed: 100_000_001n, cap: 100_000_000n });
  // Zero tip is fine.
  assert.deepEqual(feesFor(20_000_000n, 0n, 100_000_000n), { ok: true, maxFeePerGas: 40_000_000n, maxPriorityFeePerGas: 0n });
});

test('feesFor: the tip never exceeds maxFeePerGas, and maxFeePerGas always covers base fee + tip', () => {
  for (const base of [0n, 1n, 20_000_000n, 49_999_999n, 80_000_000n]) {
    for (const tip of [0n, 1n, 1_000_000n, 10_000_000n]) {
      const f = feesFor(base, tip, 100_000_000n);
      if (!f.ok) continue;
      assert.ok(f.maxPriorityFeePerGas <= f.maxFeePerGas);
      assert.ok(f.maxFeePerGas >= base + f.maxPriorityFeePerGas);
      assert.ok(f.maxFeePerGas <= 100_000_000n);
    }
  }
});

test('feesFor with a replacement floor: meets the floor or refuses', () => {
  const floor = bumpedFloor({ maxFeePerGas: 41_000_000n, maxPriorityFeePerGas: 1_000_000n });
  assert.deepEqual(floor, { maxFeePerGas: 46_125_000n, maxPriorityFeePerGas: 1_125_000n });
  assert.deepEqual(feesFor(20_000_000n, 1_000_000n, 100_000_000n, floor), {
    ok: true,
    maxFeePerGas: 46_125_000n,
    maxPriorityFeePerGas: 1_125_000n,
  });
  // A floor above the cap cannot be met: no replacement.
  const high = feesFor(20_000_000n, 1_000_000n, 100_000_000n, { maxFeePerGas: 100_000_001n, maxPriorityFeePerGas: 2_000_000n });
  assert.equal(high.ok, false);
  assert.equal(!high.ok && high.reason, 'replacement_above_cap');
});

test('bumpedFloor always raises both fields', () => {
  assert.deepEqual(bumpedFloor({ maxFeePerGas: 0n, maxPriorityFeePerGas: 0n }), { maxFeePerGas: 1n, maxPriorityFeePerGas: 1n });
  assert.deepEqual(bumpedFloor({ maxFeePerGas: 1n, maxPriorityFeePerGas: 1n }), { maxFeePerGas: 2n, maxPriorityFeePerGas: 2n });
  const twice = bumpedFloor({ maxFeePerGas: 1000n, maxPriorityFeePerGas: 1000n }, 2);
  assert.deepEqual(twice, { maxFeePerGas: 1266n, maxPriorityFeePerGas: 1266n });
});

test('settleTarget: tank when configured, kernel otherwise', () => {
  assert.deepEqual(settleTarget(KERNEL_A, TANK), { via: 'tank', kernel: KERNEL_A, to: TANK, data: settleAndRefundCalldata(KERNEL_A) });
  assert.deepEqual(settleTarget(KERNEL_A, null), { via: 'direct', kernel: KERNEL_A, to: KERNEL_A, data: CALLDATA.settle });
  assert.equal(CALLDATA.settle, '0x11da60b4');
  assert.equal(settleAndRefundCalldata(KERNEL_A).length, 2 + 8 + 64);
});

const rules: GuardRules = {
  kernels: [KERNEL_A, KERNEL_B],
  tank: TANK,
  chainId: 196,
  maxGasLimit: 30_000_000n,
  maxFeePerGasCap: 100_000_000n,
};

const good = (over: Partial<UnsignedSettleTx> = {}): UnsignedSettleTx => ({
  chainId: 196,
  to: TANK,
  data: settleAndRefundCalldata(KERNEL_A),
  value: 0n,
  gas: 11_000_000n,
  nonce: 0,
  maxFeePerGas: 41_000_000n,
  maxPriorityFeePerGas: 1_000_000n,
  ...over,
});

test('assertSettleOnly accepts exactly the two settle calls', () => {
  assertSettleOnly(good(), rules);
  assertSettleOnly(good({ data: settleAndRefundCalldata(KERNEL_B) }), rules);
  assertSettleOnly(good({ to: KERNEL_A, data: CALLDATA.settle }), rules);
  assertSettleOnly(good({ to: KERNEL_B, data: CALLDATA.settle }), rules);
  // Letter case of the address does not matter.
  assertSettleOnly(good({ to: TANK.toLowerCase() as typeof TANK }), rules);
});

test('assertSettleOnly refuses everything else', () => {
  const refuse = (over: Partial<UnsignedSettleTx>, pattern: RegExp, r: GuardRules = rules): void => {
    assert.throws(() => assertSettleOnly(good(over), r), (e: unknown) => e instanceof GuardError && pattern.test(e.message));
  };
  // Value transfer.
  refuse({ value: 1n }, /value must be zero/);
  // Some other recipient, including the wallet itself and the USDT0 token.
  refuse({ to: WALLET }, /neither a configured kernel nor the tank/);
  refuse({ to: '0x779Ded0c9e1022225f8E0630b35a9b54bE713736' }, /neither a configured kernel nor the tank/);
  // The tank with a kernel that is not configured.
  refuse({ data: settleAndRefundCalldata(WALLET) }, /settleAndRefund\(kernel\) for a configured kernel/);
  // The tank with settle() calldata, or with trailing bytes, or empty calldata.
  refuse({ data: CALLDATA.settle }, /settleAndRefund/);
  refuse({ data: `${settleAndRefundCalldata(KERNEL_A)}00` }, /settleAndRefund/);
  refuse({ data: '0x' }, /settleAndRefund/);
  // A kernel with anything but settle(): withdrawCredit, bind, an ERC-20 transfer selector, trailing bytes.
  refuse({ to: KERNEL_A, data: '0xa9059cbb' }, /exactly settle\(\)/);
  refuse({ to: KERNEL_A, data: settleAndRefundCalldata(KERNEL_A) }, /exactly settle\(\)/);
  refuse({ to: KERNEL_A, data: `${CALLDATA.settle}00` }, /exactly settle\(\)/);
  refuse({ to: KERNEL_A, data: '0x' }, /exactly settle\(\)/);
  // Wrong chain, gas and fee limits, nonce.
  refuse({ chainId: 1 }, /chain id 1, expected 196/);
  refuse({ gas: 30_000_001n }, /gas limit/);
  refuse({ gas: 0n }, /gas limit/);
  refuse({ maxFeePerGas: 100_000_001n }, /above the cap/);
  refuse({ maxPriorityFeePerGas: 41_000_001n }, /maxPriorityFeePerGas/);
  refuse({ nonce: -1 }, /bad nonce/);
  // Without a tank configured, a call to the tank address is just another unknown recipient.
  refuse({}, /neither a configured kernel nor the tank/, { ...rules, tank: null });
});
