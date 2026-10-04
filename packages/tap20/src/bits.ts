// Bit packing per TAP-20 section 5: bit i of a vector is bit (i mod 8) of byte floor(i / 8),
// least significant bit first.

/**
 * Read `n` bits from a packed byte string the way the deployed evaluator does: a bit whose
 * byte lies beyond the end of the string reads as 0; bytes and bits beyond `n` are ignored.
 * Returns one byte (0 or 1) per bit.
 */
export function unpackBits(bytes: ArrayLike<number>, n: number): Uint8Array {
  const out = new Uint8Array(n);
  const avail = Math.min(n, bytes.length * 8);
  for (let i = 0; i < avail; i++) out[i] = (bytes[i >>> 3] >>> (i & 7)) & 1;
  return out;
}

/**
 * Pack the first `n` entries of `bits` (anything truthy is a 1) into exactly ceil(n / 8)
 * bytes with the unused high bits of the last byte zero.
 */
export function packBits(bits: ArrayLike<number>, n: number = bits.length): Uint8Array {
  const out = new Uint8Array((n + 7) >>> 3);
  for (let i = 0; i < n; i++) if (bits[i]) out[i >>> 3] |= 1 << (i & 7);
  return out;
}

/** Bit `i` of a packed byte string, read leniently (0 beyond the end). */
export function getBit(bytes: ArrayLike<number>, i: number): 0 | 1 {
  const k = i >>> 3;
  return k < bytes.length && (bytes[k] >>> (i & 7)) & 1 ? 1 : 0;
}

/** Set bit `i` of a packed byte string in place. The byte must exist. */
export function setBit(bytes: Uint8Array, i: number, value: number | boolean): void {
  const k = i >>> 3;
  if (k >= bytes.length) throw new RangeError(`bit ${i} is beyond ${bytes.length} bytes`);
  if (value) bytes[k] |= 1 << (i & 7);
  else bytes[k] &= ~(1 << (i & 7));
}

/**
 * Normalise a leniently read byte string to the canonical form the contracts return:
 * exactly ceil(n / 8) bytes, padding bits zero.
 */
export function canonical(bytes: ArrayLike<number>, n: number): Uint8Array {
  const len = (n + 7) >>> 3;
  const out = new Uint8Array(len);
  const copy = Math.min(len, bytes.length);
  for (let i = 0; i < copy; i++) out[i] = bytes[i];
  if (n & 7 && len > 0) out[len - 1] &= (1 << (n & 7)) - 1;
  return out;
}

/** Number of bytes of a canonical packed vector of `n` bits. */
export function byteLength(n: number): number {
  return (n + 7) >>> 3;
}

const HEX = '0123456789abcdef';

/** Lower-case hex of a byte string, with a `0x` prefix unless `prefix` is false. */
export function bytesToHex(bytes: ArrayLike<number>, prefix: boolean = true): string {
  let s = prefix ? '0x' : '';
  for (let i = 0; i < bytes.length; i++) {
    const v = bytes[i];
    s += HEX[v >>> 4] + HEX[v & 15];
  }
  return s;
}

/** Parse hex (with or without `0x`). Throws on an odd length or a non-hex character. */
export function hexToBytes(hex: string): Uint8Array {
  let h = hex.trim();
  if (h.startsWith('0x') || h.startsWith('0X')) h = h.slice(2);
  if (h.length & 1) throw new SyntaxError('hex string has an odd number of digits');
  const out = new Uint8Array(h.length >>> 1);
  for (let i = 0; i < out.length; i++) {
    const hi = nibble(h.charCodeAt(2 * i));
    const lo = nibble(h.charCodeAt(2 * i + 1));
    if (hi < 0 || lo < 0) throw new SyntaxError(`not a hex digit at position ${hi < 0 ? 2 * i : 2 * i + 1}`);
    out[i] = (hi << 4) | lo;
  }
  return out;
}

function nibble(c: number): number {
  if (c >= 48 && c <= 57) return c - 48; // 0-9
  if (c >= 97 && c <= 102) return c - 87; // a-f
  if (c >= 65 && c <= 70) return c - 55; // A-F
  return -1;
}
