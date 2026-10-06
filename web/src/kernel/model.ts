// The kernel's arithmetic in TypeScript: the lg8 log code, the input and output word layouts, and the routing
// with its clamps (chips/INTERFACE.md sections 4 to 8). A port of chips/golden/kernel_model.py, which is the
// reference; test/model.test.ts runs every routing, log-code, layout and fallback vector of
// chips/golden/vectors.json through it. Integers only (bigint), no floats.

export const LG8_MAX = 1023;

/** 10-bit log code in 1/8-octave steps. lg8(0) = 0, lg8(1) = 1, lg8(1e18) = 478. */
export function lg8(x: bigint): number {
  if (x < 0n) throw new RangeError('negative amount');
  if (x === 0n) return 0;
  const e = x.toString(2).length - 1;
  const m = e >= 3 ? Number((x >> BigInt(e - 3)) & 7n) : Number((x << BigInt(3 - e)) & 7n);
  return Math.min(LG8_MAX, 8 * e + m + 1);
}

/** Floor inverse of lg8: exp8(lg8(x)) <= x. */
export function exp8(c: number): bigint {
  if (!Number.isInteger(c) || c < 0 || c > LG8_MAX) throw new RangeError('code out of range');
  if (c === 0) return 0n;
  return (BigInt(8 + ((c - 1) & 7)) << BigInt((c - 1) >> 3)) >> 3n;
}

export type Layout = readonly (readonly [name: string, offset: number, width: number])[];

export const INPUT_FIELDS: Layout = [
  ['TAX', 0, 10],
  ['TAXCUM', 10, 10],
  ['REV', 20, 10],
  ['REVCUM', 30, 10],
  ['RES', 40, 10],
  ['ESC', 50, 10],
  ['PROG', 60, 8],
  ['LOCK', 68, 8],
  ['DT', 76, 4],
  ['GRAD', 80, 1],
  ['ZERO', 81, 15],
];

export const OUTPUT_FIELDS: Layout = [
  ['T_BUY', 0, 9],
  ['T_HOLD', 9, 9],
  ['T_ALLOW', 18, 9],
  ['T_RES', 27, 9],
  ['V_BUY', 36, 9],
  ['V_HOLD', 45, 9],
  ['V_ALLOW', 54, 9],
  ['V_RES', 63, 9],
  ['REL', 72, 9],
  ['CEIL', 81, 10],
  ['MODE', 91, 3],
  ['TIER', 94, 2],
  ['FLAGS', 96, 8],
  ['AUX', 104, 8],
];

export type Fields = Record<string, number>;

export function unpack(layout: Layout, word: bigint): Fields {
  const out: Fields = {};
  for (const [name, off, width] of layout) out[name] = Number((word >> BigInt(off)) & ((1n << BigInt(width)) - 1n));
  return out;
}

export function pack(layout: Layout, values: Fields): bigint {
  let word = 0n;
  for (const [name, off, width] of layout) {
    const v = values[name] ?? 0;
    if (!Number.isInteger(v) || v < 0 || v >= 2 ** width) throw new RangeError(`${name}=${v} does not fit ${width} bits`);
    word |= BigInt(v) << BigInt(off);
  }
  return word;
}

/** TAP-20 packing: bit i is bit (i mod 8) of byte (i / 8); the word is the little-endian integer of the bytes. */
export function wordOf(hex: string): bigint {
  const h = hex.replace(/^0x/i, '');
  let w = 0n;
  for (let i = h.length / 2 - 1; i >= 0; i--) w = (w << 8n) | BigInt(parseInt(h.slice(2 * i, 2 * i + 2), 16));
  return w;
}

/** The `nBytes` little-endian bytes of a word, as 0x hex. */
export function bytesOf(word: bigint, nBytes: number): string {
  let s = '0x';
  for (let i = 0; i < nBytes; i++) s += Number((word >> BigInt(8 * i)) & 255n).toString(16).padStart(2, '0');
  return s;
}

export const inputFields = (hex: string): Fields => unpack(INPUT_FIELDS, wordOf(hex));
export const outputFields = (hex: string): Fields => unpack(OUTPUT_FIELDS, wordOf(hex));

/** Kernel storage form of a state (bytes32, the string first) to the `ceil(nState / 8)` bytes step takes. */
export const stateBytes = (bytes32: string, nState: number): string => '0x' + bytes32.replace(/^0x/i, '').slice(0, 2 * Math.ceil(nState / 8)).padEnd(2 * Math.ceil(nState / 8), '0');

/** The other direction: a step's state bytes, right-padded to the kernel's bytes32. */
export const stateWord32 = (hex: string): string => '0x' + hex.replace(/^0x/i, '').padEnd(64, '0');

// ---------------------------------------------------------------------------------------------- routing

export const K1T = 1;
export const K1V = 2;
export const K2 = 4;
export const K2C = 8;
export const K2L = 16;
export const K3 = 32;
export const K5 = 64;
export const K2V = 128;

/** The envelope fields the routing reads. */
export interface RouteEnv {
  capT: number;
  allowCumBps: number;
  ceilMax: number;
  relMax: number;
  floorRel: number;
  floorMin: number;
}

export interface Routed {
  clamp: number;
  /** credited to the allowance payee */
  allow: bigint;
  /** part of fresh inflow sent to buy-and-lock */
  buyShare: bigint;
  /** part of the pre-settle reserve sent to buy-and-lock */
  release: bigint;
  buyDecided: bigint;
  /** part of fresh inflow that stays: holder share, reserve share, clipped excess, rounding dust */
  toReserve: bigint;
  /** if the whole decided buy executes */
  reserveAfter: bigint;
  /** effective (buy, hold, allow, reserve) shares in 1/256ths */
  shares: [number, number, number, number];
  /** effective REL */
  rel: number;
}

/**
 * One settle's routing of the regime asset (INTERFACE 8.2, kernel_model.route_tax). `cum` already includes
 * `inflow`; `allowPaidCum` is the allowance credited before this settle in the current regime. After graduation
 * kernel v1 pays no allowance: the T_ALLOW share joins the reserve share and K2, K2C, K2L are not evaluated.
 */
export function route(env: RouteEnv, outWord: bigint, inflow: bigint, reserve0: bigint, cum: bigint, allowPaidCum: bigint, graduated: boolean = false): Routed {
  const o = unpack(OUTPUT_FIELDS, outWord);
  let clamp = 0;
  let [tb, th, ta, tr] = [o.T_BUY, o.T_HOLD, o.T_ALLOW, o.T_RES];
  if (Math.max(tb, th, ta, tr) > 256 || tb + th + ta + tr !== 256) {
    [tb, th, ta, tr] = [0, 0, 0, 256];
    clamp |= K1T;
  }
  let allow = 0n;
  if (graduated) {
    tr += ta;
    ta = 0;
  } else {
    if (ta > env.capT) {
      tr += ta - env.capT;
      ta = env.capT;
      clamp |= K2;
    }
    allow = (inflow * BigInt(ta)) / 256n;
    if (o.CEIL !== LG8_MAX) {
      const own = exp8(o.CEIL);
      if (own < allow) allow = own;
    }
    if (env.ceilMax !== LG8_MAX && allow > exp8(env.ceilMax)) {
      allow = exp8(env.ceilMax);
      clamp |= K2C;
    }
    let room = (cum * BigInt(env.allowCumBps)) / 10000n - allowPaidCum;
    if (room < 0n) room = 0n;
    if (allow > room) {
      allow = room;
      clamp |= K2L;
    }
  }
  const buyShare = (inflow * BigInt(tb)) / 256n;
  const toReserve = inflow - allow - buyShare;
  let rel = o.REL;
  if (rel > env.relMax) {
    rel = env.relMax;
    clamp |= K3;
  }
  if (lg8(reserve0) >= env.floorMin && rel < env.floorRel) {
    rel = env.floorRel;
    clamp |= K5;
  }
  const release = (reserve0 * BigInt(rel)) / 256n;
  return {
    clamp,
    allow,
    buyShare,
    release,
    buyDecided: buyShare + release,
    toReserve,
    reserveAfter: reserve0 - release + toReserve,
    shares: [tb, th, ta, tr],
    rel,
  };
}

/** The output word the kernel applies when neither evaluator answers past the grace period (INTERFACE 8.4). */
export const fallbackWord = (fbAllow: number, relMax: number): bigint =>
  pack(OUTPUT_FIELDS, { T_BUY: 256 - fbAllow, T_ALLOW: fbAllow, REL: relMax, CEIL: LG8_MAX });

/** What each clamp bit means, in the words a holder reads. */
export const CLAMPS: readonly { bit: number; name: string; what: string }[] = [
  { bit: K1T, name: 'K1T', what: 'the tax shares did not sum to 256, so the whole inflow went to the reserve' },
  { bit: K1V, name: 'K1V', what: 'the revenue shares were malformed (kernel v2)' },
  { bit: K2, name: 'K2', what: 'the chip asked for a larger allowance share than capT; the excess stayed in the reserve' },
  { bit: K2C, name: 'K2C', what: "the allowance was above the envelope's per-settle ceiling and was cut to it" },
  { bit: K2L, name: 'K2L', what: 'the allowance was above the lifetime cap (allowCumBps of all inflow) and was cut to it' },
  { bit: K3, name: 'K3', what: 'the chip asked to release more of the reserve than relMax; the release was cut' },
  { bit: K5, name: 'K5', what: 'the chip released less than the floor while the reserve was above floorMin; the release was raised' },
  { bit: K2V, name: 'K2V', what: 'the revenue allowance was above capV (kernel v2)' },
];

/** Record flags (INTERFACE section 10). */
export const RECORD_FLAGS: readonly { bit: number; name: string; what: string }[] = [
  { bit: 1, name: 'fallback', what: 'neither evaluator answered past the grace period; the fallback word was applied' },
  { bit: 2, name: 'sealed', what: "the sealed evaluator's answer was used" },
  { bit: 4, name: 'claim failed', what: 'the vault held something and the claim failed' },
  { bit: 8, name: 'curve unread', what: 'the curve could not be read' },
  { bit: 16, name: 'buy skipped', what: 'a buy was skipped by a guard, or the capped amount was zero' },
  { bit: 32, name: 'buy failed', what: 'a buy, burn or swap failed or moved less than it was sent' },
  { bit: 64, name: 'graduated', what: 'written in the graduated regime (amounts are project tokens)' },
  { bit: 128, name: 'buy shrunk', what: 'a buy was shrunk by a cap' },
];

export const bitsOf = <T extends { bit: number }>(table: readonly T[], value: number): T[] => table.filter((t) => (value & t.bit) !== 0);
