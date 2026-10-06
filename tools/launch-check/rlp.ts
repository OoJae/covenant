// RLP encoding, the address a CREATE gives, and the hashes that Ethereum signatures cover.
// Used by the tests (recovering the sender of a real transaction) and by audit-team (labelling contract
// creations and explaining nonces consumed by EIP-7702 authorisations).

import { keccak256 } from '../../packages/chain/src/keccak.ts';
import { bytesToHex, hexToBytes, strip0x } from './hex.ts';

export type RlpInput = Uint8Array | readonly RlpInput[];

/** Big-endian bytes of an unsigned integer with no leading zero byte; zero is the empty string. */
export function intBytes(v: bigint | number | string): Uint8Array {
  let x = BigInt(v);
  if (x < 0n) throw new Error('rlp: negative integer');
  const out: number[] = [];
  while (x > 0n) {
    out.unshift(Number(x & 255n));
    x >>= 8n;
  }
  return Uint8Array.from(out);
}

function lengthPrefix(length: number, base: number): Uint8Array {
  if (length < 56) return Uint8Array.of(base + length);
  const len = intBytes(length);
  return Uint8Array.of(base + 55 + len.length, ...len);
}

function concat(parts: readonly Uint8Array[]): Uint8Array {
  let total = 0;
  for (const p of parts) total += p.length;
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

export function rlpEncode(input: RlpInput): Uint8Array {
  if (input instanceof Uint8Array) {
    if (input.length === 1 && input[0] < 0x80) return input;
    return concat([lengthPrefix(input.length, 0x80), input]);
  }
  const body = concat(input.map(rlpEncode));
  return concat([lengthPrefix(body.length, 0xc0), body]);
}

/** The address of a contract created by `sender` with a plain CREATE at `nonce`. */
export function createAddress(sender: string, nonce: bigint | number): string {
  return bytesToHex(keccak256(rlpEncode([hexToBytes(sender), intBytes(nonce)])).slice(12));
}

/** The JSON-RPC shape of a transaction, as far as signing hashes need it. */
export interface RpcTransaction {
  type?: string;
  chainId?: string;
  nonce: string;
  gasPrice?: string;
  maxPriorityFeePerGas?: string;
  maxFeePerGas?: string;
  gas: string;
  to?: string | null;
  value: string;
  input: string;
  accessList?: { address: string; storageKeys: string[] }[];
  authorizationList?: RpcAuthorization[];
  v?: string;
  r: string;
  s: string;
  yParity?: string;
}

export interface RpcAuthorization {
  chainId: string;
  address: string;
  nonce: string;
  yParity?: string;
  v?: string;
  r: string;
  s: string;
}

const accessList = (list: RpcTransaction['accessList']): RlpInput =>
  (list ?? []).map((e) => [hexToBytes(e.address), e.storageKeys.map((k) => hexToBytes(k))]);

const authList = (list: readonly RpcAuthorization[]): RlpInput =>
  list.map((a) => [
    intBytes(a.chainId),
    hexToBytes(a.address),
    intBytes(a.nonce),
    intBytes(a.yParity ?? a.v ?? '0x0'),
    intBytes(a.r),
    intBytes(a.s),
  ]);

const toField = (to: string | null | undefined): Uint8Array => (to ? hexToBytes(to) : new Uint8Array(0));

/**
 * The hash a transaction's signature covers, and the signature's y parity.
 * Supports legacy (with and without EIP-155), EIP-2930, EIP-1559 and EIP-7702 transactions.
 */
export function signingHash(tx: RpcTransaction): { hash: Uint8Array; yParity: number } {
  const type = Number(BigInt(tx.type ?? '0x0'));
  const data = hexToBytes(tx.input);
  if (type === 0) {
    const v = BigInt(tx.v ?? '0x1b');
    const base: RlpInput[] = [intBytes(tx.nonce), intBytes(tx.gasPrice ?? '0x0'), intBytes(tx.gas), toField(tx.to), intBytes(tx.value), data];
    if (v === 27n || v === 28n) return { hash: keccak256(rlpEncode(base)), yParity: Number(v - 27n) };
    const chainId = (v - 35n) / 2n;
    const hash = keccak256(rlpEncode([...base, intBytes(chainId), new Uint8Array(0), new Uint8Array(0)]));
    return { hash, yParity: Number((v - 35n) % 2n) };
  }
  const yParity = Number(BigInt(tx.yParity ?? tx.v ?? '0x0'));
  const chainId = intBytes(tx.chainId ?? '0x0');
  let fields: RlpInput[];
  if (type === 1) {
    fields = [chainId, intBytes(tx.nonce), intBytes(tx.gasPrice ?? '0x0'), intBytes(tx.gas), toField(tx.to), intBytes(tx.value), data, accessList(tx.accessList)];
  } else if (type === 2 || type === 4) {
    fields = [
      chainId,
      intBytes(tx.nonce),
      intBytes(tx.maxPriorityFeePerGas ?? '0x0'),
      intBytes(tx.maxFeePerGas ?? '0x0'),
      intBytes(tx.gas),
      toField(tx.to),
      intBytes(tx.value),
      data,
      accessList(tx.accessList),
    ];
    if (type === 4) fields.push(authList(tx.authorizationList ?? []));
  } else {
    throw new Error(`signingHash: transaction type ${type} is not supported`);
  }
  const body = rlpEncode(fields);
  const prefixed = new Uint8Array(body.length + 1);
  prefixed[0] = type;
  prefixed.set(body, 1);
  return { hash: keccak256(prefixed), yParity };
}

/** The hash an EIP-7702 authorisation signature covers: keccak256(0x05 || rlp([chainId, address, nonce])). */
export function authorizationHash(a: RpcAuthorization): Uint8Array {
  const body = rlpEncode([intBytes(a.chainId), hexToBytes(a.address), intBytes(a.nonce)]);
  const prefixed = new Uint8Array(body.length + 1);
  prefixed[0] = 0x05;
  prefixed.set(body, 1);
  return keccak256(prefixed);
}

export const hex32 = (v: string): bigint => BigInt('0x' + (strip0x(v) || '0'));
