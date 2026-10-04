// A scripted chain for the scheduling tests. No network and no private key anywhere:
// the "signer" serialises the transaction with a constant dummy signature.

import { encodeAbiParameters, encodeEventTopics, getAddress, keccak256, parseAbiItem, parseTransaction, serializeTransaction } from 'viem';
import type { AbiEvent, Address, Hex } from 'viem';
import { kernelAbi, makeRefundDecoder, settleAndRefundCalldata, CALLDATA } from '../../src/abi.ts';
import type { LogLite } from '../../src/abi.ts';
import type { CallRequest, ChainClient, KernelView, Receipt } from '../../src/chain.ts';
import { DEFAULT_REFUNDED_EVENT } from '../../src/config.ts';
import { NonceTooLowError, RevertError, RpcError } from '../../src/errors.ts';
import { Keeper } from '../../src/keeper.ts';
import type { KeeperOptions, Signer } from '../../src/keeper.ts';
import type { Fields, Logger } from '../../src/log.ts';
import { RpcPool } from '../../src/pool.ts';
import type { StateStore } from '../../src/state.ts';

// Made-up addresses in checksummed form, the form the keeper normalises to.
export const KERNEL_A: Address = getAddress('0x00000000000000000000000000000000000000a1');
export const KERNEL_B: Address = getAddress('0x00000000000000000000000000000000000000b2');
export const TANK: Address = getAddress('0x00000000000000000000000000000000000000c3');
export const WALLET: Address = getAddress('0x00000000000000000000000000000000000000d4');

export interface FakeKernel {
  epochNow: number;
  lastEpoch: number;
  minSettleGas: bigint;
  chipId: bigint;
  count: number;
  /** When set, settle() reverts with this reason (in simulation and on chain). */
  settleRevert: string | null;
  /** When set, the views revert: the kernel is not bound yet. */
  viewRevert: string | null;
}

export interface SentTx {
  raw: Hex;
  hash: Hex;
  to: Address;
  data: Hex;
  gas: bigint;
  nonce: number;
  chainId: number;
  value: bigint;
  maxFeePerGas: bigint;
  maxPriorityFeePerGas: bigint;
  type: string;
}

const refundedEvent = parseAbiItem(DEFAULT_REFUNDED_EVENT) as AbiEvent;

/** State shared by every FakeChain endpoint of a test: several RPC URLs, one chain. */
export class World {
  chain = 196;
  kernels = new Map<string, FakeKernel>();
  code = new Set<string>();
  tank: Address | null = TANK;
  /** When set, the tank path reverts with this reason while the direct path still works. */
  tankRevert: string | null = null;
  /** Refund the tank pays per settle; null means the tank emits no event this keeper can decode. */
  refundWei: bigint | null = 123_000_000_000_000n;
  /** What the tank can still pay for any chip. A refund is capped by it, like the real tank's allowance. */
  tankRemainingWei = 1_000_000_000_000_000n;
  baseFee = 20_000_000n;
  balances = new Map<string, bigint>([[WALLET.toLowerCase(), 50_000_000_000_000_000n]]);
  nonceLatest = 7;
  /** Extra transactions sitting in the pool that the keeper under test did not send. */
  foreignPending = 0;
  estimate = 5_000_000n;
  gasUsed = 4_200_000n;
  /** Mine a broadcast transaction at once. When false it stays pending until mine() is called. */
  autoMine = true;
  /** Mined transactions revert on chain although the simulation passed. */
  mineReverts = false;
  /** Re-broadcasting bytes that are already mined is answered with "nonce too low" instead of "already known". */
  minedSaysNonceTooLow = false;
  /** Runs at the start of every broadcast: lets a test change the chain between the nonce read and the send. */
  beforeSend: (() => void) | null = null;
  sent: SentTx[] = [];
  pool = new Map<Hex, SentTx>();
  receipts = new Map<Hex, Receipt>();
  block = 1000n;

  constructor() {
    this.addKernel(KERNEL_A, { epochNow: 5, lastEpoch: 4 });
    this.code.add(TANK.toLowerCase());
  }

  addKernel(address: Address, init: Partial<FakeKernel> = {}): FakeKernel {
    const k: FakeKernel = {
      epochNow: 1,
      lastEpoch: 0,
      minSettleGas: 10_000_000n,
      chipId: 42n,
      count: 0,
      settleRevert: null,
      viewRevert: null,
      ...init,
    };
    this.kernels.set(address.toLowerCase(), k);
    this.code.add(address.toLowerCase());
    return k;
  }

  kernel(address: Address): FakeKernel {
    const k = this.kernels.get(address.toLowerCase());
    if (!k) throw new RevertError('no data: the address is not a kernel');
    return k;
  }

  /** Which kernel a call targets, and whether it goes through the tank. Throws RevertError like a node would. */
  resolve(to: Address, data: Hex): { kernel: Address; via: 'tank' | 'direct' } {
    const lowerTo = to.toLowerCase();
    if (this.tank && lowerTo === this.tank.toLowerCase()) {
      for (const address of this.kernels.keys()) {
        if (data.toLowerCase() === settleAndRefundCalldata(address as Address).toLowerCase()) {
          return { kernel: address as Address, via: 'tank' };
        }
      }
      throw new RevertError('tank: unknown kernel');
    }
    if (this.kernels.has(lowerTo) && data.toLowerCase() === CALLDATA.settle.toLowerCase()) {
      return { kernel: to, via: 'direct' };
    }
    throw new RevertError('no such function');
  }

  /** What executing the settle would do right now. */
  check(to: Address, data: Hex): { kernel: Address; via: 'tank' | 'direct' } {
    const target = this.resolve(to, data);
    const k = this.kernel(target.kernel);
    if (target.via === 'tank' && this.tankRevert) throw new RevertError(this.tankRevert);
    if (k.viewRevert) throw new RevertError(k.viewRevert);
    if (k.settleRevert) throw new RevertError(k.settleRevert);
    if (k.epochNow <= k.lastEpoch) throw new RevertError('epoch already settled');
    return target;
  }

  mine(hash: Hex): Receipt {
    const tx = this.pool.get(hash);
    if (!tx) throw new Error(`fake chain: ${hash} is not in the pool`);
    this.pool.delete(hash);
    // Every other pooled transaction with the same nonce is now invalid, including a foreign one:
    // foreign pending transactions occupy the nonces from nonceLatest upwards.
    for (const [h, other] of this.pool) if (other.nonce === tx.nonce) this.pool.delete(h);
    if (this.foreignPending > 0 && tx.nonce === this.nonceLatest) this.foreignPending -= 1;
    this.nonceLatest = tx.nonce + 1;
    this.block += 1n;

    let status: 'success' | 'reverted' = 'success';
    const logs: LogLite[] = [];
    try {
      if (this.mineReverts) throw new RevertError('reverted on chain');
      const target = this.check(tx.to, tx.data);
      const k = this.kernel(target.kernel);
      k.lastEpoch = k.epochNow;
      k.count += 1;
      logs.push({
        address: target.kernel,
        topics: encodeEventTopics({ abi: kernelAbi, eventName: 'Settled', args: { n: k.count } }) as string[],
        data: encodeAbiParameters(
          [
            { type: 'uint32' }, { type: 'bytes12' }, { type: 'bytes14' }, { type: 'uint16' }, { type: 'uint8' },
            { type: 'bytes32' }, { type: 'uint128' }, { type: 'uint128' }, { type: 'uint128' }, { type: 'uint128' }, { type: 'uint128' },
          ],
          [k.epochNow, `0x${'00'.repeat(12)}`, `0x${'00'.repeat(14)}`, 0, 0, `0x${'00'.repeat(32)}`, 1000n, 100n, 500n, 500n, 77n],
        ),
      });
      if (target.via === 'tank' && this.tank && this.refundWei !== null) {
        const paid = this.refundWei < this.tankRemainingWei ? this.refundWei : this.tankRemainingWei;
        this.tankRemainingWei -= paid;
        logs.push({
          address: this.tank,
          topics: encodeEventTopics({
            abi: [refundedEvent],
            args: { chipId: k.chipId, kernel: target.kernel, caller: WALLET },
          }) as string[],
          data: encodeAbiParameters([{ type: 'uint256' }, { type: 'uint256' }], [this.gasUsed + 34_000n, paid]),
        });
      }
    } catch (err) {
      if (!(err instanceof RevertError)) throw err;
      status = 'reverted';
    }
    const receipt: Receipt = {
      transactionHash: hash,
      status,
      blockNumber: this.block,
      gasUsed: this.gasUsed,
      effectiveGasPrice: this.baseFee + tx.maxPriorityFeePerGas,
      l1Fee: 0n,
      logs,
    };
    this.receipts.set(hash, receipt);
    return receipt;
  }
}

export class FakeChain implements ChainClient {
  readonly label: string;
  readonly world: World;
  /** Throw RpcError for the next N calls of a method (or of any method with the key "*"). */
  failures = new Map<string, number>();
  /** For the next N broadcasts: take the transaction, then fail as if the response had been lost. */
  acceptThenFail = 0;
  calls: Record<string, number> = {};
  chainOverride: number | null = null;

  constructor(world: World, label = 'fake-a') {
    this.world = world;
    this.label = label;
  }

  failNext(method: string, times: number): void {
    this.failures.set(method, times);
  }

  #enter(method: string): void {
    this.calls[method] = (this.calls[method] ?? 0) + 1;
    for (const key of [method, '*']) {
      const left = this.failures.get(key) ?? 0;
      if (left > 0) {
        this.failures.set(key, left - 1);
        throw new RpcError(this.label, method, 'injected failure');
      }
    }
  }

  async chainId(): Promise<number> {
    this.#enter('chainId');
    return this.chainOverride ?? this.world.chain;
  }

  async hasCode(address: Address): Promise<boolean> {
    this.#enter('hasCode');
    return this.world.code.has(address.toLowerCase());
  }

  async chipId(kernel: Address): Promise<bigint> {
    this.#enter('chipId');
    return this.world.kernel(kernel).chipId;
  }

  async epochs(kernel: Address): Promise<KernelView> {
    this.#enter('epochs');
    const k = this.world.kernel(kernel);
    if (k.viewRevert) throw new RevertError(k.viewRevert);
    return { epochNow: k.epochNow, lastEpoch: k.lastEpoch };
  }

  async minSettleGas(kernel: Address): Promise<bigint> {
    this.#enter('minSettleGas');
    return this.world.kernel(kernel).minSettleGas;
  }

  async tankRemaining(tank: Address): Promise<bigint> {
    this.#enter('tankRemaining');
    if (!this.world.tank || tank.toLowerCase() !== this.world.tank.toLowerCase()) throw new RevertError('no such function');
    return this.world.tankRemainingWei;
  }

  async baseFee(): Promise<bigint> {
    this.#enter('baseFee');
    return this.world.baseFee;
  }

  async balance(address: Address): Promise<bigint> {
    this.#enter('balance');
    return this.world.balances.get(address.toLowerCase()) ?? 0n;
  }

  async nonces(): Promise<{ latest: number; pending: number }> {
    this.#enter('nonces');
    const pooled = new Set([...this.world.pool.values()].map((t) => t.nonce)).size;
    return { latest: this.world.nonceLatest, pending: this.world.nonceLatest + pooled + this.world.foreignPending };
  }

  async estimateGas(call: CallRequest): Promise<bigint> {
    this.#enter('estimateGas');
    this.world.check(call.to, call.data);
    return this.world.estimate;
  }

  async simulate(call: CallRequest): Promise<Hex> {
    this.#enter('simulate');
    this.world.check(call.to, call.data);
    return '0x';
  }

  async sendRaw(raw: Hex): Promise<void> {
    this.#enter('sendRaw');
    this.world.beforeSend?.();
    const hash = keccak256(raw);
    if (this.world.receipts.has(hash)) {
      // Already mined. Some nodes say "already known", others "nonce too low".
      if (this.world.minedSaysNonceTooLow) throw new NonceTooLowError('nonce too low');
      return;
    }
    if (this.world.pool.has(hash)) return; // already known
    const p = parseTransaction(raw);
    if ((p.nonce ?? 0) < this.world.nonceLatest) throw new NonceTooLowError('nonce too low');
    const tx: SentTx = {
      raw,
      hash,
      to: p.to as Address,
      data: (p.data ?? '0x') as Hex,
      gas: p.gas ?? 0n,
      nonce: p.nonce ?? 0,
      chainId: p.chainId ?? 0,
      value: p.value ?? 0n,
      maxFeePerGas: p.maxFeePerGas ?? 0n,
      maxPriorityFeePerGas: p.maxPriorityFeePerGas ?? 0n,
      type: String(p.type),
    };
    this.world.sent.push(tx);
    this.world.pool.set(hash, tx);
    if (this.world.autoMine) this.world.mine(hash);
    if (this.acceptThenFail > 0) {
      this.acceptThenFail -= 1;
      throw new RpcError(this.label, 'sendRaw', 'response lost');
    }
  }

  async receipt(hash: Hex): Promise<Receipt | null> {
    this.#enter('receipt');
    return this.world.receipts.get(hash) ?? null;
  }
}

/** Serialises with a constant dummy signature. The address is whatever the test says it is. */
export function fakeSigner(address: Address = WALLET): Signer & { signed: number } {
  const s = {
    address,
    signed: 0,
    async signTransaction(tx: Parameters<Signer['signTransaction']>[0]): Promise<Hex> {
      s.signed += 1;
      return serializeTransaction(tx, { r: '0x1', s: '0x1', yParity: 0 });
    },
  };
  return s;
}

export interface LogLine {
  level: string;
  event: string;
  fields: Fields;
}

export function memoryLogger(): Logger & { lines: LogLine[]; events(): string[]; find(event: string): LogLine[] } {
  const lines: LogLine[] = [];
  const push = (level: string) => (event: string, fields: Fields = {}) => void lines.push({ level, event, fields });
  return {
    lines,
    events: () => lines.map((l) => l.event),
    find: (event) => lines.filter((l) => l.event === event),
    debug: push('debug'),
    info: push('info'),
    warn: push('warn'),
    error: push('error'),
  };
}

/** A clock the test moves by hand; sleep() advances it instead of waiting. */
export function manualClock(start = 1_000_000): { now: () => number; sleep: (ms: number) => Promise<void>; advance: (ms: number) => void; slept: number[] } {
  let t = start;
  const slept: number[] = [];
  return {
    now: () => t,
    sleep: async (ms) => {
      slept.push(ms);
      t += ms;
    },
    advance: (ms) => {
      t += ms;
    },
    slept,
  };
}

export const DEFAULT_OPTIONS: KeeperOptions = {
  kernels: [KERNEL_A],
  tank: TANK,
  chainId: 196,
  maxFeePerGasCap: 100_000_000n, // 0.1 gwei
  priorityFeePerGas: 1_000_000n, // 0.001 gwei
  maxGasLimit: 30_000_000n,
  minEpochLag: 1,
  directFallback: true,
  dryRun: false,
  verboseIdle: false,
  receiptTimeoutMs: 5_000,
  receiptPollMs: 1_000,
  stuckTxMs: 180_000,
  minBalanceWei: 5_000_000_000_000_000n,
  heartbeatMs: 600_000,
};

export interface Harness {
  world: World;
  chains: FakeChain[];
  keeper: Keeper;
  log: ReturnType<typeof memoryLogger>;
  clock: ReturnType<typeof manualClock>;
  signer: ReturnType<typeof fakeSigner> | null;
}

export function harness(
  overrides: Partial<KeeperOptions> = {},
  setup: { rpcs?: number; signer?: boolean; world?: World; store?: StateStore } = {},
): Harness {
  const world = setup.world ?? new World();
  const options = { ...DEFAULT_OPTIONS, ...overrides };
  world.tank = options.tank;
  const chains = Array.from({ length: setup.rpcs ?? 1 }, (_, i) => new FakeChain(world, `fake-${'abcdef'[i]}`));
  const log = memoryLogger();
  const clock = manualClock();
  const signer = setup.signer === false ? null : fakeSigner();
  const pool = new RpcPool(chains, { log, sleep: clock.sleep, random: () => 0 });
  const keeper = new Keeper(options, {
    pool,
    signer,
    from: WALLET,
    log,
    now: clock.now,
    sleep: clock.sleep,
    decodeRefund: makeRefundDecoder(DEFAULT_REFUNDED_EVENT),
    store: setup.store,
  });
  return { world, chains, keeper, log, clock, signer };
}
