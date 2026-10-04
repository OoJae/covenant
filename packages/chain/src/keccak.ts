// Keccak-256 (the Ethereum hash, original Keccak padding 0x01, not SHA-3's 0x06) and the
// EIP-55 address checksum. Written from the Keccak specification; 64-bit lanes are held as
// (low, high) pairs of 32-bit words. Kept out of the package's main entry so the RPC client
// stays small; import from '@covenant/chain/keccak'.

// Round constants, as (low, high) 32-bit halves.
const RC = new Uint32Array([
  0x00000001, 0x00000000, 0x00008082, 0x00000000, 0x0000808a, 0x80000000, 0x80008000, 0x80000000,
  0x0000808b, 0x00000000, 0x80000001, 0x00000000, 0x80008081, 0x80000000, 0x00008009, 0x80000000,
  0x0000008a, 0x00000000, 0x00000088, 0x00000000, 0x80008009, 0x00000000, 0x8000000a, 0x00000000,
  0x8000808b, 0x00000000, 0x0000008b, 0x80000000, 0x00008089, 0x80000000, 0x00008003, 0x80000000,
  0x00008002, 0x80000000, 0x00000080, 0x80000000, 0x0000800a, 0x00000000, 0x8000000a, 0x80000000,
  0x80008081, 0x80000000, 0x00008080, 0x80000000, 0x80000001, 0x00000000, 0x80008008, 0x80000000,
]);
// Rho rotation offsets and the pi lane permutation, both in the order the rho-pi chain visits lanes.
const ROT = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44];
const PI = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1];

// Keccak-f[1600] on 25 lanes stored as s[2i] = low half, s[2i + 1] = high half.
function permute(s: Uint32Array): void {
  const c = new Uint32Array(10);
  for (let round = 0; round < 24; round++) {
    // theta
    for (let x = 0; x < 10; x++) c[x] = s[x] ^ s[x + 10] ^ s[x + 20] ^ s[x + 30] ^ s[x + 40];
    for (let x = 0; x < 5; x++) {
      const p = ((x + 4) % 5) * 2;
      const q = ((x + 1) % 5) * 2;
      const dl = c[p] ^ ((c[q] << 1) | (c[q + 1] >>> 31));
      const dh = c[p + 1] ^ ((c[q + 1] << 1) | (c[q] >>> 31));
      for (let y = 0; y < 50; y += 10) {
        s[y + 2 * x] ^= dl;
        s[y + 2 * x + 1] ^= dh;
      }
    }
    // rho and pi
    let l = s[2];
    let h = s[3];
    for (let i = 0; i < 24; i++) {
      const j = PI[i] * 2;
      const n = ROT[i];
      const tl = s[j];
      const th = s[j + 1];
      if (n < 32) {
        s[j] = (l << n) | (h >>> (32 - n));
        s[j + 1] = (h << n) | (l >>> (32 - n));
      } else {
        // n is never exactly 32
        s[j] = (h << (n - 32)) | (l >>> (64 - n));
        s[j + 1] = (l << (n - 32)) | (h >>> (64 - n));
      }
      l = tl;
      h = th;
    }
    // chi
    for (let y = 0; y < 50; y += 10) {
      for (let x = 0; x < 10; x++) c[x] = s[y + x];
      for (let x = 0; x < 5; x++) {
        const p = ((x + 1) % 5) * 2;
        const q = ((x + 2) % 5) * 2;
        s[y + 2 * x] = c[2 * x] ^ (~c[p] & c[q]);
        s[y + 2 * x + 1] = c[2 * x + 1] ^ (~c[p + 1] & c[q + 1]);
      }
    }
    // iota
    s[0] ^= RC[2 * round];
    s[1] ^= RC[2 * round + 1];
  }
}

const RATE = 136; // bytes absorbed per permutation for a 256-bit digest

export function keccak256(data: ArrayLike<number>): Uint8Array {
  const s = new Uint32Array(50);
  const len = data.length;
  let off = 0;
  for (; off + RATE <= len; off += RATE) {
    for (let i = 0; i < RATE; i++) s[i >> 2] ^= data[off + i] << (8 * (i & 3));
    permute(s);
  }
  const rem = len - off;
  for (let i = 0; i < rem; i++) s[i >> 2] ^= data[off + i] << (8 * (i & 3));
  s[rem >> 2] ^= 0x01 << (8 * (rem & 3));
  s[(RATE - 1) >> 2] ^= 0x80 << (8 * ((RATE - 1) & 3));
  permute(s);
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i++) out[i] = (s[i >> 2] >>> (8 * (i & 3))) & 255;
  return out;
}

/** keccak256 as lower-case hex with 0x. */
export function keccak256Hex(data: ArrayLike<number>): string {
  const d = keccak256(data);
  let s = '0x';
  for (let i = 0; i < 32; i++) s += (d[i] | 256).toString(16).slice(1);
  return s;
}

/** EIP-55 mixed-case checksum form of an address. */
export function checksumAddress(address: string): string {
  const a = address.replace(/^0x/i, '').toLowerCase();
  const h = keccak256Hex(new TextEncoder().encode(a));
  let out = '0x';
  for (let i = 0; i < a.length; i++) out += parseInt(h[2 + i], 16) >= 8 ? a[i].toUpperCase() : a[i];
  return out;
}
