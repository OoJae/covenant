// The scheduling logic. Everything it touches is injected (chain, signer, clock, logger), so it runs
// unchanged against the real chain and against the fake one in test/.
//
// Rules, in the order they are applied to each kernel on every pass:
//   1. Read epochNow() and lastEpoch(). Nothing to do unless epochNow - lastEpoch >= minEpochLag.
//   2. At most one settle is ever sent per kernel per epoch. The epoch is recorded just before the
//      broadcast, so no error path can lead to a second send in the same epoch.
//   3. The wallet has at most one transaction in flight. While one is pending, nothing new is sent.
//      If it stays pending past stuckTxMs, the next settle reuses its nonce with higher fees, so
//      only one of the two can ever be mined.
//   4. The call is estimated and then simulated at the exact gas limit, through the tank when one
//      is configured. It is sent only if the simulation succeeds.
//   5. The transaction is checked by assertSettleOnly() and only then signed.

import { keccak256 } from 'viem';
import type { Address, Hex, TransactionSerializableEIP1559 } from 'viem';
import { findSettled } from './abi.ts';
import type { RefundDecoder } from './abi.ts';
import type { KernelView, Receipt } from './chain.ts';
import {
  ConfigError,
  InsufficientFundsError,
  NonceTooLowError,
  RevertError,
  RpcUnavailableError,
  TxRejectedError,
  UnderpricedError,
} from './errors.ts';
import type { Logger } from './log.ts';
import type { Pool } from './pool.ts';
import { memoryStore } from './state.ts';
import type { StateStore } from './state.ts';
import { assertSettleOnly, bumpedFloor, feesFor, gasLimitFor, settleTarget } from './tx.ts';
import type { Fees, SettleTarget } from './tx.ts';

export interface Signer {
  readonly address: Address;
  signTransaction(tx: TransactionSerializableEIP1559): Promise<Hex>;
}

export interface KeeperOptions {
  kernels: readonly Address[];
  tank: Address | null;
  chainId: number;
  maxFeePerGasCap: bigint;
  priorityFeePerGas: bigint;
  maxGasLimit: bigint;
  minEpochLag: number;
  directFallback: boolean;
  dryRun: boolean;
  /** Log idle kernels at info level (used by --once, where every pass should leave a trace). */
  verboseIdle: boolean;
  receiptTimeoutMs: number;
  receiptPollMs: number;
  stuckTxMs: number;
  minBalanceWei: bigint;
  heartbeatMs: number;
}

export interface KeeperDeps {
  pool: Pool;
  /** null in dry-run mode without a key. */
  signer: Signer | null;
  /** The address simulations are made from. Equals signer.address when there is a signer. */
  from: Address;
  log: Logger;
  now: () => number;
  sleep: (ms: number) => Promise<void>;
  decodeRefund: RefundDecoder;
  /** Remembers the send of each epoch across restarts. Default: memory only. */
  store?: StateStore;
}

export type Outcome =
  | { kind: 'idle'; kernel: Address; epochNow: number; lastEpoch: number }
  | { kind: 'already_sent'; kernel: Address; epoch: number; txHash: Hex | null }
  | { kind: 'waiting'; kernel: Address; epoch: number; reason: 'own_tx_pending' | 'foreign_tx_pending' }
  | { kind: 'not_ready'; kernel: Address; reason: string }
  | { kind: 'simulation_failed'; kernel: Address; epoch: number; reason: string }
  | { kind: 'fee_above_cap'; kernel: Address; epoch: number }
  | { kind: 'gas_above_cap'; kernel: Address; epoch: number }
  | { kind: 'insufficient_balance'; kernel: Address; epoch: number }
  | { kind: 'dry_run'; kernel: Address; epoch: number; via: 'tank' | 'direct'; gas: bigint }
  | { kind: 'settled'; kernel: Address; epoch: number; txHash: Hex; gasUsed: bigint; refundWei: bigint | null }
  | { kind: 'reverted'; kernel: Address; epoch: number; txHash: Hex }
  | { kind: 'pending'; kernel: Address; epoch: number; txHash: Hex }
  | { kind: 'send_failed'; kernel: Address; epoch: number; reason: string }
  | { kind: 'rpc_unavailable'; kernel: Address; error: string };

/** Outcomes after which a one-shot run should exit non-zero: a settle was due and did not land. */
export const FAILED_KINDS: ReadonlySet<Outcome['kind']> = new Set([
  'not_ready',
  'simulation_failed',
  'fee_above_cap',
  'gas_above_cap',
  'insufficient_balance',
  'reverted',
  'pending',
  'send_failed',
  'rpc_unavailable',
]);

interface KernelState {
  /** The epoch of the single send this process made for the kernel, if any. */
  sentEpoch: number | null;
  sentHash: Hex | null;
  /** The epoch last reported in dry-run mode, so each epoch is printed once. */
  lastKey: string | null;
  view: KernelView | null;
  chipId: bigint | null;
}

interface Inflight {
  kernel: Address;
  epoch: number;
  hash: Hex;
  raw: Hex;
  nonce: number;
  fees: Fees;
  gas: bigint;
  via: 'tank' | 'direct';
  sentAt: number;
}

type Slot =
  | { kind: 'ready'; nonce: number; floor?: Fees; replaces?: Hex; stateChanged: boolean }
  | { kind: 'wait'; reason: 'own_tx_pending' | 'foreign_tx_pending'; txHash?: Hex };

interface Plan {
  target: SettleTarget;
  estimate: bigint;
  minSettleGas: bigint;
  gas: bigint;
  fees: Fees;
  baseFee: bigint;
  balance: bigint;
  /** False when the wallet could not cover the worst case, so the simulation ran at gas price zero. */
  feesSimulated: boolean;
  /** Why the tank path was not used, when the direct fallback was. */
  tankFailure: string | null;
}

const message = (err: unknown): string => (err instanceof Error ? err.message : String(err));

export class Keeper {
  readonly #o: KeeperOptions;
  readonly #pool: Pool;
  readonly #signer: Signer | null;
  readonly #from: Address;
  readonly #log: Logger;
  readonly #now: () => number;
  readonly #sleep: (ms: number) => Promise<void>;
  readonly #decodeRefund: RefundDecoder;
  readonly #store: StateStore;

  readonly #kernels = new Map<Address, KernelState>();
  #inflight: Inflight | null = null;
  #foreignSince: number | null = null;
  #foreignBumps = 0;
  #lastHeartbeat: number | null = null;

  constructor(options: KeeperOptions, deps: KeeperDeps) {
    if (!options.dryRun && !deps.signer) throw new ConfigError('KEEPER_PRIVATE_KEY is required unless DRY_RUN is set');
    if (deps.signer && deps.signer.address.toLowerCase() !== deps.from.toLowerCase()) {
      throw new ConfigError('the signer address and the simulation address differ');
    }
    this.#o = options;
    this.#pool = deps.pool;
    this.#signer = deps.signer;
    this.#from = deps.from;
    this.#log = deps.log;
    this.#now = deps.now;
    this.#sleep = deps.sleep;
    this.#decodeRefund = deps.decodeRefund;
    this.#store = deps.store ?? memoryStore();
    // What an earlier run of this wallet sent: rule 2 holds across restarts as far as the store reaches.
    const remembered = this.#store.load();
    for (const kernel of options.kernels) {
      const r = remembered.get(kernel.toLowerCase());
      this.#kernels.set(kernel, {
        sentEpoch: r ? r.epoch : null,
        sentHash: r ? r.txHash : null,
        lastKey: null,
        view: null,
        chipId: null,
      });
    }
  }

  /** The unmined transaction this process is tracking, if any. For tests and the heartbeat. */
  get inflightHash(): Hex | null {
    return this.#inflight?.hash ?? null;
  }

  #state(kernel: Address): KernelState {
    const st = this.#kernels.get(kernel);
    if (!st) throw new Error(`unknown kernel ${kernel}`);
    return st;
  }

  /** Log a line only when it differs from the last one logged for this kernel. */
  #note(kernel: Address, key: string, level: 'debug' | 'info' | 'warn' | 'error', event: string, fields: Record<string, unknown>): void {
    const st = this.#state(kernel);
    if (st.lastKey === key) return;
    st.lastKey = key;
    this.#log[level](event, { kernel, ...fields });
  }

  /**
   * Checks that need the chain: every reachable RPC serves the configured chain, every kernel is a
   * contract that answers chipId(), and the tank is a contract. Wrong answers are configuration errors.
   */
  async preflight(): Promise<void> {
    let reachable = 0;
    for (const client of this.#pool.clients) {
      let id: number;
      try {
        id = await client.chainId();
      } catch (err) {
        this.#log.warn('rpc_unreachable', { rpc: client.label, error: message(err) });
        continue;
      }
      if (id !== this.#o.chainId) {
        throw new ConfigError(`RPC ${client.label} serves chain ${id}, expected ${this.#o.chainId}`);
      }
      reachable++;
    }
    if (reachable === 0) throw new RpcUnavailableError('no RPC endpoint answered eth_chainId');

    for (const kernel of this.#o.kernels) {
      if (!(await this.#pool.call('hasCode', (c) => c.hasCode(kernel)))) {
        throw new ConfigError(`KERNELS: ${kernel} has no contract code on chain ${this.#o.chainId}`);
      }
      let chipId: bigint;
      try {
        chipId = await this.#pool.call('chipId', (c) => c.chipId(kernel));
      } catch (err) {
        if (err instanceof RevertError) {
          throw new ConfigError(`KERNELS: ${kernel} is not a Covenant kernel (chipId() failed: ${err.reason})`);
        }
        throw err;
      }
      this.#state(kernel).chipId = chipId;
      this.#log.info('kernel_ok', { kernel, chipId });
    }

    const tank = this.#o.tank;
    if (tank && !(await this.#pool.call('hasCode', (c) => c.hasCode(tank)))) {
      throw new ConfigError(`TANK: ${tank} has no contract code on chain ${this.#o.chainId}`);
    }
  }

  /** One pass over every kernel. Kernels are handled one after another: the wallet has one nonce sequence. */
  async tick(): Promise<Outcome[]> {
    const outcomes: Outcome[] = [];
    for (const [i, kernel] of this.#o.kernels.entries()) {
      try {
        outcomes.push(await this.#process(kernel));
      } catch (err) {
        if (!(err instanceof RpcUnavailableError)) throw err;
        this.#log.error('rpc_unavailable', { kernel, error: err.message });
        // The other kernels would only wait through the same backoff again.
        for (const k of this.#o.kernels.slice(i)) outcomes.push({ kind: 'rpc_unavailable', kernel: k, error: err.message });
        break;
      }
    }
    return outcomes;
  }

  async #readView(kernel: Address): Promise<KernelView | { notReady: string }> {
    try {
      const view = await this.#pool.call('epochs', (c) => c.epochs(kernel));
      this.#state(kernel).view = view;
      return view;
    } catch (err) {
      if (err instanceof RevertError) return { notReady: err.reason };
      throw err;
    }
  }

  async #process(kernel: Address): Promise<Outcome> {
    const st = this.#state(kernel);

    let view = await this.#readView(kernel);
    if ('notReady' in view) {
      this.#note(kernel, `not_ready:${view.notReady}`, 'warn', 'kernel_not_ready', { reason: view.notReady });
      return { kind: 'not_ready', kernel, reason: view.notReady };
    }
    if (view.epochNow - view.lastEpoch < this.#o.minEpochLag) return this.#idle(kernel, view);

    // Rule 2: one send per kernel per epoch, whatever happened to that send.
    if (st.sentEpoch === view.epochNow) {
      this.#note(kernel, `already_sent:${view.epochNow}`, 'debug', 'already_sent_this_epoch', {
        epoch: view.epochNow,
        txHash: st.sentHash,
      });
      return { kind: 'already_sent', kernel, epoch: view.epochNow, txHash: st.sentHash };
    }

    // Rule 3: one transaction in flight per wallet.
    const slot = await this.#acquireSlot();
    if (slot.kind === 'wait') {
      this.#note(kernel, `waiting:${view.epochNow}:${slot.reason}`, 'info', 'waiting_for_pending_tx', {
        epoch: view.epochNow,
        reason: slot.reason,
        txHash: slot.txHash ?? null,
      });
      return { kind: 'waiting', kernel, epoch: view.epochNow, reason: slot.reason };
    }
    if (slot.stateChanged) {
      // A transaction of ours was just resolved: lastEpoch may have moved.
      view = await this.#readView(kernel);
      if ('notReady' in view) return { kind: 'not_ready', kernel, reason: view.notReady };
      if (view.epochNow - view.lastEpoch < this.#o.minEpochLag) return this.#idle(kernel, view);
      if (st.sentEpoch === view.epochNow) {
        return { kind: 'already_sent', kernel, epoch: view.epochNow, txHash: st.sentHash };
      }
    }
    const epoch = view.epochNow;

    const planned = await this.#plan(kernel, epoch, slot.floor);
    if ('kind' in planned) return planned;
    const plan = planned;

    const signer = this.#signer;
    if (this.#o.dryRun || !signer) {
      this.#note(kernel, `dry_run:${epoch}`, 'info', 'dry_run', {
        epoch,
        lastEpoch: view.lastEpoch,
        wouldSend: true,
        via: plan.target.via,
        from: this.#from,
        to: plan.target.to,
        data: plan.target.data,
        nonce: slot.nonce,
        gasEstimate: plan.estimate,
        minSettleGas: plan.minSettleGas,
        gasLimit: plan.gas,
        baseFeeWei: plan.baseFee,
        maxFeePerGasWei: plan.fees.maxFeePerGas,
        maxPriorityFeePerGasWei: plan.fees.maxPriorityFeePerGas,
        maxCostWei: plan.gas * plan.fees.maxFeePerGas,
        balanceWei: plan.balance,
        feesSimulated: plan.feesSimulated,
        tankFailure: plan.tankFailure,
      });
      return { kind: 'dry_run', kernel, epoch, via: plan.target.via, gas: plan.gas };
    }

    return this.#send(kernel, epoch, plan, slot, signer);
  }

  #idle(kernel: Address, view: KernelView): Outcome {
    this.#note(kernel, `idle:${view.epochNow}:${view.lastEpoch}`, this.#o.verboseIdle ? 'info' : 'debug', 'idle', {
      epochNow: view.epochNow,
      lastEpoch: view.lastEpoch,
      minEpochLag: this.#o.minEpochLag,
    });
    return { kind: 'idle', kernel, epochNow: view.epochNow, lastEpoch: view.lastEpoch };
  }

  /** Decide which nonce the next transaction may use, resolving whatever is still in flight first. */
  async #acquireSlot(): Promise<Slot> {
    let stateChanged = false;
    const inf = this.#inflight;
    if (inf) {
      const receipt = await this.#pool.call('receipt', (c) => c.receipt(inf.hash));
      if (receipt) {
        this.#finalize(inf, receipt);
        stateChanged = true;
      } else {
        const n = await this.#pool.call('nonces', (c) => c.nonces(this.#from));
        if (n.latest > inf.nonce) {
          // The nonce is used but our hash has no receipt: another transaction took the nonce.
          this.#log.warn('inflight_superseded', { kernel: inf.kernel, epoch: inf.epoch, txHash: inf.hash, nonce: inf.nonce });
          this.#inflight = null;
          stateChanged = true;
        } else if (this.#now() - inf.sentAt < this.#o.stuckTxMs) {
          return { kind: 'wait', reason: 'own_tx_pending', txHash: inf.hash };
        } else {
          return { kind: 'ready', nonce: inf.nonce, floor: bumpedFloor(inf.fees), replaces: inf.hash, stateChanged };
        }
      }
    }

    const n = await this.#pool.call('nonces', (c) => c.nonces(this.#from));
    if (n.pending > n.latest) {
      // The wallet has a transaction in the pool that this process did not send (another instance, or a
      // previous run of this one). Let it land; replace it only if it is stuck.
      this.#foreignSince ??= this.#now();
      if (this.#now() - this.#foreignSince < this.#o.stuckTxMs) return { kind: 'wait', reason: 'foreign_tx_pending' };
      this.#foreignBumps = Math.min(this.#foreignBumps + 1, 8);
      return { kind: 'ready', nonce: n.latest, floor: undefined, stateChanged, replaces: undefined };
    }
    this.#foreignSince = null;
    this.#foreignBumps = 0;
    return { kind: 'ready', nonce: n.latest, stateChanged };
  }

  async #plan(kernel: Address, epoch: number, floor: Fees | undefined): Promise<Plan | Outcome> {
    const baseFee = await this.#pool.call('baseFee', (c) => c.baseFee());

    // Replacing an unknown stuck transaction: we cannot see its fees, so escalate from our own.
    let effectiveFloor = floor;
    if (!effectiveFloor && this.#foreignBumps > 0) {
      const normal = feesFor(baseFee, this.#o.priorityFeePerGas, this.#o.maxFeePerGasCap);
      if (normal.ok) effectiveFloor = bumpedFloor(normal, this.#foreignBumps * 3);
    }

    const fee = feesFor(baseFee, this.#o.priorityFeePerGas, this.#o.maxFeePerGasCap, effectiveFloor);
    if (!fee.ok) {
      this.#note(kernel, `fee:${epoch}:${fee.reason}`, 'warn', 'fee_above_cap', {
        epoch,
        reason: fee.reason,
        baseFeeWei: fee.baseFee,
        neededWei: fee.needed,
        capWei: fee.cap,
      });
      return { kind: 'fee_above_cap', kernel, epoch };
    }
    const fees: Fees = { maxFeePerGas: fee.maxFeePerGas, maxPriorityFeePerGas: fee.maxPriorityFeePerGas };

    let minSettleGas: bigint;
    try {
      minSettleGas = await this.#pool.call('minSettleGas', (c) => c.minSettleGas(kernel));
    } catch (err) {
      if (!(err instanceof RevertError)) throw err;
      this.#note(kernel, `not_ready:${err.reason}`, 'warn', 'kernel_not_ready', { reason: err.reason });
      return { kind: 'not_ready', kernel, reason: err.reason };
    }

    const balance = await this.#pool.call('balance', (c) => c.balance(this.#from));
    // Pass the fee fields to the node only when the wallet covers the worst case. Otherwise the node
    // would cap the estimate by what the balance can buy and report a misleading failure.
    const feesSimulated = balance >= this.#o.maxGasLimit * fees.maxFeePerGas;
    const feeFields = feesSimulated ? fees : {};

    const targets: SettleTarget[] = [settleTarget(kernel, this.#o.tank)];
    if (this.#o.tank && this.#o.directFallback) targets.push(settleTarget(kernel, null));

    const failures: string[] = [];
    for (const target of targets) {
      try {
        const estimate = await this.#pool.call('estimateGas', (c) =>
          c.estimateGas({ from: this.#from, to: target.to, data: target.data, ...feeFields }),
        );
        const gas = gasLimitFor(estimate, minSettleGas);
        if (gas > this.#o.maxGasLimit) {
          this.#note(kernel, `gas:${epoch}`, 'error', 'gas_above_cap', {
            epoch,
            via: target.via,
            gasEstimate: estimate,
            minSettleGas,
            gasLimit: gas,
            maxGasLimit: this.#o.maxGasLimit,
          });
          return { kind: 'gas_above_cap', kernel, epoch };
        }
        if (!this.#o.dryRun && balance < gas * fees.maxFeePerGas) {
          this.#note(kernel, `balance:${epoch}`, 'error', 'insufficient_balance', {
            epoch,
            wallet: this.#from,
            balanceWei: balance,
            neededWei: gas * fees.maxFeePerGas,
          });
          return { kind: 'insufficient_balance', kernel, epoch };
        }
        // The decisive check: the same call, at the exact gas limit that would be sent.
        await this.#pool.call('simulate', (c) =>
          c.simulate({ from: this.#from, to: target.to, data: target.data, gas, ...feeFields }),
        );
        return {
          target,
          estimate,
          minSettleGas,
          gas,
          fees,
          baseFee,
          balance,
          feesSimulated,
          tankFailure: target.via === 'direct' && failures.length > 0 ? (failures[0] ?? null) : null,
        };
      } catch (err) {
        if (err instanceof InsufficientFundsError) {
          this.#note(kernel, `balance:${epoch}`, 'error', 'insufficient_balance', {
            epoch,
            wallet: this.#from,
            balanceWei: balance,
            error: err.message,
          });
          return { kind: 'insufficient_balance', kernel, epoch };
        }
        if (!(err instanceof RevertError)) throw err;
        failures.push(`${target.via}: ${err.reason}`);
      }
    }

    const reason = failures.join(' | ');
    this.#note(kernel, `sim:${epoch}:${reason}`, 'warn', 'settle_simulation_failed', { epoch, reason });
    return { kind: 'simulation_failed', kernel, epoch, reason };
  }

  async #send(
    kernel: Address,
    epoch: number,
    plan: Plan,
    slot: Extract<Slot, { kind: 'ready' }>,
    signer: Signer,
  ): Promise<Outcome> {
    const st = this.#state(kernel);
    const tx = {
      chainId: this.#o.chainId,
      to: plan.target.to,
      data: plan.target.data,
      value: 0n,
      gas: plan.gas,
      nonce: slot.nonce,
      maxFeePerGas: plan.fees.maxFeePerGas,
      maxPriorityFeePerGas: plan.fees.maxPriorityFeePerGas,
    };
    // Rule 5. Throws GuardError, which stops the process: a transaction that fails this check is a bug.
    assertSettleOnly(tx, {
      kernels: this.#o.kernels,
      tank: this.#o.tank,
      chainId: this.#o.chainId,
      maxGasLimit: this.#o.maxGasLimit,
      maxFeePerGasCap: this.#o.maxFeePerGasCap,
    });

    const raw = await signer.signTransaction({ ...tx, type: 'eip1559' });
    const hash = keccak256(raw);

    // Rule 2: recorded before the broadcast, so that no failure below can cause a second send this epoch.
    st.sentEpoch = epoch;
    st.sentHash = hash;
    try {
      this.#store.save(kernel, { epoch, txHash: hash });
    } catch (err) {
      // The memory above still covers this process; only a restart within this epoch would not know.
      this.#log.warn('state_not_saved', { kernel, epoch, error: message(err) });
    }
    const inflight: Inflight = {
      kernel,
      epoch,
      hash,
      raw,
      nonce: slot.nonce,
      fees: plan.fees,
      gas: plan.gas,
      via: plan.target.via,
      sentAt: this.#now(),
    };
    this.#inflight = inflight;
    this.#foreignSince = null;

    this.#log.info('settle_sent', {
      kernel,
      epoch,
      txHash: hash,
      via: plan.target.via,
      to: plan.target.to,
      nonce: slot.nonce,
      gasEstimate: plan.estimate,
      minSettleGas: plan.minSettleGas,
      gasLimit: plan.gas,
      maxFeePerGasWei: plan.fees.maxFeePerGas,
      maxPriorityFeePerGasWei: plan.fees.maxPriorityFeePerGas,
      feesSimulated: plan.feesSimulated,
      tankFailure: plan.tankFailure,
      replaces: slot.replaces ?? null,
    });

    try {
      // The same signed bytes go to every RPC the pool tries, so a retry can never create a second transaction.
      await this.#pool.call('sendRaw', (c) => c.sendRaw(raw));
    } catch (err) {
      if (err instanceof NonceTooLowError) {
        // Either these very bytes were mined after an earlier, apparently failed, broadcast, or another
        // instance used the nonce. A short receipt lookup tells the two apart.
        this.#log.warn('settle_nonce_too_low', { kernel, epoch, txHash: hash, nonce: slot.nonce });
        const outcome = await this.#awaitReceipt(inflight, Math.min(this.#o.receiptTimeoutMs, 5000), true);
        if (outcome.kind !== 'pending') return outcome;
        // Not ours: the nonce went to another transaction, so this one can never be mined.
        this.#inflight = null;
        return { kind: 'send_failed', kernel, epoch, reason: 'nonce_too_low' };
      } else if (err instanceof UnderpricedError || err instanceof InsufficientFundsError || err instanceof TxRejectedError) {
        this.#inflight = null;
        this.#log.error('settle_send_rejected', { kernel, epoch, txHash: hash, error: `${err.name}: ${err.message}` });
        return { kind: 'send_failed', kernel, epoch, reason: err.name };
      } else if (err instanceof RpcUnavailableError) {
        // Unknown whether any node took it. Keep tracking the hash; the next pass looks for its receipt.
        this.#log.error('settle_broadcast_uncertain', { kernel, epoch, txHash: hash, error: err.message });
        return { kind: 'send_failed', kernel, epoch, reason: 'rpc_unavailable' };
      } else {
        throw err;
      }
    }

    return this.#awaitReceipt(inflight);
  }

  async #awaitReceipt(inf: Inflight, timeoutMs = this.#o.receiptTimeoutMs, quiet = false): Promise<Outcome> {
    const deadline = this.#now() + timeoutMs;
    for (;;) {
      const receipt = await this.#pool.call('receipt', (c) => c.receipt(inf.hash));
      if (receipt) return this.#finalize(inf, receipt);
      if (this.#now() >= deadline) break;
      await this.#sleep(this.#o.receiptPollMs);
    }
    if (!quiet) {
      this.#log.warn('settle_pending', { kernel: inf.kernel, epoch: inf.epoch, txHash: inf.hash, waitedMs: timeoutMs });
    }
    return { kind: 'pending', kernel: inf.kernel, epoch: inf.epoch, txHash: inf.hash };
  }

  /** The one line per action: kernel, epoch, tx hash, gas used, and the refund when the tank logged one. */
  #finalize(inf: Inflight, receipt: Receipt): Outcome {
    if (this.#inflight?.hash === inf.hash) this.#inflight = null;
    const gasCost = receipt.gasUsed * receipt.effectiveGasPrice + receipt.l1Fee;

    if (receipt.status !== 'success') {
      this.#log.error('settle_reverted', {
        kernel: inf.kernel,
        epoch: inf.epoch,
        txHash: inf.hash,
        block: receipt.blockNumber,
        via: inf.via,
        gasUsed: receipt.gasUsed,
        gasLimit: inf.gas,
        gasCostWei: gasCost,
      });
      return { kind: 'reverted', kernel: inf.kernel, epoch: inf.epoch, txHash: inf.hash };
    }

    const settled = findSettled(receipt.logs, inf.kernel);
    const refund = inf.via === 'tank' && this.#o.tank ? this.#decodeRefund(receipt.logs, this.#o.tank) : null;
    const refundWei = refund ? refund.amount : null;
    const epoch = settled ? settled.epoch : inf.epoch;

    this.#log.info('settled', {
      kernel: inf.kernel,
      epoch,
      txHash: inf.hash,
      block: receipt.blockNumber,
      via: inf.via,
      gasUsed: receipt.gasUsed,
      gasLimit: inf.gas,
      effectiveGasPriceWei: receipt.effectiveGasPrice,
      gasCostWei: gasCost,
      refundWei,
      netCostWei: refundWei === null ? null : gasCost - refundWei,
      ...(settled
        ? {
            record: settled.n,
            clampBits: settled.clampBits,
            flags: settled.flags,
            inflow: settled.inflow,
            allow: settled.allow,
            buyDecided: settled.buyDecided,
            buyExecuted: settled.buyExecuted,
          }
        : { record: null }),
    });
    if (!settled) {
      // The transaction succeeded but the kernel logged no Settled event this keeper can decode. Either the
      // kernel declares the event differently, or the settle did not happen (a tank that swallows a failed
      // inner call). Compare lastEpoch() on chain; this epoch is not retried either way.
      this.#log.warn('settled_event_not_found', { kernel: inf.kernel, epoch: inf.epoch, txHash: inf.hash });
    }
    if (inf.via === 'tank' && refundWei === null) {
      this.#log.warn('refund_event_not_found', {
        kernel: inf.kernel,
        txHash: inf.hash,
        hint: 'no log from TANK matched TANK_REFUNDED_EVENT (allowance exhausted, or the event is declared differently)',
      });
    }
    return { kind: 'settled', kernel: inf.kernel, epoch, txHash: inf.hash, gasUsed: receipt.gasUsed, refundWei };
  }

  async #tankRemaining(chipId: bigint | null): Promise<bigint | null> {
    const tank = this.#o.tank;
    if (!tank || chipId === null) return null;
    try {
      return await this.#pool.call('tankRemaining', (c) => c.tankRemaining(tank, chipId));
    } catch (err) {
      if (err instanceof RevertError) return null; // a tank without remainingOf(): not worth more than a null
      throw err;
    }
  }

  /** Periodic liveness line with the wallet balance. Failures here never stop the keeper. */
  async heartbeat(force = false): Promise<void> {
    const now = this.#now();
    if (!force && this.#lastHeartbeat !== null && now - this.#lastHeartbeat < this.#o.heartbeatMs) return;
    this.#lastHeartbeat = now;
    try {
      const balance = await this.#pool.call('balance', (c) => c.balance(this.#from));
      const kernels = [];
      for (const kernel of this.#o.kernels) {
        const st = this.#state(kernel);
        kernels.push({
          kernel,
          epochNow: st.view?.epochNow ?? null,
          lastEpoch: st.view?.lastEpoch ?? null,
          sentEpoch: st.sentEpoch,
          // What the tank can still refund for this chip. When it reaches zero, settles go on unrefunded.
          tankRemainingWei: await this.#tankRemaining(st.chipId),
        });
      }
      this.#log.info('heartbeat', {
        wallet: this.#from,
        balanceWei: balance,
        rpc: this.#pool.current.label,
        dryRun: this.#o.dryRun,
        inflight: this.#inflight?.hash ?? null,
        kernels,
      });
      if (this.#signer && balance < this.#o.minBalanceWei) {
        this.#log.warn('low_balance', { wallet: this.#from, balanceWei: balance, thresholdWei: this.#o.minBalanceWei });
      }
    } catch (err) {
      this.#log.warn('heartbeat_failed', { error: message(err) });
    }
  }
}
