// Small hex, address and amount helpers shared by launch-check and audit-team.
// Everything is a hex string or a bigint; no dependencies beyond the repository's own keccak.

import { checksumAddress } from '../../packages/chain/src/keccak.ts';

export const strip0x = (h: string): string => (h.startsWith('0x') || h.startsWith('0X') ? h.slice(2) : h);

/** True for an even-length string of hex digits (after an optional 0x). */
export const isHex = (s: string): boolean => /^(0x)?([0-9a-fA-F]{2})*$/.test(s);

export function hexToBytes(hex: string): Uint8Array {
  const h = strip0x(hex);
  if (!/^([0-9a-fA-F]{2})*$/.test(h)) throw new Error('not a hex string of whole bytes');
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(2 * i, 2 * i + 2), 16);
  return out;
}

export function bytesToHex(bytes: ArrayLike<number>): string {
  let s = '0x';
  for (let i = 0; i < bytes.length; i++) s += (bytes[i] | 256).toString(16).slice(1);
  return s;
}

/** One 32-byte ABI word (64 hex digits, no 0x) holding an unsigned integer. */
export function word(v: bigint | number): string {
  const b = BigInt(v);
  if (b < 0n || b >= 1n << 256n) throw new Error('value does not fit in 256 bits');
  return b.toString(16).padStart(64, '0');
}

/** One 32-byte ABI word holding an address. */
export const addressWord = (a: string): string => strip0x(a).toLowerCase().padStart(64, '0');

export const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';

/**
 * Validates an address typed by a human and returns it in lower case.
 * A mixed-case address must carry a correct EIP-55 checksum, so a typo is caught;
 * an all-lower-case or all-upper-case address is accepted as it is.
 */
export function parseAddress(s: string, what: string = 'address'): string {
  const t = s.trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(t)) throw new Error(`${what}: "${s}" is not a 20-byte hex address`);
  const body = t.slice(2);
  const mixed = body !== body.toLowerCase() && body !== body.toUpperCase();
  if (mixed && checksumAddress(t) !== t) {
    throw new Error(`${what}: "${s}" has a wrong EIP-55 checksum (a character was mistyped, or the case was changed)`);
  }
  return '0x' + body.toLowerCase();
}

/** EIP-55 display form. */
export const show = (a: string): string => checksumAddress(a);

export const sameAddress = (a: string, b: string): boolean => strip0x(a).toLowerCase() === strip0x(b).toLowerCase();

/** Wei as a decimal OKB amount, exact, without trailing zeros. */
export function formatOkb(wei: bigint): string {
  const neg = wei < 0n;
  const v = neg ? -wei : wei;
  const whole = v / 10n ** 18n;
  const frac = (v % 10n ** 18n).toString().padStart(18, '0').replace(/0+$/, '');
  return (neg ? '-' : '') + whole.toString() + (frac ? '.' + frac : '');
}

/**
 * A transaction value typed by a human: decimal wei ("0", "400000000000000000"), hex wei ("0x58d1..."),
 * or an OKB amount with the unit written out ("0.4okb", "0.4 OKB"). Exact; never goes through a float.
 */
export function parseValue(s: string): bigint {
  const t = s.trim();
  const okb = /^([0-9]+)(?:\.([0-9]{1,18}))?\s*okb$/i.exec(t);
  if (okb) return BigInt(okb[1]) * 10n ** 18n + BigInt((okb[2] ?? '').padEnd(18, '0') || '0');
  if (/^0x[0-9a-fA-F]+$/.test(t)) return BigInt(t);
  if (/^[0-9]+$/.test(t)) return BigInt(t);
  throw new Error(`value: "${s}" is not a wei amount (decimal or 0x hex) or an OKB amount such as "0.4okb"`);
}

/** Seconds as "2 h 5 min 7 s". */
export function formatDuration(seconds: bigint): string {
  const neg = seconds < 0n;
  let s = neg ? -seconds : seconds;
  const d = s / 86400n;
  s %= 86400n;
  const h = s / 3600n;
  s %= 3600n;
  const m = s / 60n;
  s %= 60n;
  const parts: string[] = [];
  if (d) parts.push(`${d} d`);
  if (h) parts.push(`${h} h`);
  if (m) parts.push(`${m} min`);
  if (s || !parts.length) parts.push(`${s} s`);
  return (neg ? '-' : '') + parts.join(' ');
}

/** Unix seconds as "2026-10-04 18:20:36 UTC". */
export function formatUtc(unixSeconds: bigint | number): string {
  const ms = Number(unixSeconds) * 1000;
  if (!Number.isFinite(ms) || Math.abs(ms) > 8.64e15) return `timestamp ${unixSeconds}`;
  return new Date(ms).toISOString().replace('T', ' ').replace(/\.\d+Z$/, ' UTC');
}

/** A string with every character outside printable ASCII written as an escape, so nothing is invisible. */
export function visible(s: string): string {
  let out = '';
  for (const ch of s) {
    const c = ch.codePointAt(0) as number;
    if (c >= 0x20 && c < 0x7f && ch !== '\\') out += ch;
    else if (ch === '\\') out += '\\\\';
    else out += c <= 0xffff ? '\\u' + c.toString(16).padStart(4, '0') : '\\u{' + c.toString(16) + '}';
  }
  return out;
}

/** True when the string is printable ASCII only. */
export const isPlainAscii = (s: string): boolean => /^[\x20-\x7e]*$/.test(s);
