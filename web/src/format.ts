// Small pure helpers for turning chain values into text and text into chain values.

const ADDRESS = /0x[0-9a-fA-F]{40}(?![0-9a-fA-F])/;

export const isAddress = (s: string): boolean => /^0x[0-9a-fA-F]{40}$/.test(s);

/** 1234567 -> "1,234,567". Works for bigint and for integers as numbers. */
export function fmtInt(n: bigint | number): string {
  const s = n.toString();
  const neg = s.startsWith('-');
  const digits = neg ? s.slice(1) : s;
  let out = '';
  for (let i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 === 0) out += ',';
    out += digits[i];
  }
  return (neg ? '-' : '') + out;
}

/** A token amount in its smallest unit as a decimal string: 20000000000000 wei -> "0.00002". */
export function fmtUnits(value: bigint, decimals: number = 18): string {
  const neg = value < 0n;
  const v = neg ? -value : value;
  const base = 10n ** BigInt(decimals);
  const whole = fmtInt(v / base);
  const frac = (v % base).toString().padStart(decimals, '0').replace(/0+$/, '');
  return (neg ? '-' : '') + (frac ? `${whole}.${frac}` : whole);
}

export const shortAddress = (a: string): string => `${a.slice(0, 6)}…${a.slice(-4)}`;

/** Hex without the middle when it is long, for table cells. */
export function shortHex(hex: string, keep: number = 10): string {
  return hex.length <= 2 * keep + 5 ? hex : `${hex.slice(0, keep + 2)}…${hex.slice(-keep)}`;
}

export interface Target {
  processor: string;
  /** Circuit id as a decimal string, or null to open the processor itself. */
  id: string | null;
}

/**
 * What the user typed or pasted into the "open" box: an address, optionally followed by a
 * circuit id ("0xabc… 3", "0xabc…/3", "0xabc…#3"), or a URL that contains an address.
 */
export function parseTarget(text: string): Target | null {
  const m = ADDRESS.exec(text);
  if (!m) return null;
  const rest = text.slice(m.index + m[0].length);
  const id = /^[\s/#:,]*(?:circuit|id|token)?[\s/#:=]*(\d{1,20})\s*$/i.exec(rest);
  return { processor: m[0], id: id ? BigInt(id[1]).toString() : null };
}

/** `#/c/<processor>/<id>` or `#/p/<processor>`. */
export const targetHash = (t: Target): string => (t.id === null ? `#/p/${t.processor}` : `#/c/${t.processor}/${t.id}`);

/** Normalise hex typed by a user to an even number of lower-case digits, or null if it is not hex. */
export function cleanHex(text: string): string | null {
  const h = text.trim().replace(/^0x/i, '').replace(/[\s_]/g, '').toLowerCase();
  if (!/^[0-9a-f]*$/.test(h) || h.length % 2 === 1) return null;
  return h;
}

/** A unix time as "2026-10-06 14:05 UTC". */
export const fmtTime = (t: number): string => new Date(t * 1000).toISOString().slice(0, 16).replace('T', ' ') + ' UTC';

/** Seconds as "3 d 4 h", "12 min 5 s", "45 s"; a zero remainder is left out ("15 min", "2 h", "1 d"). */
export function fmtDuration(s: number): string {
  s = Math.max(0, Math.floor(s));
  const two = (a: number, ua: string, b: number, ub: string): string => (b === 0 ? `${a} ${ua}` : `${a} ${ua} ${b} ${ub}`);
  if (s >= 86400) return two(Math.floor(s / 86400), 'd', Math.floor((s % 86400) / 3600), 'h');
  if (s >= 3600) return two(Math.floor(s / 3600), 'h', Math.floor((s % 3600) / 60), 'min');
  if (s >= 60) return two(Math.floor(s / 60), 'min', s % 60, 's');
  return `${s} s`;
}
