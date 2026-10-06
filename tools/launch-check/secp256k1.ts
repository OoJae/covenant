// secp256k1 public-key recovery (the EVM's ecrecover), in BigInt arithmetic. Verification only:
// this module cannot sign and never sees a private key.
//
// test/secp256k1.test.ts checks it against real X Layer data: the sender of a real transaction is
// recovered from its (r, s, yParity), and the IGNIX platform signer from real createToken signatures.

import { keccak256 } from '../../packages/chain/src/keccak.ts';
import { bytesToHex } from './hex.ts';

export const P = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2fn;
export const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const GX = 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798n;
const GY = 0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8n;

const mod = (a: bigint, m: bigint): bigint => ((a % m) + m) % m;

function pow(base: bigint, exp: bigint, m: bigint): bigint {
  let result = 1n;
  let b = mod(base, m);
  let e = exp;
  while (e > 0n) {
    if (e & 1n) result = (result * b) % m;
    b = (b * b) % m;
    e >>= 1n;
  }
  return result;
}

/** Modular inverse for a prime modulus. */
const inv = (a: bigint, m: bigint): bigint => pow(a, m - 2n, m);

/** A point in Jacobian coordinates; z = 0 is the point at infinity. */
type Jac = readonly [x: bigint, y: bigint, z: bigint];
const INFINITY: Jac = [0n, 1n, 0n];

function double(p: Jac): Jac {
  const [x, y, z] = p;
  if (z === 0n || y === 0n) return INFINITY;
  const yy = (y * y) % P;
  const s = (4n * x * yy) % P;
  const m = (3n * x * x) % P; // a = 0 for secp256k1
  const nx = mod(m * m - 2n * s, P);
  const ny = mod(m * (s - nx) - 8n * yy * yy, P);
  const nz = (2n * y * z) % P;
  return [nx, ny, nz];
}

function add(p: Jac, q: Jac): Jac {
  if (p[2] === 0n) return q;
  if (q[2] === 0n) return p;
  const [x1, y1, z1] = p;
  const [x2, y2, z2] = q;
  const z1z1 = (z1 * z1) % P;
  const z2z2 = (z2 * z2) % P;
  const u1 = (x1 * z2z2) % P;
  const u2 = (x2 * z1z1) % P;
  const s1 = (y1 * z2 * z2z2) % P;
  const s2 = (y2 * z1 * z1z1) % P;
  if (u1 === u2) return s1 === s2 ? double(p) : INFINITY;
  const h = mod(u2 - u1, P);
  const r = mod(s2 - s1, P);
  const hh = (h * h) % P;
  const hhh = (hh * h) % P;
  const v = (u1 * hh) % P;
  const nx = mod(r * r - hhh - 2n * v, P);
  const ny = mod(r * (v - nx) - s1 * hhh, P);
  const nz = (h * z1 * z2) % P;
  return [nx, ny, nz];
}

function multiply(p: Jac, k: bigint): Jac {
  let result: Jac = INFINITY;
  let addend = p;
  let e = mod(k, N);
  while (e > 0n) {
    if (e & 1n) result = add(result, addend);
    addend = double(addend);
    e >>= 1n;
  }
  return result;
}

function affine(p: Jac): { x: bigint; y: bigint } | null {
  if (p[2] === 0n) return null;
  const zi = inv(p[2], P);
  const zi2 = (zi * zi) % P;
  return { x: (p[0] * zi2) % P, y: (p[1] * zi2 * zi) % P };
}

const bytesToBig = (b: ArrayLike<number>): bigint => {
  let v = 0n;
  for (let i = 0; i < b.length; i++) v = (v << 8n) | BigInt(b[i]);
  return v;
};

const bigTo32 = (v: bigint): Uint8Array => {
  const out = new Uint8Array(32);
  let x = v;
  for (let i = 31; i >= 0; i--) {
    out[i] = Number(x & 255n);
    x >>= 8n;
  }
  return out;
};

/** The address of an uncompressed public key: the last 20 bytes of keccak256(x || y). */
export function addressOfPoint(x: bigint, y: bigint): string {
  const pub = new Uint8Array(64);
  pub.set(bigTo32(x), 0);
  pub.set(bigTo32(y), 32);
  return bytesToHex(keccak256(pub).slice(12));
}

/**
 * ecrecover. `yParity` is 0 or 1 (v - 27). Returns the signer's address in lower case, or null when the
 * values are not a valid signature (exactly the cases in which the EVM precompile returns nothing).
 */
export function recoverAddress(hash: ArrayLike<number>, r: bigint, s: bigint, yParity: number): string | null {
  if (hash.length !== 32) throw new Error('recoverAddress: the hash must be 32 bytes');
  if (yParity !== 0 && yParity !== 1) return null;
  if (r <= 0n || r >= N || s <= 0n || s >= N) return null;
  // R = (r, y) with the requested parity. (r + N as an x coordinate is never used on Ethereum: v is 27 or 28.)
  const y2 = mod(r * r * r + 7n, P);
  let y = pow(y2, (P + 1n) / 4n, P);
  if ((y * y) % P !== y2) return null; // r is not the x coordinate of a curve point
  if (Number(y & 1n) !== yParity) y = P - y;
  const z = mod(bytesToBig(hash), N);
  const rInv = inv(r, N);
  const u1 = mod(-z * rInv, N);
  const u2 = mod(s * rInv, N);
  const q = affine(add(multiply([GX, GY, 1n], u1), multiply([r, y, 1n], u2)));
  if (!q) return null;
  return addressOfPoint(q.x, q.y);
}

export interface SignatureCheck {
  /** The recovered signer, or null. */
  signer: string | null;
  /** Why OpenZeppelin's ECDSA.recover (used by IgnixManager) would revert, or null if it would not. */
  problem: string | null;
}

/**
 * What `ECDSA.recover(digest, signature)` of OpenZeppelin 5 does with a 65-byte `r || s || v` signature:
 * it reverts unless the length is 65, s is in the lower half of the curve order, and ecrecover yields an address.
 */
export function recoverFromSignature(digest: ArrayLike<number>, signature: Uint8Array): SignatureCheck {
  if (signature.length !== 65) return { signer: null, problem: `the signature is ${signature.length} bytes, not 65` };
  const r = bytesToBig(signature.slice(0, 32));
  const s = bytesToBig(signature.slice(32, 64));
  const v = signature[64];
  if (s > N / 2n) return { signer: null, problem: 'the signature has a high s value (ECDSAInvalidSignatureS)' };
  if (v !== 27 && v !== 28) return { signer: null, problem: `the signature's v byte is ${v}, not 27 or 28` };
  const signer = recoverAddress(digest, r, s, v - 27);
  return signer ? { signer, problem: null } : { signer: null, problem: 'the signature does not recover to any address' };
}

// Exported for the tests, which build a throwaway signer for a local fork.
export const _internal = { GX, GY, multiply, affine, inv, mod, bytesToBig, bigTo32 };
