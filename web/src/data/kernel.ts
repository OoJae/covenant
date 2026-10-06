// What the kernel pages read from X Layer. eth_call and eth_getCode only; nothing here can send a transaction.
// History comes from records(n) by eth_call, never from logs: the public nodes cap eth_getLogs at 100 blocks.
// Free of any DOM, so the tests and the terminal scripts run the same functions as the pages.

import { blockNumber, CallError, MULTICALL3, processor, read, readAll, toBytes, type Rpc } from '@covenant/chain';
import { checksumAddress, keccak256Hex } from '@covenant/chain/keccak';
import {
  beaconImpl,
  decEnvelope,
  decGlobals,
  erc20,
  fab,
  fabSnapshot,
  ignix,
  kernel,
  kernelFactory,
  lens,
  multicallViews,
  SHADOW_START,
  type CfCursor,
  type Counterfactual,
  type CurveToken,
  type Envelope,
  type Globals,
  type KernelRecord,
  type Replay,
  type ShadowCursor,
  type ShadowStep,
  type StateMatters,
} from '@covenant/chain/kernel';
import { cloneOf, scanCode, type CloneCheck, type CodeScan } from '../kernel/code.ts';
import { Missing } from './processor.ts';

const ZERO = '0x0000000000000000000000000000000000000000';
const ok = <T>(v: T | Error): T | null => (v instanceof Error ? null : v);
const same = (a: string | null | undefined, b: string | null | undefined): boolean => !!a && !!b && a.toLowerCase() === b.toLowerCase();
const nonZero = (a: string | null): string | null => (a && !same(a, ZERO) ? checksumAddress(a) : null);

export interface TokenInfo {
  address: string;
  name: string | null;
  symbol: string | null;
  decimals: number;
  totalSupply: bigint | null;
  /** IgnixToken.pair(): non-zero once the token has graduated. */
  pair: string | null;
}

export interface VaultData {
  kernel: string;
  block: bigint | null;
  /** Chain time of that block (Multicall3 getCurrentBlockTimestamp). */
  time: number | null;
  /** When this machine received the answer, to run the epoch clock between reads. */
  readAt: number;
  globals: Globals;
  envelope: Envelope;
  /** The kernel's own factory says it created this kernel. */
  isKernel: boolean | null;
  /** That factory is the one deployments/xlayer.json names. */
  ourFactory: boolean;
  token: TokenInfo | null;
  vault: string | null;
  count: number;
  state: string;
  epochNow: number;
  lastEpoch: number;
  lastStepEpoch: number;
  bindTime: number;
  reserve: bigint;
  lockedTokens: bigint;
  burnedTokens: bigint;
  graduated: boolean;
  pair: string | null;
  evaluator: { vm: string; sealedMode: boolean } | null;
  minSettleGas: bigint | null;
  cumInflow: bigint;
  allowPaidCum: bigint;
  tokenSupply: bigint;
  /** Native OKB the kernel holds (reserve, credits, and on-curve the decided-but-unexecuted buys). */
  okb: bigint | null;
  /** Circuits.ownerOf(chipId). */
  chipOwner: string | null;
  /** KernelFactory.pinsLive(): TapeOut's implementation is still the one pinned. */
  pinsLive: boolean | null;
  /** The factory's Kernel implementation, and the beacon's implementation now. */
  factoryImpl: string | null;
  beaconNow: string | null;
  vaultRecipient: string | null;
  vaultToken: string | null;
  vaultQuote: string | null;
  /** IgnixManager.vaultOf(token). */
  managerVault: string | null;
  /** OKB waiting in the vault: tax not yet claimed. */
  vaultOkb: bigint | null;
  curve: CurveToken | null;
  /** Allowance credited to the payee and not yet withdrawn, in OKB and in tokens. */
  creditOkb: bigint | null;
  creditToken: bigint | null;
  kernelTokens: bigint | null;
  clone: CloneCheck;
  /** The immutable arguments in the code equal what globals() and envelope() return. */
  argsMatch: boolean;
  implScan: CodeScan | null;
  implementation: string | null;
}

/** Everything the vault page shows, in three round trips: kernel views, dependent reads, code. */
export async function loadVault(rpc: Rpc, address: string, factoryAddress: string | null): Promise<VaultData> {
  const k = kernel(address);
  const m = multicallViews(MULTICALL3);
  const first = await readAll(rpc, [
    k.globals(),
    k.envelope(),
    k.token(),
    k.vault(),
    k.count(),
    k.state(),
    k.epochNow(),
    k.lastEpoch(),
    k.lastStepEpoch(),
    k.bindTime(),
    k.reserve(),
    k.lockedTokens(),
    k.burnedTokens(),
    k.graduated(),
    k.pair(),
    k.evaluator(),
    k.minSettleGas(),
    k.cumInflow(),
    k.allowPaidCum(),
    k.tokenSupply(),
    m.ethBalance(address),
    m.timestamp(),
    blockNumber(),
  ] as const);
  const [globals, envelope, token, vault, count] = first;
  if (globals instanceof Error || envelope instanceof Error || count instanceof Error) {
    const e = [globals, envelope, count].find((v) => v instanceof Error) as Error;
    if (!(e instanceof CallError)) throw e;
    throw new Missing(`${address} does not answer like a Covenant kernel (${e.message})`);
  }
  const [, , , , , state, epochNow, lastEpoch, lastStepEpoch, bindTime, reserve, locked, burned, graduated, pair, evaluator, minGas, cumInflow, allowPaidCum, supply, okb, time, block] = first;
  const tok = nonZero(ok(token));
  const vlt = nonZero(ok(vault));
  const f = kernelFactory(globals.factory);
  const calls = [
    f.isKernel(address),
    f.pinsLive(),
    f.kernelImpl(),
    beaconImpl(globals.beacon),
    processor(globals.circuits).ownerOf(globals.chipId),
  ] as const;
  const tokenCalls = tok
    ? ([
        erc20(tok).name(),
        erc20(tok).symbol(),
        erc20(tok).decimals(),
        erc20(tok).totalSupply(),
        erc20(tok).pair(),
        ignix.vaultOf(globals.manager, tok),
        ignix.tokens(globals.manager, tok),
        kernel(address).creditOf(envelope.allowancePayee, ZERO),
        kernel(address).creditOf(envelope.allowancePayee, tok),
        erc20(tok).balanceOf(address),
      ] as const)
    : null;
  const vaultCalls = vlt ? ([ignix.recipient(vlt), ignix.vaultToken(vlt), ignix.vaultQuote(vlt), m.ethBalance(vlt)] as const) : null;
  const [second, third, fourth, codes] = await Promise.all([
    readAll(rpc, calls),
    tokenCalls ? readAll(rpc, tokenCalls) : Promise.resolve(null),
    vaultCalls ? readAll(rpc, vaultCalls) : Promise.resolve(null),
    rpc.batch([['eth_getCode', [address, 'latest']]]),
  ]);
  const [isKernel, pinsLive, factoryImpl, beaconNow, chipOwner] = second;
  const code = typeof codes[0] === 'string' ? (codes[0] as string) : '0x';
  const clone = cloneOf(code);
  let argsMatch = false;
  if (clone.isClone) {
    try {
      const a = clone.args.slice(2);
      argsMatch = JSON.stringify(decGlobals(a.slice(0, 18 * 64)), big) === JSON.stringify(globals, big) && JSON.stringify(decEnvelope(a.slice(18 * 64)), big) === JSON.stringify(envelope, big) && a.length === 32 * 64;
    } catch {
      argsMatch = false;
    }
  }
  let implScan: CodeScan | null = null;
  if (clone.implementation) {
    const [implCode] = await rpc.batch([['eth_getCode', [clone.implementation, 'latest']]]);
    if (typeof implCode === 'string' && implCode.length > 2) implScan = scanCode(implCode);
  }
  return {
    kernel: checksumAddress(address),
    block: ok(block),
    time: ok(time),
    readAt: Date.now(),
    globals,
    envelope,
    isKernel: ok(isKernel),
    ourFactory: same(globals.factory, factoryAddress),
    token: tok
      ? {
          address: tok,
          name: third ? ok(third[0]) : null,
          symbol: third ? ok(third[1]) : null,
          decimals: (third && ok(third[2])) ?? 18,
          totalSupply: third ? ok(third[3]) : null,
          pair: third ? nonZero(ok(third[4])) : null,
        }
      : null,
    vault: vlt,
    count,
    state: ok(state) ?? '0x' + '00'.repeat(32),
    epochNow: ok(epochNow) ?? 0,
    lastEpoch: ok(lastEpoch) ?? 0,
    lastStepEpoch: ok(lastStepEpoch) ?? 0,
    bindTime: ok(bindTime) ?? 0,
    reserve: ok(reserve) ?? 0n,
    lockedTokens: ok(locked) ?? 0n,
    burnedTokens: ok(burned) ?? 0n,
    graduated: ok(graduated) ?? false,
    pair: nonZero(ok(pair)),
    evaluator: ok(evaluator),
    minSettleGas: ok(minGas),
    cumInflow: ok(cumInflow) ?? 0n,
    allowPaidCum: ok(allowPaidCum) ?? 0n,
    tokenSupply: ok(supply) ?? 0n,
    okb: ok(okb),
    chipOwner: nonZero(ok(chipOwner)),
    pinsLive: ok(pinsLive),
    factoryImpl: nonZero(ok(factoryImpl)),
    beaconNow: nonZero(ok(beaconNow)),
    vaultRecipient: fourth ? nonZero(ok(fourth[0])) : null,
    vaultToken: fourth ? nonZero(ok(fourth[1])) : null,
    vaultQuote: fourth ? ok(fourth[2]) : null,
    managerVault: third ? nonZero(ok(third[5])) : null,
    vaultOkb: fourth ? ok(fourth[3]) : null,
    curve: third ? ok(third[6]) : null,
    creditOkb: third ? ok(third[7]) : null,
    creditToken: third ? ok(third[8]) : null,
    kernelTokens: third ? ok(third[9]) : null,
    clone,
    argsMatch,
    implScan,
    implementation: clone.implementation ? checksumAddress(clone.implementation) : null,
  };
}

const big = (_: string, v: unknown): unknown => (typeof v === 'bigint' ? v.toString() : typeof v === 'string' ? v.toLowerCase() : v);

export interface RecordRow {
  n: number;
  rec: KernelRecord;
  /** Regime totals after this settle. */
  cumInflow: bigint;
  allowPaidCum: bigint;
  /** The state the chip was stepped from: the previous record's stateAfter (zero for n = 1). */
  stateBefore: string;
}

/** Records from..to (1-indexed, inclusive) with their totals, and the state each was stepped from. */
export async function loadRecords(rpc: Rpc, address: string, from: number, to: number): Promise<RecordRow[]> {
  if (to < from) return [];
  const k = kernel(address);
  const calls = [];
  const lo = Math.max(1, from - 1);
  for (let n = lo; n <= to; n++) calls.push(k.records(n), k.cums(n));
  const out = await readAll(rpc, calls);
  const rows: RecordRow[] = [];
  let prevState = '0x' + '00'.repeat(32);
  for (let n = lo; n <= to; n++) {
    const rec = out[2 * (n - lo)];
    const cum = out[2 * (n - lo) + 1];
    if (rec instanceof Error) throw rec;
    if (cum instanceof Error) throw cum;
    const r = rec as KernelRecord;
    const c = cum as { cumInflow: bigint; allowPaidCum: bigint };
    if (n >= from) rows.push({ n, rec: r, cumInflow: c.cumInflow, allowPaidCum: c.allowPaidCum, stateBefore: n === 1 ? '0x' + '00'.repeat(32) : prevState });
    prevState = r.stateAfter;
  }
  return rows;
}

/** Lens.counterfactual over records 1..count, paged so that no eth_call grows too large. */
export async function loadCounterfactual(rpc: Rpc, lensAddress: string, address: string, count: number, page: number = 400): Promise<{ curve: Counterfactual; graduated: Counterfactual } | null> {
  if (count === 0) return null;
  const L = lens(lensAddress);
  let cursor: CfCursor = { reserve: 0n, allowPaid: 0n, grad: false };
  let acc: { curve: Counterfactual; graduated: Counterfactual } | null = null;
  for (let from = 1; from <= count; from += page) {
    const to = Math.min(count, from + page - 1);
    const r = await read(rpc, from === 1 ? L.counterfactual(address, from, to) : L.counterfactualFrom(address, from, to, cursor));
    cursor = r.next;
    acc = acc ? { curve: addCf(acc.curve, r.curve), graduated: addCf(acc.graduated, r.graduated) } : { curve: r.curve, graduated: r.graduated };
  }
  return acc;
}

function addCf(a: Counterfactual, b: Counterfactual): Counterfactual {
  const t = (x: Counterfactual['chip'], y: Counterfactual['chip']) => ({
    inflow: x.inflow + y.inflow,
    allow: x.allow + y.allow,
    buy: x.buy + y.buy,
    reserveEnd: y.inflow > 0n || y.buy > 0n ? y.reserveEnd : x.reserveEnd,
  });
  return { chip: t(a.chip, b.chip), chipBuyExecuted: a.chipBuyExecuted + b.chipBuyExecuted, fixedSplit: t(a.fixedSplit, b.fixedSplit), alwaysBuy: t(a.alwaysBuy, b.alwaysBuy) };
}

/** The chip's netlist as TapeOut stores it, with the Fab's snapshot as the fallback when TapeOut cannot be read. */
export async function loadNetlist(rpc: Rpc, g: Globals): Promise<{ bytes: Uint8Array; keccak: string; source: 'tapeout' | 'fab' }> {
  const [a, b] = await readAll(rpc, [processor(g.circuits).netlist(g.chipId), fabSnapshot(g.fab, g.chipId)] as const);
  for (const [v, source] of [
    [a, 'tapeout'],
    [b, 'fab'],
  ] as const) {
    if (v instanceof Error) continue;
    const bytes = toBytes(v);
    if (bytes.length > 0) return { bytes, keccak: keccak256Hex(bytes), source };
  }
  throw new Error(`the netlist of chip ${g.chipId} could not be read from TapeOut or from the Fab`);
}

export interface AuditData {
  row: RecordRow;
  count: number;
  globals: Globals;
  envelope: Envelope;
  replayTapeout: Replay | Error;
  replaySealed: Replay | Error;
  stateMatters: StateMatters | Error;
}

/** Record n with everything needed to recompute it, and the Lens's three answers about it. */
export async function loadAudit(rpc: Rpc, lensAddress: string, address: string, n: number): Promise<AuditData> {
  const k = kernel(address);
  const [g, e, count] = await readAll(rpc, [k.globals(), k.envelope(), k.count()] as const);
  if (g instanceof Error || e instanceof Error || count instanceof Error) {
    const err = [g, e, count].find((v) => v instanceof Error) as Error;
    if (!(err instanceof CallError)) throw err;
    throw new Missing(`${address} does not answer like a Covenant kernel (${err.message})`);
  }
  if (n < 1 || n > count) throw new Missing(`kernel ${address} has ${count} record${count === 1 ? '' : 's'}; there is no record ${n}`);
  const rows = await loadRecords(rpc, address, n, n);
  const L = lens(lensAddress);
  const settle = <T>(p: Promise<T>): Promise<T | Error> => p.catch((x: unknown) => (x instanceof Error ? x : new Error(String(x))));
  // Direct calls, exactly what the printed cast lines ask.
  const [replayTapeout, replaySealed, stateMatters] = await Promise.all([settle(read(rpc, L.replayOn(address, n, false))), settle(read(rpc, L.replayOn(address, n, true))), settle(read(rpc, L.stateMatters(address, n)))]);
  return { row: rows[0], count, globals: g, envelope: e, replayTapeout, replaySealed, stateMatters };
}

/** Lens.shadowChip over records 1..count for another chip on the same processor, all pages. */
export async function loadShadowChip(rpc: Rpc, lensAddress: string, address: string, chipId: number, count: number): Promise<ShadowStep[]> {
  const L = lens(lensAddress);
  const steps: ShadowStep[] = [];
  let cur: ShadowCursor = SHADOW_START;
  let from = 1;
  while (from <= count) {
    const page = await read(rpc, L.shadowChip(address, chipId, from, count, cur));
    if (page.steps.length === 0) throw new Error('Lens.shadowChip made no progress');
    steps.push(...page.steps);
    cur = page.next;
    from = page.nextN;
  }
  return steps;
}

/** Fab facts about a chip id: whether the Fab taped it out, its snapshot and hashes. */
export async function loadChipFacts(rpc: Rpc, fabAddress: string, id: number) {
  const [isChip, info] = await readAll(rpc, [fab(fabAddress).isChip(id), fab(fabAddress).chipInfo(id)] as const);
  return { isChip: ok(isChip), info: ok(info) };
}
