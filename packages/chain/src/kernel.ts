// Covenant's read-only surface: the kernel (chips/INTERFACE.md section 10, contracts/core/src/Kernel.sol), kernel v2
// (USD₮0 quote: chips/INTERFACE-V2.md section 10, contracts/core-v2), their factories, the Lens, the Fab, and the
// few IGNIX, USD₮0 and Multicall3 views the kernel pages read. Same pattern as tapeout.ts: literal selectors next to
// their signatures, hand-written decoders; test/kernel.test.ts checks every selector against keccak256 and every
// encoder and decoder against viem.
//
// A separate entry ('@covenant/chain/kernel') so that a bundle that only reads TapeOut does not carry it.

import { addressWord, decAddress, decBool, decBytes, decString, decUint, strip, word } from './abi.ts';
import type { Call } from './tapeout.ts';

const mk = <T>(to: string, selector: string, args: string, decode: (ret: string) => T): Call<T> => ({
  to,
  data: '0x' + selector + args,
  decode,
});

/** 32-byte word `i` of return data, refusing to read past the end. */
const w = (r: string, i: number): string => {
  const s = r.slice(64 * i, 64 * i + 64);
  if (s.length < 64) throw new Error('ABI: return data too short');
  return s;
};
const big = (r: string, i: number): bigint => BigInt('0x' + w(r, i));
const small = (r: string, i: number): number => Number(big(r, i));
const flag = (r: string, i: number): boolean => big(r, i) !== 0n;
const addr = (r: string, i: number): string => '0x' + w(r, i).slice(24);
const b32 = (r: string, i: number): string => '0x' + w(r, i);
/** A left-aligned bytesN value: the first n bytes of the word. */
const bN = (r: string, i: number, n: number): string => '0x' + w(r, i).slice(0, 2 * n);
/** Several static words at once: `f` gets the return data without 0x. */
const tuple =
  <T>(f: (r: string) => T) =>
  (ret: string): T =>
    f(strip(ret));

const u32 = (v: number | bigint): string => word(v);
const bool = (v: boolean): string => word(v ? 1 : 0);
const b32w = (h: string): string => strip(h).toLowerCase().padEnd(64, '0');

// ----------------------------------------------------------------------------------------------- types

/** One settle (INTERFACE section 10). `stateBefore` is the previous record's `stateAfter`. */
export interface KernelRecord {
  epoch: number;
  time: number;
  clampBits: number;
  flags: number;
  /** bytes12, exactly what was passed to step */
  inputs: string;
  /** bytes14, exactly what step returned (or the fallback word) */
  outputs: string;
  /** bytes32: the state string first, zero bytes after it */
  stateAfter: string;
  inflow: bigint;
  reserveBefore: bigint;
  allow: bigint;
  buyDecided: bigint;
  buyExecuted: bigint;
  tokensOut: bigint;
  nativeIn: bigint;
}

export const decRecord = tuple(
  (r): KernelRecord => ({
    epoch: small(r, 0),
    time: small(r, 1),
    clampBits: small(r, 2),
    flags: small(r, 3),
    inputs: bN(r, 4, 12),
    outputs: bN(r, 5, 14),
    stateAfter: b32(r, 6),
    inflow: big(r, 7),
    reserveBefore: big(r, 8),
    allow: big(r, 9),
    buyDecided: big(r, 10),
    buyExecuted: big(r, 11),
    tokensOut: big(r, 12),
    nativeIn: big(r, 13),
  }),
);

/** The immutable envelope of a kernel (INTERFACE section 7). */
export interface Envelope {
  launcher: string;
  epochLen: number;
  allowancePayee: string;
  capT: number;
  capV: number;
  allowCumBps: number;
  ceilMax: number;
  relMax: number;
  floorRel: number;
  floorMin: number;
  fallbackEpochs: number;
  fbAllow: number;
  buyEnabled: boolean;
  sink: string;
}

export const decEnvelope = tuple(
  (r): Envelope => ({
    launcher: addr(r, 0),
    epochLen: small(r, 1),
    allowancePayee: addr(r, 2),
    capT: small(r, 3),
    capV: small(r, 4),
    allowCumBps: small(r, 5),
    ceilMax: small(r, 6),
    relMax: small(r, 7),
    floorRel: small(r, 8),
    floorMin: small(r, 9),
    fallbackEpochs: small(r, 10),
    fbAllow: small(r, 11),
    buyEnabled: flag(r, 12),
    sink: addr(r, 13),
  }),
);

/** Everything a kernel knows besides its envelope (IKernelExt.sol). */
export interface Globals {
  manager: string;
  v2Router: string;
  wokb: string;
  factory: string;
  circuits: string;
  fab: string;
  sealedVM: string;
  beacon: string;
  impl0: string;
  impl0Hash: string;
  snapshot: string;
  netlistHash: string;
  chipId: bigint;
  nState: number;
  gateCount: number;
  netlistLen: number;
  stepFloor: bigint;
  sealedFloor: bigint;
}

export const decGlobals = tuple(
  (r): Globals => ({
    manager: addr(r, 0),
    v2Router: addr(r, 1),
    wokb: addr(r, 2),
    factory: addr(r, 3),
    circuits: addr(r, 4),
    fab: addr(r, 5),
    sealedVM: addr(r, 6),
    beacon: addr(r, 7),
    impl0: addr(r, 8),
    impl0Hash: b32(r, 9),
    snapshot: addr(r, 10),
    netlistHash: b32(r, 11),
    chipId: big(r, 12),
    nState: small(r, 13),
    gateCount: small(r, 14),
    netlistLen: small(r, 15),
    stepFloor: big(r, 16),
    sealedFloor: big(r, 17),
  }),
);

// Kernel v2 (USD₮0 quote): contracts/core-v2/src/interfaces/IKernelV2.sol, chips/INTERFACE-V2.md section 10.
// Same record layout with `quoteIn` (USD₮0 the post-graduation router buy spent) in place of `nativeIn`; globals with
// the quote asset in place of WOKB and the code shift appended. Everything else reads exactly as kernel v1.

/** One settle of a v2 kernel. Amounts on the curve are USD₮0 base units (6 decimals). */
export interface KernelRecordV2 extends Omit<KernelRecord, 'nativeIn'> {
  quoteIn: bigint;
}

export const decRecordV2 = tuple((r): KernelRecordV2 => {
  const { nativeIn, ...rest } = decRecord(r);
  return { ...rest, quoteIn: nativeIn };
});

/** GlobalsV2: `quote` in place of `wokb`, plus `quoteShift` (bits) at the end: 19 words. */
export interface GlobalsV2 extends Omit<Globals, 'wokb'> {
  quote: string;
  quoteShift: number;
}

export const decGlobalsV2 = tuple((r): GlobalsV2 => {
  const { wokb, ...rest } = decGlobals(r);
  return { ...rest, quote: wokb, quoteShift: small(r, 18) };
});

/** Lens.replay: the record recomputed through one evaluator and through KernelMath. */
export interface Replay {
  ok: boolean;
  ran: boolean;
  outputsMatch: boolean;
  stateMatch: boolean;
  amountsMatch: boolean;
  inputsMatch: boolean;
  sealedUsed: boolean;
  outputs: string;
  stateAfter: string;
}

export const decReplay = tuple(
  (r): Replay => ({
    ok: flag(r, 0),
    ran: flag(r, 1),
    outputsMatch: flag(r, 2),
    stateMatch: flag(r, 3),
    amountsMatch: flag(r, 4),
    inputsMatch: flag(r, 5),
    sealedUsed: flag(r, 6),
    outputs: bN(r, 7, 14),
    stateAfter: b32(r, 8),
  }),
);

export interface Totals {
  inflow: bigint;
  allow: bigint;
  buy: bigint;
  reserveEnd: bigint;
}
export interface Counterfactual {
  chip: Totals;
  chipBuyExecuted: bigint;
  fixedSplit: Totals;
  alwaysBuy: Totals;
}
export interface CfCursor {
  reserve: bigint;
  allowPaid: bigint;
  grad: boolean;
}

const totals = (r: string, i: number): Totals => ({ inflow: big(r, i), allow: big(r, i + 1), buy: big(r, i + 2), reserveEnd: big(r, i + 3) });
const cf = (r: string, i: number): Counterfactual => ({
  chip: totals(r, i),
  chipBuyExecuted: big(r, i + 4),
  fixedSplit: totals(r, i + 5),
  alwaysBuy: totals(r, i + 9),
});

export const decCounterfactual = tuple((r): { curve: Counterfactual; graduated: Counterfactual; next: CfCursor } => ({
  curve: cf(r, 0),
  graduated: cf(r, 13),
  next: { reserve: big(r, 26), allowPaid: big(r, 27), grad: flag(r, 28) },
}));

export interface StateMatters {
  matters: boolean;
  withState: string;
  withOther: string;
}
export const decStateMatters = tuple((r): StateMatters => ({ matters: flag(r, 0), withState: bN(r, 1, 14), withOther: bN(r, 2, 14) }));

export interface Preflight {
  sealedModeNow: boolean;
  tapeoutRan: boolean;
  sealedRan: boolean;
  agree: boolean;
  tapeoutGas: bigint;
  sealedGas: bigint;
  stepFloor: bigint;
  sealedFloor: bigint;
  minSettleGas: bigint;
}
export const decPreflight = tuple(
  (r): Preflight => ({
    sealedModeNow: flag(r, 0),
    tapeoutRan: flag(r, 1),
    sealedRan: flag(r, 2),
    agree: flag(r, 3),
    tapeoutGas: big(r, 4),
    sealedGas: big(r, 5),
    stepFloor: big(r, 6),
    sealedFloor: big(r, 7),
    minSettleGas: big(r, 8),
  }),
);

/** Running state of a Lens shadow run; all zero at record 1. */
export interface ShadowCursor {
  state: string;
  reserve: bigint;
  allowPaid: bigint;
  grad: boolean;
}
export const SHADOW_START: ShadowCursor = { state: '0x' + '00'.repeat(32), reserve: 0n, allowPaid: 0n, grad: false };

export interface ShadowStep {
  n: number;
  ran: boolean;
  inputs: string;
  outputs: string;
  clampBits: number;
  allow: bigint;
  buyDecided: bigint;
  reserveAfter: bigint;
}
export interface ShadowPage {
  steps: ShadowStep[];
  next: ShadowCursor;
  nextN: number;
}
export const decShadow = tuple((r): ShadowPage => {
  const at = small(r, 0) / 32;
  const n = small(r, at);
  const steps: ShadowStep[] = [];
  for (let k = 0; k < n; k++) {
    const i = at + 1 + 8 * k;
    steps.push({
      n: small(r, i),
      ran: flag(r, i + 1),
      inputs: bN(r, i + 2, 12),
      outputs: bN(r, i + 3, 14),
      clampBits: small(r, i + 4),
      allow: big(r, i + 5),
      buyDecided: big(r, i + 6),
      reserveAfter: big(r, i + 7),
    });
  }
  return { steps, next: { state: b32(r, 1), reserve: big(r, 2), allowPaid: big(r, 3), grad: flag(r, 4) }, nextN: small(r, 5) };
});

const cursorWords = (c: ShadowCursor): string => b32w(c.state) + word(c.reserve) + word(c.allowPaid) + bool(c.grad);

export interface ChipInfo {
  snapshot: string;
  netlistHash: string;
  nState: number;
  gateCount: number;
  author: string;
  manifestHash: string;
}
export const decChipInfo = tuple(
  (r): ChipInfo => ({ snapshot: addr(r, 0), netlistHash: b32(r, 1), nState: small(r, 2), gateCount: small(r, 3), author: addr(r, 4), manifestHash: b32(r, 5) }),
);

/** IgnixManager.tokens(token): the curve words the kernel reads. */
export interface CurveToken {
  creator: string;
  buyFeeBps: number;
  sellFeeBps: number;
  taxBuyBps: number;
  taxSellBps: number;
  quote: string;
  snipeStartBps: number;
  snipeMins: number;
  createdAt: number;
  vQuote: bigint;
  vToken: bigint;
  sold: bigint;
  collected: bigint;
  sellable: bigint;
  reserve: bigint;
  poolId: string;
}
export const decCurveToken = tuple(
  (r): CurveToken => ({
    creator: addr(r, 0),
    buyFeeBps: small(r, 1),
    sellFeeBps: small(r, 2),
    taxBuyBps: small(r, 3),
    taxSellBps: small(r, 4),
    quote: addr(r, 5),
    snipeStartBps: small(r, 6),
    snipeMins: small(r, 7),
    createdAt: small(r, 8),
    vQuote: big(r, 9),
    vToken: big(r, 10),
    sold: big(r, 11),
    collected: big(r, 12),
    sellable: big(r, 13),
    reserve: big(r, 14),
    poolId: b32(r, 15),
  }),
);

export interface TeamEntry {
  wallet: string;
  role: string;
  timestamp: bigint;
}
export const decTeamEntry = tuple((r): TeamEntry => ({ wallet: addr(r, 0), role: decString(word(32) + r.slice(2 * small(r, 1))), timestamp: big(r, 2) }));

// ----------------------------------------------------------------------------------------------- calls

type N = number | bigint;

/** A Covenant kernel (a clone of the factory's Kernel implementation). */
export const kernel = (at: string) => ({
  /** token() */
  token: (): Call<string> => mk(at, 'fc0c546a', '', decAddress),
  /** vault() */
  vault: (): Call<string> => mk(at, 'fbfa77cf', '', decAddress),
  /** chipId() */
  chipId: (): Call<bigint> => mk(at, '0351e494', '', decUint),
  /** count(): number of records; records are 1-indexed */
  count: (): Call<number> => mk(at, '06661abd', '', (r) => Number(decUint(r))),
  /** records(uint32): all zero for n = 0 or n > count */
  records: (n: N): Call<KernelRecord> => mk(at, '3bd29d69', u32(n), decRecord),
  /** cums(uint32) returns (uint128 cumInflow, uint128 allowPaidCum): regime totals after settle n */
  cums: (n: N): Call<{ cumInflow: bigint; allowPaidCum: bigint }> => mk(at, '775b0b88', u32(n), tuple((r) => ({ cumInflow: big(r, 0), allowPaidCum: big(r, 1) }))),
  /** state() */
  state: (): Call<string> => mk(at, 'c19d93fb', '', (r) => '0x' + strip(r).slice(0, 64)),
  /** epochNow() */
  epochNow: (): Call<number> => mk(at, '222ae786', '', (r) => Number(decUint(r))),
  /** lastEpoch() */
  lastEpoch: (): Call<number> => mk(at, '06a4c983', '', (r) => Number(decUint(r))),
  /** lastStepEpoch() */
  lastStepEpoch: (): Call<number> => mk(at, '6e582a9e', '', (r) => Number(decUint(r))),
  /** bindTime() */
  bindTime: (): Call<number> => mk(at, '41ab2965', '', (r) => Number(decUint(r))),
  /** reserve(): regime asset, as of the last settle */
  reserve: (): Call<bigint> => mk(at, 'cd3293de', '', decUint),
  /** creditOf(address payee, address asset) */
  creditOf: (payee: string, asset: string): Call<bigint> => mk(at, '035ec584', addressWord(payee) + addressWord(asset), decUint),
  /** totalCredits(address asset) */
  totalCredits: (asset: string): Call<bigint> => mk(at, 'cc89a012', addressWord(asset), decUint),
  /** lockedTokens() */
  lockedTokens: (): Call<bigint> => mk(at, '0eb34740', '', decUint),
  /** burnedTokens() */
  burnedTokens: (): Call<bigint> => mk(at, '47b5dd54', '', decUint),
  /** graduated() */
  graduated: (): Call<boolean> => mk(at, 'e7c2b772', '', decBool),
  /** pair() */
  pair: (): Call<string> => mk(at, 'a8aa1b31', '', decAddress),
  /** envelope() */
  envelope: (): Call<Envelope> => mk(at, '0ee8b522', '', decEnvelope),
  /** evaluator() returns (address vm, bool sealedMode): what the next settle would ask first */
  evaluator: (): Call<{ vm: string; sealedMode: boolean }> => mk(at, '9cb93dd1', '', tuple((r) => ({ vm: addr(r, 0), sealedMode: flag(r, 1) }))),
  /** minSettleGas() */
  minSettleGas: (): Call<bigint> => mk(at, 'dcf032c9', '', decUint),
  /** globals() */
  globals: (): Call<Globals> => mk(at, 'c3124525', '', decGlobals),
  /** cumInflow() */
  cumInflow: (): Call<bigint> => mk(at, '58148290', '', decUint),
  /** allowPaidCum() */
  allowPaidCum: (): Call<bigint> => mk(at, '768a2f23', '', decUint),
  /** tokenSupply(): token.totalSupply() read at bind */
  tokenSupply: (): Call<bigint> => mk(at, '7824407f', '', decUint),
});

/** The KernelFactory. */
export const kernelFactory = (at: string) => ({
  /** isKernel(address) */
  isKernel: (k: string): Call<boolean> => mk(at, 'be537a79', addressWord(k), decBool),
  /** kernelOf(address token) */
  kernelOf: (token: string): Call<string> => mk(at, 'ee07e32a', addressWord(token), decAddress),
  /** pinsLive(): TapeOut's live circuit implementation is still the pinned one */
  pinsLive: (): Call<boolean> => mk(at, '5445c19c', '', decBool),
  /** kernelImpl() */
  kernelImpl: (): Call<string> => mk(at, 'd2920091', '', decAddress),
  /** fab() */
  fab: (): Call<string> => mk(at, 'd27e6fed', '', decAddress),
  /** impl0() */
  impl0: (): Call<string> => mk(at, '19ed6021', '', decAddress),
  /** impl0Hash() */
  impl0Hash: (): Call<string> => mk(at, '74fadbf8', '', (r) => '0x' + strip(r).slice(0, 64)),
  /** beacon() */
  beacon: (): Call<string> => mk(at, '59659e90', '', decAddress),
});

/**
 * A kernel v2 (USD₮0 quote): kernel v1's views with the v2 `globals()` and `records(n)` layouts, plus the quote
 * asset and its code shift. LensV2 has kernel v1's Lens ABI, so `lens(at)` reads it unchanged.
 */
export const kernelV2 = (at: string) => ({
  ...kernel(at),
  /** records(uint32): RecordV2 (`quoteIn` in place of `nativeIn`) */
  records: (n: N): Call<KernelRecordV2> => mk(at, '3bd29d69', u32(n), decRecordV2),
  /** globals(): GlobalsV2 */
  globals: (): Call<GlobalsV2> => mk(at, 'c3124525', '', decGlobalsV2),
  /** quote(): the ERC-20 quote asset this kernel routes on the curve */
  quote: (): Call<string> => mk(at, '999b93af', '', decAddress),
  /** quoteShift(): code shift in bits on the curve (33 for USD₮0) */
  quoteShift: (): Call<number> => mk(at, 'c415e92c', '', (r) => Number(decUint(r))),
});

/** The KernelFactoryV2: kernel v1's factory views plus its quote pins. */
export const kernelFactoryV2 = (at: string) => ({
  ...kernelFactory(at),
  /** quote() */
  quote: (): Call<string> => mk(at, '999b93af', '', decAddress),
  /** quoteShift(): bits */
  quoteShift: (): Call<number> => mk(at, 'c415e92c', '', (r) => Number(decUint(r))),
  /** codeShift(): 8 * quoteShift, in lg8 codes */
  codeShift: (): Call<number> => mk(at, 'd18c0712', '', (r) => Number(decUint(r))),
  /** manager() */
  manager: (): Call<string> => mk(at, '481c6a75', '', decAddress),
  /** v2Router() */
  v2Router: (): Call<string> => mk(at, 'deadbc14', '', decAddress),
});

/** The Lens: stateless audit views over the kernels of one factory. */
export const lens = (at: string) => ({
  /** FACTORY() */
  factory: (): Call<string> => mk(at, '2dd31000', '', decAddress),
  /** replay(address,uint32): through the evaluator the record says was used */
  replay: (k: string, n: N): Call<Replay> => mk(at, '6cb4f3b4', addressWord(k) + u32(n), decReplay),
  /** replayOn(address,uint32,bool useSealed) */
  replayOn: (k: string, n: N, useSealed: boolean): Call<Replay> => mk(at, 'a577a07b', addressWord(k) + u32(n) + bool(useSealed), decReplay),
  /** counterfactual(address,uint32,uint32) */
  counterfactual: (k: string, fromN: N, toN: N) => mk(at, '55080a96', addressWord(k) + u32(fromN) + u32(toN), decCounterfactual),
  /** counterfactualFrom(address,uint32,uint32,(uint256,uint256,bool)) */
  counterfactualFrom: (k: string, fromN: N, toN: N, c: CfCursor) =>
    mk(at, 'ddd88d29', addressWord(k) + u32(fromN) + u32(toN) + word(c.reserve) + word(c.allowPaid) + bool(c.grad), decCounterfactual),
  /** stateMatters(address,uint32): the record's state against the all-zero state */
  stateMatters: (k: string, n: N): Call<StateMatters> => mk(at, 'e59316f3', addressWord(k) + u32(n), decStateMatters),
  /** stateMattersVs(address,uint32,bytes32) */
  stateMattersVs: (k: string, n: N, other: string): Call<StateMatters> => mk(at, 'd42de344', addressWord(k) + u32(n) + b32w(other), decStateMatters),
  /** preflight(address) */
  preflight: (k: string): Call<Preflight> => mk(at, 'e7ef7f66', addressWord(k), decPreflight),
  /** shadowChip(address,uint256,uint32,uint32,(bytes32,uint256,uint256,bool)) */
  shadowChip: (k: string, chipId: N, fromN: N, toN: N, c: ShadowCursor = SHADOW_START): Call<ShadowPage> =>
    mk(at, '0bd3fbd4', addressWord(k) + word(chipId) + u32(fromN) + u32(toN) + cursorWords(c), decShadow),
  /** shadowSnapshot(address,address,uint32,uint32,(bytes32,uint256,uint256,bool)) */
  shadowSnapshot: (k: string, snapshot: string, fromN: N, toN: N, c: ShadowCursor = SHADOW_START): Call<ShadowPage> =>
    mk(at, '2bc5a813', addressWord(k) + addressWord(snapshot) + u32(fromN) + u32(toN) + cursorWords(c), decShadow),
});

/** The Fab that tapes chips out and keeps their netlist snapshots. */
export const fab = (at: string) => ({
  /** chipInfo(uint256) */
  chipInfo: (id: N): Call<ChipInfo> => mk(at, '4c9540b3', word(id), decChipInfo),
  /** isChip(uint256) */
  isChip: (id: N): Call<boolean> => mk(at, '5ae77099', word(id), decBool),
  /** CIRCUITS() */
  circuits: (): Call<string> => mk(at, '5ddfb7ea', '', decAddress),
});

/** IGNIX: the launch manager, a Directed vault, a token. */
export const ignix = {
  /** IgnixManager.vaultOf(address token) */
  vaultOf: (manager: string, token: string): Call<string> => mk(manager, '0709df45', addressWord(token), decAddress),
  /** IgnixManager.tokens(address token) */
  tokens: (manager: string, token: string): Call<CurveToken> => mk(manager, 'e4860339', addressWord(token), decCurveToken),
  /** DirectedVault.RECIPIENT() */
  recipient: (vault: string): Call<string> => mk(vault, '0d9019e1', '', decAddress),
  /** DirectedVault.TOKEN() */
  vaultToken: (vault: string): Call<string> => mk(vault, '82bfefc8', '', decAddress),
  /** DirectedVault.QUOTE() */
  vaultQuote: (vault: string): Call<string> => mk(vault, '9c579839', '', decAddress),
};

/** An ERC-20 (the project token). */
export const erc20 = (at: string) => ({
  /** name() */
  name: (): Call<string> => mk(at, '06fdde03', '', decString),
  /** symbol() */
  symbol: (): Call<string> => mk(at, '95d89b41', '', decString),
  /** decimals() */
  decimals: (): Call<number> => mk(at, '313ce567', '', (r) => Number(decUint(r))),
  /** totalSupply() */
  totalSupply: (): Call<bigint> => mk(at, '18160ddd', '', decUint),
  /** balanceOf(address) */
  balanceOf: (who: string): Call<bigint> => mk(at, '70a08231', addressWord(who), decUint),
  /** pair() (IgnixToken): non-zero once graduated */
  pair: (): Call<string> => mk(at, 'a8aa1b31', '', decAddress),
  /** allowance(address owner, address spender) */
  allowance: (owner: string, spender: string): Call<bigint> => mk(at, 'dd62ed3e', addressWord(owner) + addressWord(spender), decUint),
});

/** USD₮0 (a TetherToken): whether its owner has blocked an address. A blocked address can receive but not send. */
export const tether = (at: string) => ({
  /** isBlocked(address) */
  isBlocked: (who: string): Call<boolean> => mk(at, 'fbac3951', addressWord(who), decBool),
});

/** An OpenZeppelin UpgradeableBeacon: implementation(). */
export const beaconImpl = (at: string): Call<string> => mk(at, '5c60da1b', '', decAddress);

/** The issuance TeamRegistry: count() and at(i). */
export const teamRegistry = (at: string) => ({
  count: (): Call<number> => mk(at, '06661abd', '', (r) => Number(decUint(r))),
  at: (i: N): Call<TeamEntry> => mk(at, 'e0886f90', word(i), decTeamEntry),
});

/** Multicall3 getCurrentBlockTimestamp() and getEthBalance(address). */
export const multicallViews = (at: string) => ({
  timestamp: (): Call<number> => mk(at, '0f28c97d', '', (r) => Number(decUint(r))),
  ethBalance: (who: string): Call<bigint> => mk(at, '4d2301cc', addressWord(who), decUint),
});

/** owner() of an Ownable contract, and a Safe's threshold and owners: who can upgrade what. */
export const ownerOf = (at: string): Call<string> => mk(at, '8da5cb5b', '', decAddress);
export const safe = (at: string) => ({
  threshold: (): Call<number> => mk(at, 'e75235b8', '', (r) => Number(decUint(r))),
  owners: (): Call<string[]> =>
    mk(at, 'a0e67e2b', '', tuple((r) => {
      const at0 = small(r, 0) / 32;
      return Array.from({ length: small(r, at0) }, (_, i) => addr(r, at0 + 1 + i));
    })),
});

/** Raw bytes return, for `Fab.snapshot(uint256)`. */
export const fabSnapshot = (at: string, id: N): Call<string> => mk(at, '8f1dd809', word(id), decBytes);

/**
 * Every signature used above with its selector, for the tests and for printing `cast` lines.
 * Reference data; it costs nothing in a bundle that does not import it.
 */
export const KERNEL_SIGNATURES = {
  token: ['token()', 'fc0c546a'],
  vault: ['vault()', 'fbfa77cf'],
  chipId: ['chipId()', '0351e494'],
  count: ['count()', '06661abd'],
  records: ['records(uint32)', '3bd29d69'],
  cums: ['cums(uint32)', '775b0b88'],
  state: ['state()', 'c19d93fb'],
  epochNow: ['epochNow()', '222ae786'],
  lastEpoch: ['lastEpoch()', '06a4c983'],
  lastStepEpoch: ['lastStepEpoch()', '6e582a9e'],
  bindTime: ['bindTime()', '41ab2965'],
  reserve: ['reserve()', 'cd3293de'],
  creditOf: ['creditOf(address,address)', '035ec584'],
  totalCredits: ['totalCredits(address)', 'cc89a012'],
  lockedTokens: ['lockedTokens()', '0eb34740'],
  burnedTokens: ['burnedTokens()', '47b5dd54'],
  graduated: ['graduated()', 'e7c2b772'],
  pair: ['pair()', 'a8aa1b31'],
  envelope: ['envelope()', '0ee8b522'],
  evaluator: ['evaluator()', '9cb93dd1'],
  minSettleGas: ['minSettleGas()', 'dcf032c9'],
  globals: ['globals()', 'c3124525'],
  cumInflow: ['cumInflow()', '58148290'],
  allowPaidCum: ['allowPaidCum()', '768a2f23'],
  tokenSupply: ['tokenSupply()', '7824407f'],
  isKernel: ['isKernel(address)', 'be537a79'],
  kernelOf: ['kernelOf(address)', 'ee07e32a'],
  pinsLive: ['pinsLive()', '5445c19c'],
  kernelImpl: ['kernelImpl()', 'd2920091'],
  fab: ['fab()', 'd27e6fed'],
  impl0: ['impl0()', '19ed6021'],
  impl0Hash: ['impl0Hash()', '74fadbf8'],
  beacon: ['beacon()', '59659e90'],
  FACTORY: ['FACTORY()', '2dd31000'],
  replay: ['replay(address,uint32)', '6cb4f3b4'],
  replayOn: ['replayOn(address,uint32,bool)', 'a577a07b'],
  counterfactual: ['counterfactual(address,uint32,uint32)', '55080a96'],
  counterfactualFrom: ['counterfactualFrom(address,uint32,uint32,(uint256,uint256,bool))', 'ddd88d29'],
  stateMatters: ['stateMatters(address,uint32)', 'e59316f3'],
  stateMattersVs: ['stateMattersVs(address,uint32,bytes32)', 'd42de344'],
  preflight: ['preflight(address)', 'e7ef7f66'],
  shadowChip: ['shadowChip(address,uint256,uint32,uint32,(bytes32,uint256,uint256,bool))', '0bd3fbd4'],
  shadowSnapshot: ['shadowSnapshot(address,address,uint32,uint32,(bytes32,uint256,uint256,bool))', '2bc5a813'],
  chipInfo: ['chipInfo(uint256)', '4c9540b3'],
  isChip: ['isChip(uint256)', '5ae77099'],
  snapshot: ['snapshot(uint256)', '8f1dd809'],
  CIRCUITS: ['CIRCUITS()', '5ddfb7ea'],
  vaultOf: ['vaultOf(address)', '0709df45'],
  tokens: ['tokens(address)', 'e4860339'],
  RECIPIENT: ['RECIPIENT()', '0d9019e1'],
  TOKEN: ['TOKEN()', '82bfefc8'],
  QUOTE: ['QUOTE()', '9c579839'],
  name: ['name()', '06fdde03'],
  symbol: ['symbol()', '95d89b41'],
  decimals: ['decimals()', '313ce567'],
  totalSupply: ['totalSupply()', '18160ddd'],
  balanceOf: ['balanceOf(address)', '70a08231'],
  allowance: ['allowance(address,address)', 'dd62ed3e'],
  isBlocked: ['isBlocked(address)', 'fbac3951'],
  quote: ['quote()', '999b93af'],
  quoteShift: ['quoteShift()', 'c415e92c'],
  codeShift: ['codeShift()', 'd18c0712'],
  manager: ['manager()', '481c6a75'],
  v2Router: ['v2Router()', 'deadbc14'],
  implementation: ['implementation()', '5c60da1b'],
  at: ['at(uint256)', 'e0886f90'],
  getCurrentBlockTimestamp: ['getCurrentBlockTimestamp()', '0f28c97d'],
  getEthBalance: ['getEthBalance(address)', '4d2301cc'],
  owner: ['owner()', '8da5cb5b'],
  getThreshold: ['getThreshold()', 'e75235b8'],
  getOwners: ['getOwners()', 'a0e67e2b'],
} as const satisfies Record<string, readonly [signature: string, selector: string]>;
