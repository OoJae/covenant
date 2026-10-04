// The only contract surface the keeper touches. Kernel ABI: chips/INTERFACE.md section 10.

import { decodeEventLog, encodeFunctionData, parseAbi, parseAbiItem, toEventSelector, toFunctionSelector } from 'viem';
import type { AbiEvent, Address, Hex } from 'viem';
import { ConfigError } from './errors.ts';

export const kernelAbi = parseAbi([
  'function chipId() view returns (uint256)',
  'function settle() returns (uint32 n)',
  'function epochNow() view returns (uint32)',
  'function lastEpoch() view returns (uint32)',
  'function minSettleGas() view returns (uint256)',
  'event Settled(uint32 indexed n, uint32 epoch, bytes12 inputs, bytes14 outputs, uint16 clampBits, uint8 flags, bytes32 stateAfter, uint128 inflow, uint128 allow, uint128 buyDecided, uint128 buyExecuted, uint128 tokensOut)',
]);

/**
 * KeeperTank (contracts/issuance/src/KeeperTank.sol): settleAndRefund calls kernel.settle(), bubbles up its
 * revert unchanged, and pays the caller min(gas * min(tx.gasprice, basefee + 0.01 gwei), allowance left).
 */
export const tankAbi = parseAbi([
  'function settleAndRefund(address kernel)',
  'function remainingOf(uint256 chipId) view returns (uint256)',
]);

export const CALLDATA = {
  chipId: encodeFunctionData({ abi: kernelAbi, functionName: 'chipId' }),
  settle: encodeFunctionData({ abi: kernelAbi, functionName: 'settle' }),
  epochNow: encodeFunctionData({ abi: kernelAbi, functionName: 'epochNow' }),
  lastEpoch: encodeFunctionData({ abi: kernelAbi, functionName: 'lastEpoch' }),
  minSettleGas: encodeFunctionData({ abi: kernelAbi, functionName: 'minSettleGas' }),
} as const;

export const settleAndRefundCalldata = (kernel: Address): Hex =>
  encodeFunctionData({ abi: tankAbi, functionName: 'settleAndRefund', args: [kernel] });

export const remainingOfCalldata = (chipId: bigint): Hex =>
  encodeFunctionData({ abi: tankAbi, functionName: 'remainingOf', args: [chipId] });

/**
 * Custom errors of the kernel and the tank, so that a failed simulation is logged by name instead of by
 * selector. Names only: an unknown selector is still reported as "custom error 0x........".
 */
const KNOWN_ERRORS = [
  // contracts/core/src/Kernel.sol
  'OnlyClone()',
  'AlreadyBound()',
  'NotBound()',
  'BindCheck(uint8)',
  'EpochNotElapsed()',
  'InsufficientGas()',
  'StepFailed()',
  'PayFailed()',
  'NotAccepted()',
  'NotGraduated()',
  // contracts/issuance/src/KeeperTank.sol
  'KernelDoesNotHoldChip()',
  'RefundFailed()',
  'InsufficientGasForAttribution()',
  // OpenZeppelin ReentrancyGuardTransient
  'ReentrancyGuardReentrantCall()',
] as const;

const ERROR_NAMES = new Map<string, string>(KNOWN_ERRORS.map((sig) => [toFunctionSelector(sig).toLowerCase(), sig]));

/** The error's signature for a known 4-byte selector, else null. */
export const knownErrorName = (data: string): string | null => ERROR_NAMES.get(data.slice(0, 10).toLowerCase()) ?? null;

/** The fields of a log that decoding needs. */
export interface LogLite {
  address: string;
  topics: readonly string[];
  data: string;
}

const sameAddress = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();

export interface SettledInfo {
  n: number;
  epoch: number;
  clampBits: number;
  flags: number;
  inflow: bigint;
  allow: bigint;
  buyDecided: bigint;
  buyExecuted: bigint;
  tokensOut: bigint;
}

/** The kernel's Settled event in a receipt, or null (absent, or declared differently by the deployed kernel). */
export function findSettled(logs: readonly LogLite[], kernel: Address): SettledInfo | null {
  for (const log of logs) {
    if (!sameAddress(log.address, kernel) || log.topics.length === 0) continue;
    try {
      const decoded = decodeEventLog({
        abi: kernelAbi,
        eventName: 'Settled',
        data: log.data as Hex,
        topics: log.topics as [Hex, ...Hex[]],
      });
      const a = decoded.args;
      return {
        n: a.n,
        epoch: a.epoch,
        clampBits: a.clampBits,
        flags: a.flags,
        inflow: a.inflow,
        allow: a.allow,
        buyDecided: a.buyDecided,
        buyExecuted: a.buyExecuted,
        tokensOut: a.tokensOut,
      };
    } catch {
      // not the Settled event
    }
  }
  return null;
}

export interface Refund {
  amount: bigint;
}

export type RefundDecoder = (logs: readonly LogLite[], tank: Address) => Refund | null;

const AMOUNT_NAMES = ['paid', 'amount', 'refund', 'refunded', 'value'];

/**
 * Build a decoder for the tank's refund event from its human-readable signature.
 * The amount is the argument named paid / amount / refund / refunded / value, else the last uint argument.
 */
export function makeRefundDecoder(signature: string): RefundDecoder {
  let item: AbiEvent;
  try {
    const parsed = parseAbiItem(signature) as { type: string };
    if (parsed.type !== 'event') throw new Error('not an event');
    item = parsed as AbiEvent;
  } catch {
    throw new ConfigError(
      `TANK_REFUNDED_EVENT: cannot parse "${signature}". Expected something like "event Refunded(uint256 indexed chipId, address indexed kernel, address indexed caller, uint256 gasUsed, uint256 paid)".`,
    );
  }

  const inputs = item.inputs;
  let index = -1;
  for (const name of AMOUNT_NAMES) {
    index = inputs.findIndex((i) => i.name === name && i.type.startsWith('uint'));
    if (index >= 0) break;
  }
  if (index < 0) {
    for (let i = inputs.length - 1; i >= 0; i--) {
      if (inputs[i]?.type.startsWith('uint')) {
        index = i;
        break;
      }
    }
  }
  if (index < 0) throw new ConfigError('TANK_REFUNDED_EVENT: the event has no uint argument to read the refund from');

  const topic0 = toEventSelector(item).toLowerCase();
  const amountName = inputs[index]?.name;

  return (logs, tank) => {
    for (const log of logs) {
      if (!sameAddress(log.address, tank)) continue;
      if (log.topics[0]?.toLowerCase() !== topic0) continue;
      try {
        const decoded = decodeEventLog({
          abi: [item],
          data: log.data as Hex,
          topics: log.topics as [Hex, ...Hex[]],
        });
        const args: unknown = decoded.args;
        let value: unknown;
        if (Array.isArray(args)) value = args[index];
        else if (args && typeof args === 'object' && amountName) value = (args as Record<string, unknown>)[amountName];
        if (typeof value === 'bigint') return { amount: value };
        if (typeof value === 'number') return { amount: BigInt(value) };
      } catch {
        // same topic, different layout: keep looking
      }
    }
    return null;
  };
}
