// Pure rules: gas limit, fees, and the guard that keeps this wallet to one kind of transaction.

import type { Address, Hex } from 'viem';
import { CALLDATA, settleAndRefundCalldata } from './abi.ts';
import { GuardError } from './errors.ts';

/** max(ceil(estimate * 1.25), ceil(minSettleGas * 1.1)). The second term keeps the kernel's gas guard satisfied
 *  through the tank's 63/64 forwarding. */
export function gasLimitFor(estimate: bigint, minSettleGas: bigint): bigint {
  const fromEstimate = (estimate * 125n + 99n) / 100n;
  const fromFloor = (minSettleGas * 110n + 99n) / 100n;
  return fromEstimate > fromFloor ? fromEstimate : fromFloor;
}

export interface Fees {
  maxFeePerGas: bigint;
  maxPriorityFeePerGas: bigint;
}

export type FeeDecision =
  | ({ ok: true } & Fees)
  | { ok: false; reason: 'fee_above_cap' | 'replacement_above_cap'; baseFee: bigint; needed: bigint; cap: bigint };

/**
 * EIP-1559 fees under a hard cap.
 *   maxFeePerGas = min(cap, 2 * baseFee + tip): room for the base fee to double before the transaction stalls.
 * If baseFee + tip is already above the cap the keeper does not send; it tries again on the next poll.
 * `floor` is the minimum a replacement must pay to evict a pending transaction at the same nonce.
 */
export function feesFor(baseFee: bigint, tip: bigint, cap: bigint, floor?: Fees): FeeDecision {
  const priority = floor && floor.maxPriorityFeePerGas > tip ? floor.maxPriorityFeePerGas : tip;
  const needed = baseFee + priority;
  if (needed > cap) {
    return { ok: false, reason: floor ? 'replacement_above_cap' : 'fee_above_cap', baseFee, needed, cap };
  }
  let maxFee = 2n * baseFee + priority;
  if (floor && floor.maxFeePerGas > maxFee) maxFee = floor.maxFeePerGas;
  if (maxFee > cap) {
    if (floor && floor.maxFeePerGas > cap) {
      return { ok: false, reason: 'replacement_above_cap', baseFee, needed: floor.maxFeePerGas, cap };
    }
    maxFee = cap;
  }
  return { ok: true, maxFeePerGas: maxFee, maxPriorityFeePerGas: priority };
}

/** What a replacement must pay at least: 12.5% more on both fields, and never the same value. */
export function bumpedFloor(prev: Fees, times = 1): Fees {
  const up = (x: bigint): bigint => {
    const y = (x * 1125n + 999n) / 1000n;
    return y > x ? y : x + 1n;
  };
  let out: Fees = { ...prev };
  for (let i = 0; i < Math.max(1, times); i++) {
    out = { maxFeePerGas: up(out.maxFeePerGas), maxPriorityFeePerGas: up(out.maxPriorityFeePerGas) };
  }
  return out;
}

export interface SettleTarget {
  via: 'tank' | 'direct';
  kernel: Address;
  to: Address;
  data: Hex;
}

/** Through the tank when one is configured (gas refunded), else straight to the kernel. */
export function settleTarget(kernel: Address, tank: Address | null): SettleTarget {
  return tank
    ? { via: 'tank', kernel, to: tank, data: settleAndRefundCalldata(kernel) }
    : { via: 'direct', kernel, to: kernel, data: CALLDATA.settle };
}

export interface GuardRules {
  kernels: readonly Address[];
  tank: Address | null;
  chainId: number;
  maxGasLimit: bigint;
  maxFeePerGasCap: bigint;
}

export interface UnsignedSettleTx {
  chainId: number;
  to: Address;
  data: Hex;
  value: bigint;
  gas: bigint;
  nonce: number;
  maxFeePerGas: bigint;
  maxPriorityFeePerGas: bigint;
}

const lower = (s: string): string => s.toLowerCase();

/**
 * The keeper wallet is a declared team wallet and may only ever call settle. This runs on the exact
 * object handed to the signer: any other recipient, calldata, value, chain or fee above the cap throws.
 */
export function assertSettleOnly(tx: UnsignedSettleTx, rules: GuardRules): void {
  if (tx.chainId !== rules.chainId) throw new GuardError(`chain id ${tx.chainId}, expected ${rules.chainId}`);
  if (tx.value !== 0n) throw new GuardError('value must be zero');
  if (tx.gas <= 0n || tx.gas > rules.maxGasLimit) throw new GuardError(`gas limit ${tx.gas} is outside 1..${rules.maxGasLimit}`);
  if (tx.maxFeePerGas <= 0n || tx.maxFeePerGas > rules.maxFeePerGasCap) {
    throw new GuardError(`maxFeePerGas ${tx.maxFeePerGas} is above the cap ${rules.maxFeePerGasCap}`);
  }
  if (tx.maxPriorityFeePerGas < 0n || tx.maxPriorityFeePerGas > tx.maxFeePerGas) {
    throw new GuardError('maxPriorityFeePerGas must be between 0 and maxFeePerGas');
  }
  if (!Number.isSafeInteger(tx.nonce) || tx.nonce < 0) throw new GuardError('bad nonce');

  const to = lower(tx.to);
  const data = lower(tx.data);
  const kernels = rules.kernels.map(lower);

  if (kernels.includes(to)) {
    if (data !== lower(CALLDATA.settle)) throw new GuardError('a call to a kernel must be exactly settle()');
    return;
  }
  if (rules.tank && to === lower(rules.tank)) {
    for (const kernel of rules.kernels) {
      if (data === lower(settleAndRefundCalldata(kernel))) return;
    }
    throw new GuardError('a call to the tank must be exactly settleAndRefund(kernel) for a configured kernel');
  }
  throw new GuardError(`recipient ${tx.to} is neither a configured kernel nor the tank`);
}
