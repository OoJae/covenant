// What the kernel pages read from X Layer. eth_call and eth_getCode only; nothing here can send a transaction.
// History comes from records(n) by eth_call, never from logs: the public nodes cap eth_getLogs at 100 blocks.
// Free of any DOM, so the tests and the terminal scripts run the same functions as the pages.

import { blockNumber, CallError, MULTICALL3, processor, read, readAll, toBytes, type Rpc } from '@covenant/chain';
import { checksumAddress, keccak256Hex } from '@covenant/chain/keccak';
import {
  beaconImpl,
  decEnvelope,
  decGlobals,
  decGlobalsV2,
  erc20,
  fab,
  fabSnapshot,
  ignix,
  kernel,
  kernelFactory,
  kernelFactoryV2,
  kernelV2,
  lens,
  multicallViews,
  SHADOW_START,
  tether,
  type CfCursor,
  type Counterfactual,
  type CurveToken,
  type Envelope,
  type Globals,
  type GlobalsV2,
  type KernelRecord,
  type KernelRecordV2,
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
/** The same call, answering the raw return data: decoded once the kernel's version is known. */
const raw = <T>(c: { to: string; data: string; decode: (r: string) => T }) => ({ to: c.to, data: c.data, decode: (r: string): string => r });

// ----------------------------------------------------------------------------------------------- kernel v1 or v2

/** The Covenant contracts the data path needs: COVENANT in config.ts (a plain object here, for the tests). */
export interface Known {
  kernelFactory: string | null;
  lens: string | null;
  kernelFactoryV2: string | null;
  lensV2: string | null;
}

/** A record of either kernel. Only the last field differs: `nativeIn` (OKB, v1) or `quoteIn` (USD₮0, v2). */
export type AnyRecord = KernelRecord | KernelRecordV2;
export type AnyGlobals = Globals | GlobalsV2;

/** What the post-graduation quote leg spent: native OKB on kernel v1, USD₮0 on kernel v2. */
export const quoteLegIn = (r: AnyRecord): bigint => ('quoteIn' in r ? r.quoteIn : r.nativeIn);

/** Which kernel an address is, and the unit of its curve regime. */
export interface KernelKind {
  /** 1: kernel v1 (native OKB quote). 2: kernel v2 (USD₮0 quote, chips/INTERFACE-V2.md). */
  version: 1 | 2;
  /** How the version was decided: one of the factories deployments/xlayer.json names says it created this kernel,
   *  or (neither does) by shape: a v2 kernel answers quoteShift(). */
  by: 'factory v1' | 'factory v2' | 'shape';
  /** Code shift in bits on the curve: 0 on kernel v1, quoteShift() on kernel v2 (33 for USD₮0). */
  shift: number;
  /** The curve's quote asset: null for native OKB, the ERC-20 (USD₮0) on kernel v2. */
  quote: string | null;
  quoteSymbol: string;
  quoteDecimals: number;
  /** The Lens for this kernel's factory: LensV2 answers only for kernels KernelFactoryV2 created, and the v1 Lens only
   *  for kernel v1's. Null when the factory is not one of ours. */
  lens: string | null;
  /** The factory deployments/xlayer.json names for this version. */
  factory: string | null;
}

/**
 * Decides v1 or v2 by asking each known factory `isKernel(address)`; when neither created it, by whether it answers
 * quoteShift(). `isV1`/`isV2` are null when that factory is not deployed.
 */
export function kindOf(known: Known, isV1: boolean | Error | null, isV2: boolean | Error | null, shift: number | Error, quote: string | Error): Omit<KernelKind, 'quoteSymbol' | 'quoteDecimals'> {
  const v2 = isV2 === true || (isV1 !== true && typeof shift === 'number');
  const by = isV2 === true ? 'factory v2' : isV1 === true ? 'factory v1' : 'shape';
  if (!v2) return { version: 1, by, shift: 0, quote: null, lens: by === 'factory v1' ? known.lens : null, factory: known.kernelFactory };
  return {
    version: 2,
    by,
    shift: typeof shift === 'number' ? shift : 0,
    quote: typeof quote === 'string' ? checksumAddress(quote) : null,
    lens: by === 'factory v2' ? known.lensV2 : null,
    factory: known.kernelFactoryV2,
  };
}

/** The calls that decide the version, in one batch with whatever else the caller reads. */
function detectCalls(known: Known, address: string) {
  const none = { to: MULTICALL3, data: '0x0f28c97d', decode: (): null => null }; // getCurrentBlockTimestamp, ignored
  return [
    known.kernelFactory ? kernelFactory(known.kernelFactory).isKernel(address) : none,
    known.kernelFactoryV2 ? kernelFactoryV2(known.kernelFactoryV2).isKernel(address) : none,
    kernelV2(address).quoteShift(),
    kernelV2(address).quote(),
  ] as const;
}

const OKB_KIND = { quoteSymbol: 'OKB', quoteDecimals: 18 };

/** Symbol and decimals of a v2 kernel's quote (USD₮0, 6 decimals: the factory refuses any other decimals). */
async function quoteUnit(rpc: Rpc, quote: string | null): Promise<{ quoteSymbol: string; quoteDecimals: number }> {
  if (!quote) return { quoteSymbol: 'USD₮0', quoteDecimals: 6 };
  const [sym, dec] = await readAll(rpc, [erc20(quote).symbol(), erc20(quote).decimals()] as const);
  return { quoteSymbol: ok(sym) ?? 'USD₮0', quoteDecimals: ok(dec) ?? 6 };
}

/** Just the kind of a kernel: one batch, plus the quote's symbol and decimals for a v2 kernel. */
export async function detectKernel(rpc: Rpc, known: Known, address: string): Promise<KernelKind> {
  const [isV1, isV2, shift, quote] = await readAll(rpc, detectCalls(known, address));
  const k = kindOf(known, isV1, isV2, shift, quote);
  return { ...k, ...(k.version === 2 ? await quoteUnit(rpc, k.quote) : OKB_KIND) };
}

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
  /** Kernel v1 (OKB quote) or v2 (USD₮0 quote), and the units of its curve regime. */
  kind: KernelKind;
  block: bigint | null;
  /** Chain time of that block (Multicall3 getCurrentBlockTimestamp). */
  time: number | null;
  /** When this machine received the answer, to run the epoch clock between reads. */
  readAt: number;
  globals: AnyGlobals;
  envelope: Envelope;
  /** The kernel's own factory (globals().factory) says it created this kernel. */
  isKernel: boolean | null;
  /** That factory is the one deployments/xlayer.json names for this version. */
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
  /** The quote asset the kernel holds (native OKB on v1, USD₮0 on v2): reserve, credits, and on the curve any
   *  inflow not yet settled (on v2 that includes revenue paid to the kernel since the last settle). */
  quoteHeld: bigint | null;
  /** totalCredits(quote): allowance credited and not yet withdrawn, in the quote asset. */
  quoteCredits: bigint | null;
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
  /** The quote asset waiting in the vault: tax not yet claimed (OKB on v1, USD₮0 on v2). */
  vaultQuoteHeld: bigint | null;
  curve: CurveToken | null;
  /** Allowance credited to the payee and not yet withdrawn, in the quote asset and in tokens. */
  creditQuote: bigint | null;
  creditToken: bigint | null;
  kernelTokens: bigint | null;
  /** Kernel v2 only, read now: USD₮0.isBlocked(kernel), and the USD₮0 allowance it has left to the IgnixManager and
   *  to the router (the kernel approves exactly one buy and resets it in the same settle; both should be 0). */
  quoteBlocked: boolean | null;
  allowanceToManager: bigint | null;
  allowanceToRouter: bigint | null;
  clone: CloneCheck;
  /** The immutable arguments in the code equal what globals() and envelope() return. */
  argsMatch: boolean;
  implScan: CodeScan | null;
  implementation: string | null;
}

/** Everything the vault page shows, in three round trips: kernel views, dependent reads, code. */
export async function loadVault(rpc: Rpc, address: string, known: Known): Promise<VaultData> {
  const k = kernel(address);
  const m = multicallViews(MULTICALL3);
  const first = await readAll(rpc, [
    raw(k.globals()),
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
    ...detectCalls(known, address),
  ] as const);
  const [globalsRaw, envelope, token, vault, count] = first;
  if (globalsRaw instanceof Error || envelope instanceof Error || count instanceof Error) {
    const e = [globalsRaw, envelope, count].find((v) => v instanceof Error) as Error;
    if (!(e instanceof CallError)) throw e;
    throw new Missing(`${address} does not answer like a Covenant kernel (${e.message})`);
  }
  const [, , , , , state, epochNow, lastEpoch, lastStepEpoch, bindTime, reserve, locked, burned, graduated, pair, evaluator, minGas, cumInflow, allowPaidCum, supply, okb, time, block, isV1, isV2, shiftAns, quoteAns] = first;
  const kind0 = kindOf(known, isV1, isV2, shiftAns, quoteAns);
  const v2 = kind0.version === 2;
  let globals: AnyGlobals;
  try {
    globals = v2 ? decGlobalsV2(globalsRaw) : decGlobals(globalsRaw);
  } catch (e) {
    throw new Missing(`${address} does not answer like a Covenant kernel v${kind0.version} (${(e as Error).message})`);
  }
  const quote = v2 ? (globals as GlobalsV2).quote : null;
  const qAsset = quote ?? ZERO; // credits in native OKB are keyed by the zero address
  const tok = nonZero(ok(token));
  const vlt = nonZero(ok(vault));
  const f = kernelFactory(globals.factory);
  const calls = [
    f.isKernel(address),
    f.pinsLive(),
    f.kernelImpl(),
    beaconImpl(globals.beacon),
    processor(globals.circuits).ownerOf(globals.chipId),
    kernel(address).totalCredits(qAsset),
  ] as const;
  const v2Calls = quote
    ? ([erc20(quote).balanceOf(address), tether(quote).isBlocked(address), erc20(quote).allowance(address, globals.manager), erc20(quote).allowance(address, globals.v2Router), erc20(quote).symbol(), erc20(quote).decimals()] as const)
    : null;
  const tokenCalls = tok
    ? ([
        erc20(tok).name(),
        erc20(tok).symbol(),
        erc20(tok).decimals(),
        erc20(tok).totalSupply(),
        erc20(tok).pair(),
        ignix.vaultOf(globals.manager, tok),
        ignix.tokens(globals.manager, tok),
        kernel(address).creditOf(envelope.allowancePayee, qAsset),
        kernel(address).creditOf(envelope.allowancePayee, tok),
        erc20(tok).balanceOf(address),
      ] as const)
    : null;
  const vaultCalls = vlt ? ([ignix.recipient(vlt), ignix.vaultToken(vlt), ignix.vaultQuote(vlt), quote ? erc20(quote).balanceOf(vlt) : m.ethBalance(vlt)] as const) : null;
  const [second, third, fourth, fifth, codes] = await Promise.all([
    readAll(rpc, calls),
    tokenCalls ? readAll(rpc, tokenCalls) : Promise.resolve(null),
    vaultCalls ? readAll(rpc, vaultCalls) : Promise.resolve(null),
    v2Calls ? readAll(rpc, v2Calls) : Promise.resolve(null),
    rpc.batch([['eth_getCode', [address, 'latest']]]),
  ]);
  const [isKernel, pinsLive, factoryImpl, beaconNow, chipOwner, quoteCredits] = second;
  const code = typeof codes[0] === 'string' ? (codes[0] as string) : '0x';
  const clone = cloneOf(code);
  let argsMatch = false;
  if (clone.isClone) {
    // abi.encode(globals, envelope): 18 + 14 words on kernel v1, 19 + 14 on kernel v2
    const gWords = v2 ? 19 : 18;
    try {
      const a = clone.args.slice(2);
      const g2 = v2 ? decGlobalsV2(a.slice(0, gWords * 64)) : decGlobals(a.slice(0, gWords * 64));
      argsMatch = JSON.stringify(g2, big) === JSON.stringify(globals, big) && JSON.stringify(decEnvelope(a.slice(gWords * 64)), big) === JSON.stringify(envelope, big) && a.length === (gWords + 14) * 64;
    } catch {
      argsMatch = false;
    }
  }
  let implScan: CodeScan | null = null;
  if (clone.implementation) {
    const [implCode] = await rpc.batch([['eth_getCode', [clone.implementation, 'latest']]]);
    if (typeof implCode === 'string' && implCode.length > 2) implScan = scanCode(implCode);
  }
  const kind: KernelKind = { ...kind0, ...(v2 ? { quoteSymbol: (fifth && ok(fifth[4])) ?? 'USD₮0', quoteDecimals: (fifth && ok(fifth[5])) ?? 6 } : OKB_KIND) };
  return {
    kernel: checksumAddress(address),
    kind,
    block: ok(block),
    time: ok(time),
    readAt: Date.now(),
    globals,
    envelope,
    isKernel: ok(isKernel),
    ourFactory: same(globals.factory, kind.factory),
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
    quoteHeld: v2 ? (fifth ? ok(fifth[0]) : null) : ok(okb),
    quoteCredits: ok(quoteCredits),
    chipOwner: nonZero(ok(chipOwner)),
    pinsLive: ok(pinsLive),
    factoryImpl: nonZero(ok(factoryImpl)),
    beaconNow: nonZero(ok(beaconNow)),
    vaultRecipient: fourth ? nonZero(ok(fourth[0])) : null,
    vaultToken: fourth ? nonZero(ok(fourth[1])) : null,
    vaultQuote: fourth ? ok(fourth[2]) : null,
    managerVault: third ? nonZero(ok(third[5])) : null,
    vaultQuoteHeld: fourth ? ok(fourth[3]) : null,
    curve: third ? ok(third[6]) : null,
    creditQuote: third ? ok(third[7]) : null,
    creditToken: third ? ok(third[8]) : null,
    kernelTokens: third ? ok(third[9]) : null,
    quoteBlocked: fifth ? ok(fifth[1]) : null,
    allowanceToManager: fifth ? ok(fifth[2]) : null,
    allowanceToRouter: fifth ? ok(fifth[3]) : null,
    clone,
    argsMatch,
    implScan,
    implementation: clone.implementation ? checksumAddress(clone.implementation) : null,
  };
}

const big = (_: string, v: unknown): unknown => (typeof v === 'bigint' ? v.toString() : typeof v === 'string' ? v.toLowerCase() : v);

export interface RecordRow {
  n: number;
  rec: AnyRecord;
  /** Regime totals after this settle. */
  cumInflow: bigint;
  allowPaidCum: bigint;
  /** The state the chip was stepped from: the previous record's stateAfter (zero for n = 1). */
  stateBefore: string;
}

/** Records from..to (1-indexed, inclusive) with their totals, and the state each was stepped from. A v2 kernel's
 *  records carry `quoteIn` where kernel v1's carry `nativeIn`; pass its version. */
export async function loadRecords(rpc: Rpc, address: string, from: number, to: number, version: 1 | 2 = 1): Promise<RecordRow[]> {
  if (to < from) return [];
  const k = version === 2 ? kernelV2(address) : kernel(address);
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
    const r = rec as AnyRecord;
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
export async function loadNetlist(rpc: Rpc, g: Pick<Globals, 'circuits' | 'fab' | 'chipId'>): Promise<{ bytes: Uint8Array; keccak: string; source: 'tapeout' | 'fab' }> {
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
  kind: KernelKind;
  row: RecordRow;
  count: number;
  globals: AnyGlobals;
  envelope: Envelope;
  replayTapeout: Replay | Error;
  replaySealed: Replay | Error;
  stateMatters: StateMatters | Error;
}

/**
 * Record n with everything needed to recompute it, and the Lens's three answers about it. The Lens is the one of the
 * kernel's own factory (kernel v1's Lens or LensV2: each answers only for its factory's kernels).
 */
export async function loadAudit(rpc: Rpc, known: Known, address: string, n: number): Promise<AuditData> {
  const k = kernel(address);
  const [gRaw, e, count, isV1, isV2, shiftAns, quoteAns] = await readAll(rpc, [raw(k.globals()), k.envelope(), k.count(), ...detectCalls(known, address)] as const);
  if (gRaw instanceof Error || e instanceof Error || count instanceof Error) {
    const err = [gRaw, e, count].find((v) => v instanceof Error) as Error;
    if (!(err instanceof CallError)) throw err;
    throw new Missing(`${address} does not answer like a Covenant kernel (${err.message})`);
  }
  const kind0 = kindOf(known, isV1, isV2, shiftAns, quoteAns);
  let g: AnyGlobals;
  try {
    g = kind0.version === 2 ? decGlobalsV2(gRaw) : decGlobals(gRaw);
  } catch (x) {
    throw new Missing(`${address} does not answer like a Covenant kernel v${kind0.version} (${(x as Error).message})`);
  }
  if (n < 1 || n > count) throw new Missing(`kernel ${address} has ${count} record${count === 1 ? '' : 's'}; there is no record ${n}`);
  const settle = <T>(p: Promise<T>): Promise<T | Error> => p.catch((x: unknown) => (x instanceof Error ? x : new Error(String(x))));
  const noLens = (): Promise<Error> => Promise.resolve(new Error(`no Lens in deployments/xlayer.json answers for this kernel (it was not created by the kernel v${kind0.version} factory recorded there)`));
  const L = kind0.lens ? lens(kind0.lens) : null;
  // Direct calls, exactly what the printed cast lines ask.
  const [rows, unit, replayTapeout, replaySealed, stateMatters] = await Promise.all([
    loadRecords(rpc, address, n, n, kind0.version),
    kind0.version === 2 ? quoteUnit(rpc, kind0.quote) : Promise.resolve(OKB_KIND),
    L ? settle(read(rpc, L.replayOn(address, n, false))) : noLens(),
    L ? settle(read(rpc, L.replayOn(address, n, true))) : noLens(),
    L ? settle(read(rpc, L.stateMatters(address, n))) : noLens(),
  ]);
  return { kind: { ...kind0, ...unit }, row: rows[0], count, globals: g, envelope: e, replayTapeout, replaySealed, stateMatters };
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
