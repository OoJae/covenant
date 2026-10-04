// Hand-written ABI encoding and decoding for exactly the calls this project makes.
// Everything works on hex strings; no general ABI machinery.

export const strip = (h: string): string => h.replace(/^0x/i, '');

/** One 32-byte word holding an unsigned integer. */
export const word = (v: number | bigint): string => BigInt(v).toString(16).padStart(64, '0');

/** One 32-byte word holding an address. */
export const addressWord = (a: string): string => strip(a).toLowerCase().padStart(64, '0');

/** A dynamic `bytes` value: length word, then the data right-padded to a multiple of 32 bytes. */
export const bytesTail = (hex: string): string => {
  const h = strip(hex);
  return word(h.length / 2) + h.padEnd(Math.ceil(h.length / 64) * 64, '0');
};

// `n` bytes of return data `r` (hex without 0x) starting at byte offset `o`. Refuses to read
// past the end, so short or empty return data throws instead of decoding to garbage.
const cut = (r: string, o: number, n: number): string => {
  const s = r.slice(o * 2, (o + n) * 2);
  if (s.length < n * 2) throw new Error('ABI: return data too short');
  return s;
};
const num = (r: string, o: number): number => parseInt(cut(r, o, 32), 16);
// The dynamic bytes whose length word is at byte offset `o`.
const dyn = (r: string, o: number): string => '0x' + cut(r, o + 32, num(r, o));

export const toBytes = (hex: string): Uint8Array => {
  const h = strip(hex);
  const out = new Uint8Array(h.length >> 1);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(2 * i, 2 * i + 2), 16);
  return out;
};

export const toHex = (bytes: ArrayLike<number>): string => {
  let s = '0x';
  for (let i = 0; i < bytes.length; i++) s += (bytes[i] | 256).toString(16).slice(1);
  return s;
};

export const decUint = (ret: string): bigint => BigInt('0x' + cut(strip(ret), 0, 32));
export const decBool = (ret: string): boolean => decUint(ret) !== 0n;
export const decAddress = (ret: string): string => '0x' + cut(strip(ret), 12, 20);
export const decBytes = (ret: string): string => {
  const r = strip(ret);
  return dyn(r, num(r, 0));
};
export const decString = (ret: string): string => new TextDecoder().decode(toBytes(decBytes(ret)));

export interface CircuitInfo {
  nIn: number;
  nOut: number;
  nState: number;
  gateCount: number;
}
/** `circuitInfo(uint256)` returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount). */
export const decCircuitInfo = (ret: string): CircuitInfo => {
  const r = strip(ret);
  return { nIn: num(r, 0), nOut: num(r, 32), nState: num(r, 64), gateCount: num(r, 96) };
};

export interface StepResult {
  newState: string;
  outputs: string;
}
/** `step(uint256,bytes,bytes)` returns (bytes newState, bytes outputs). */
export const decStep = (ret: string): StepResult => {
  const r = strip(ret);
  return { newState: dyn(r, num(r, 0)), outputs: dyn(r, num(r, 32)) };
};

/** Calldata for Multicall3 `aggregate3((address target, bool allowFailure, bytes callData)[])`. */
export const encAggregate3 = (calls: readonly { to: string; data: string }[], allowFailure: boolean = true): string => {
  let heads = '';
  let tails = '';
  for (const c of calls) {
    heads += word(calls.length * 32 + tails.length / 2);
    tails += addressWord(c.to) + word(allowFailure ? 1 : 0) + word(96) + bytesTail(c.data);
  }
  return '0x82ad56cb' + word(32) + word(calls.length) + heads + tails;
};

export interface SubResult {
  success: boolean;
  data: string;
}
/** Return data of `aggregate3`: (bool success, bytes returnData)[]. */
export const decAggregate3 = (ret: string): SubResult[] => {
  const r = strip(ret);
  const base = num(r, 0) + 32; // first byte after the array length; element offsets count from here
  const n = num(r, base - 32);
  const out: SubResult[] = [];
  for (let i = 0; i < n; i++) {
    const t = base + num(r, base + 32 * i);
    out.push({ success: num(r, t) !== 0, data: dyn(r, t + num(r, t + 32)) });
  }
  return out;
};

/** Human-readable reason from revert data: `Error(string)`, `Panic(uint256)`, or the raw hex. */
export const revertReason = (data: string | undefined): string => {
  const r = strip(data ?? '');
  try {
    if (r.startsWith('08c379a0')) return decString(r.slice(8));
    if (r.startsWith('4e487b71')) return 'panic 0x' + decUint(r.slice(8)).toString(16);
  } catch {
    // fall through to the raw data
  }
  return r ? 'reverted with 0x' + r : 'reverted';
};
