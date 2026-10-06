// What a chip's output word means in human terms, and the Flow Governor's own field names.
// The Flow Governor tables are copied from chips/out/fg.fields.json (test/chip.test.ts checks the copy), so the
// landing page does not have to ship that whole file. Telemetry fields (MODE, TIER, FLAGS, AUX) mean something
// only for a chip whose published proofs tie them to its routing; the Flow Governor's do.

import witness from '../../../chips/out/fg.witness.json' with { type: 'json' };
import { exp8, exp8s, LG8_MAX, outputFields, unpack, wordOf, type Layout } from './model.ts';

export { witness };

/** keccak256 of chips/out/fg.hex as built and proven (chips/out/fg.proofs.json). */
export const FG_KECCAK = '0xe548768a1adafa7331faacfd029e1a829b00af3f7d769657f3b234ccdd7143b4';
export const FG_NSTATE = 64;
export const FG_GATES = { nand: 1888, latch: 64 };

export const FG_MODES = ['IDLE', 'CRUISE', 'BANK', 'DEFEND', 'REST'] as const;

/** What each mode does, one line each (chips/model/FLOW_GOVERNOR.md section 3). */
export const FG_MODE_NOTES: Record<string, string> = {
  IDLE: 'no live tax for eight epochs: a drought is declared',
  CRUISE: 'ordinary flow: most tax is bought and locked, a tier-dependent share goes to the allowance, a quarter is kept in reserve',
  BANK: 'tax at least twice its recent peak: more is banked instead of buying into the spike',
  DEFEND: 'the average fell to a quarter of its peak, a surge faded or a drought was declared: the reserve is released into buy-and-lock in tranches, no allowance',
  REST: 'six epochs of cooldown after a DEFEND window',
};

export const FG_FLAGS = ['surge', 'dip', 'quiet', 'release', 'regime', 'tierup', 'cooldown', 'warm'] as const;

/** The 64 latches, as fields (offset, width) of the state word. */
export const FG_STATE: Layout = [
  ['A', 0, 12],
  ['PK', 12, 10],
  ['PKDIV', 22, 2],
  ['MODE', 24, 3],
  ['TIER', 27, 2],
  ['GSEEN', 29, 1],
  ['WARM', 30, 2],
  ['LIVE', 32, 4],
  ['SUR', 36, 2],
  ['TR', 38, 2],
  ['CD', 40, 3],
  ['NBANK', 43, 5],
  ['NDEF', 48, 6],
  ['CLOCK', 54, 10],
];

export const FG_STATE_NOTES: Record<string, string> = {
  A: 'average tax rate per epoch, in quarter-codes above the floor',
  PK: 'decaying peak of the average, in codes above the floor',
  PKDIV: 'peak-decay prescaler',
  MODE: 'mode',
  TIER: 'allowance tier, 0..3; never decreases',
  GSEEN: 'graduation already seen',
  WARM: 'warm-up epochs left after a cold start',
  LIVE: 'epochs of patience before a drought is declared',
  SUR: 'surge meter, 0..3',
  TR: 'tranche epochs left in the DEFEND window',
  CD: 'cooldown epochs left in REST',
  NBANK: 'BANK episodes so far',
  NDEF: 'DEFEND windows so far',
  CLOCK: 'elapsed epochs, mod 1024',
};

/** A state word as named fields, with the mode spelled out. */
export function fgState(stateHex: string): { name: string; value: number; text: string }[] {
  const f = unpack(FG_STATE, wordOf(stateHex));
  return FG_STATE.map(([name]) => ({ name, value: f[name], text: name === 'MODE' ? (FG_MODES[f[name]] ?? `mode ${f[name]}`) : String(f[name]) }));
}

/** An output word read the way the kernel and a holder read it. */
export interface RouteView {
  /** Shares of this settle's tax, in 1/256ths. */
  buy: number;
  hold: number;
  allow: number;
  res: number;
  /** Share of the existing reserve released into buy-and-lock, in 1/256ths. */
  rel: number;
  /** The chip's own ceiling on this settle's allowance (lg8 code; 1023 = none). */
  ceil: number;
  /** Telemetry, as the chip gave it. */
  mode: number;
  tier: number;
  flags: number;
  aux: number;
  /** The tax shares are well formed (each at most 256, summing to 256). */
  wellFormed: boolean;
}

export function routeView(outputsHex: string): RouteView {
  const o = outputFields(outputsHex);
  return {
    buy: o.T_BUY,
    hold: o.T_HOLD,
    allow: o.T_ALLOW,
    res: o.T_RES,
    rel: o.REL,
    ceil: o.CEIL,
    mode: o.MODE,
    tier: o.TIER,
    flags: o.FLAGS,
    aux: o.AUX,
    wellFormed: Math.max(o.T_BUY, o.T_HOLD, o.T_ALLOW, o.T_RES) <= 256 && o.T_BUY + o.T_HOLD + o.T_ALLOW + o.T_RES === 256,
  };
}

export const fgModeName = (mode: number): string => FG_MODES[mode] ?? `mode ${mode}`;
export const fgFlagNames = (flags: number): string[] => FG_FLAGS.filter((_, i) => (flags >> i) & 1);

/** The routing fields that differ between two output words (T_*, REL, CEIL). */
export function routeDiff(a: string, b: string): string[] {
  const x = unpack(ROUTING, wordOf(a));
  const y = unpack(ROUTING, wordOf(b));
  return ROUTING.map(([n]) => n).filter((n) => x[n] !== y[n]);
}
const ROUTING: Layout = [
  ['T_BUY', 0, 9],
  ['T_HOLD', 9, 9],
  ['T_ALLOW', 18, 9],
  ['T_RES', 27, 9],
  ['REL', 72, 9],
  ['CEIL', 81, 10],
];

/** "62.5%" for a share in 1/256ths. */
export function pct256(share: number): string {
  return `${+((share * 100) / 256).toFixed(2)}%`;
}

/** The smallest amount an lg8 code stands for, as an approximate decimal of 18-decimal units ("≈ 0.0023"). */
export function approxCode(code: number, decimals: number = 18): string {
  if (code === 0) return '0';
  if (code >= LG8_MAX) return 'no limit';
  return approx(exp8(code), decimals);
}

/** The smallest amount a code stands for on a kernel with code shift `s` (exp8(code) >> s), as a short decimal. */
export function approxCodeIn(code: number, s: number, decimals: number): string {
  if (code === 0) return '0';
  if (code >= LG8_MAX) return 'no limit';
  return approx(exp8s(code, s), decimals);
}

/** The asset an amount is in: OKB or USD₮0 on the curve, the project token after graduation. */
export interface Unit {
  symbol: string;
  decimals: number;
}
export const OKB_UNIT: Unit = { symbol: 'OKB', decimals: 18 };

/** An amount for a sentence: "3.93 USD₮0", "0.0338 OKB"; "1 wei" / "3 base units" when it is that small. */
export function amount(v: bigint, u: Unit): string {
  const a = approx(v, u.decimals);
  return a.endsWith('wei') || a.endsWith('base units') ? a : `${a} ${u.symbol}`;
}

/**
 * Kernel v2's code shift (chips/INTERFACE-V2.md 4.1, chips/golden/kernel_model_v2.py, contracts/core-v2/NOTES.md
 * section 3): the stated reference rate it was derived from. The shift itself is read from each kernel.
 */
export const V2_REFERENCE = {
  /** bits; 264 codes */
  shift: 33,
  /** USD₮0 per OKB, the canonical Uniswap V3 USD₮0/WOKB 0.05% pool's spot price at the block below */
  rate: '135.895901',
  block: 72_530_000,
  pool: '0xe3BE6A0137f1b0602Fc1a4841686f43B340a5082',
} as const;

/** The OKB prices, in USD₮0 per OKB, for which `s` is the nearest whole-bit shift: 10^12 / 2^(s ± 1/2). */
export function shiftBand(s: number): [number, number] {
  return [1e12 / 2 ** (s + 0.5), 1e12 / 2 ** (s - 0.5)];
}

/** An OKB amount for a sentence: "0.0338 OKB", or "1 wei" when it is below a millionth of a gwei. */
export const okb = (v: bigint): string => {
  const a = approx(v);
  return a.endsWith('wei') ? a : `${a} OKB`;
};

/** An amount in base units as a short decimal with two to three significant digits. */
export function approx(v: bigint, decimals: number = 18): string {
  if (v === 0n) return '0';
  const s = v.toString().padStart(decimals + 1, '0');
  const whole = s.slice(0, s.length - decimals);
  const frac = s.slice(s.length - decimals);
  if (whole !== '0') {
    const w = BigInt(whole);
    if (w >= 1000n) return w.toLocaleString('en-US');
    return `${whole}.${frac.slice(0, 3 - Math.min(2, whole.length - 1))}`.replace(/\.?0+$/, '');
  }
  const lead = frac.search(/[1-9]/);
  if (lead > 12) return decimals === 18 ? `${v} wei` : `${v} base units`;
  return `0.${frac.slice(0, lead + 2)}`.replace(/0+$/, '');
}

/** LaunchChip.referenceEnvelope, the envelope the Flow Governor was compiled against (chips/out/fg.fields.json). */
export const REF_ENVELOPE = {
  epochLen: 900,
  capT: 48,
  capV: 0,
  allowCumBps: 1875,
  ceilMax: 440,
  relMax: 128,
  floorRel: 2,
  floorMin: 1,
  fallbackEpochs: 16,
  fbAllow: 8,
  buyEnabled: true,
};
