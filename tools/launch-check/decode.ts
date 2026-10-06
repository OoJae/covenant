// Decoder and encoder for IgnixManager.createToken calldata.
//
// The layout is taken from the verified Manager source vendored in
// contracts/vendor/ignix-xlayer/src/launch/IgnixManager.sol (struct CreateParams and createToken) and from
// contracts/probes/src/interfaces/IIgnix.sol. test/decode.test.ts proves it on real mainnet launches:
// every decoded field equals what the chain shows, the calldata re-encodes byte for byte, and the platform
// signature recovers to the Manager's signer over the digest built from the decoded fields.
//
// The decoder follows offsets the way the Solidity ABI decoder does, and refuses what Solidity refuses:
// data that is too short, offsets that point outside the calldata, and values with bits set above their
// type (a uint16 word greater than 65535 makes the real call revert).

import { keccak256 } from '../../packages/chain/src/keccak.ts';
import { addressWord, bytesToHex, hexToBytes, isHex, strip0x, word } from './hex.ts';

/** IgnixManager proxy on X Layer (chain 196). */
export const MANAGER = '0x96b51c57e5346d0c0198899243cf851d1e23c309';

export const CREATE_TOKEN_SIGNATURE =
  'createToken((string,string,string,bytes32,address,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint256,uint256,uint16,uint32,bytes32),uint16,bytes,uint64,address,uint8,uint64,bytes)';

/** First four bytes of keccak256(CREATE_TOKEN_SIGNATURE). Recomputed below; a mismatch stops the module. */
export const CREATE_TOKEN_SELECTOR = '0xef44bdf2';

const utf8 = new TextEncoder();
export const selectorOf = (signature: string): string => bytesToHex(keccak256(utf8.encode(signature)).slice(0, 4));

if (selectorOf(CREATE_TOKEN_SIGNATURE) !== CREATE_TOKEN_SELECTOR) {
  throw new Error('decode.ts: the createToken signature does not hash to 0xef44bdf2');
}

export class DecodeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'DecodeError';
  }
}

/** `IgnixManager.CreateParams`, in declaration order. */
export interface CreateParams {
  /** Decoded as UTF-8. If the bytes are not valid UTF-8 the replacement character appears and `textOk` is false. */
  name: string;
  symbol: string;
  metadataURI: string;
  /** The exact bytes of the three strings (0x hex). These, not the decoded text, are what is re-encoded. */
  nameHex: string;
  symbolHex: string;
  metadataURIHex: string;
  /** False when one of the three strings is not valid UTF-8. */
  textOk: boolean;
  salt: string; // bytes32
  quote: string; // address, lower case; the zero address is native OKB
  graduation: bigint;
  buyFeeBps: number;
  sellFeeBps: number;
  taxBuyBps: number;
  taxSellBps: number;
  snipeStartBps: number;
  snipeMins: number;
  listingFee: bigint;
  firstBuy: bigint;
  founderBps: number;
  founderSecs: number;
  founderRoot: string; // bytes32
}

/** Every argument of `createToken`, in declaration order. */
export interface CreateTokenCall {
  p: CreateParams;
  templateId: number;
  vaultData: string; // 0x hex
  deadline: bigint;
  factory: string; // address, lower case
  venue: number;
  graduationProtectionSecs: bigint;
  sig: string; // 0x hex
}

const HEAD_WORDS = 8;
const PARAM_WORDS = 17;

class Reader {
  readonly hex: string;
  readonly size: number; // bytes

  constructor(hex: string) {
    this.hex = hex;
    this.size = hex.length / 2;
  }

  word(at: number, what: string): bigint {
    if (at < 0 || at + 32 > this.size) throw new DecodeError(`${what}: the calldata ends before byte ${at + 32} of the arguments`);
    return BigInt('0x' + this.hex.slice(at * 2, at * 2 + 64));
  }

  uint(at: number, bits: number, what: string): bigint {
    const v = this.word(at, what);
    if (v >> BigInt(bits) !== 0n) {
      throw new DecodeError(`${what}: the word 0x${v.toString(16)} does not fit uint${bits}; the real call would revert`);
    }
    return v;
  }

  small(at: number, bits: number, what: string): number {
    return Number(this.uint(at, bits, what));
  }

  address(at: number, what: string): string {
    return '0x' + this.uint(at, 160, what).toString(16).padStart(40, '0');
  }

  bytes32(at: number, what: string): string {
    return '0x' + this.word(at, what).toString(16).padStart(64, '0');
  }

  /** A dynamic `bytes` or `string` whose length word is at `at`. Returns the data as hex without 0x. */
  dynamic(at: number, what: string): string {
    const len = this.word(at, what + ' length');
    if (len > 0xffffffffffffffffn || at + 32 + Number(len) > this.size) {
      throw new DecodeError(`${what}: length ${len} runs past the end of the calldata`);
    }
    const start = (at + 32) * 2;
    return this.hex.slice(start, start + Number(len) * 2);
  }

  /** An offset word: must be small enough to be a position inside the calldata. */
  offset(at: number, what: string): number {
    const o = this.word(at, what + ' offset');
    if (o > BigInt(this.size)) throw new DecodeError(`${what}: offset ${o} points outside the calldata`);
    return Number(o);
  }
}

const decoder = new TextDecoder('utf-8', { fatal: true });
const lossy = new TextDecoder('utf-8', { fatal: false });

function text(hex: string): { text: string; ok: boolean } {
  const bytes = hexToBytes(hex);
  try {
    return { text: decoder.decode(bytes), ok: true };
  } catch {
    return { text: lossy.decode(bytes), ok: false };
  }
}

/** Lower-cases, validates and splits calldata into its selector and its argument bytes. */
export function splitCalldata(data: string): { selector: string; args: string } {
  const t = data.trim();
  if (!isHex(t)) throw new DecodeError('the calldata is not a hex string of whole bytes');
  const h = strip0x(t).toLowerCase();
  if (h.length < 8) throw new DecodeError('the calldata is shorter than a 4-byte function selector');
  return { selector: '0x' + h.slice(0, 8), args: h.slice(8) };
}

/**
 * Decodes `createToken` calldata (selector included). Throws `DecodeError` when the selector is another
 * function or when the Solidity decoder would reject the data.
 */
export function decodeCreateToken(data: string): CreateTokenCall {
  const { selector, args } = splitCalldata(data);
  if (selector !== CREATE_TOKEN_SELECTOR) {
    throw new DecodeError(`selector ${selector} is not createToken (${CREATE_TOKEN_SELECTOR})`);
  }
  const r = new Reader(args);
  if (r.size < HEAD_WORDS * 32) throw new DecodeError('the calldata is shorter than the eight argument words of createToken');

  // head: (offset p, templateId, offset vaultData, deadline, factory, venue, graduationProtectionSecs, offset sig)
  const pAt = r.offset(0, 'p');
  if (pAt + PARAM_WORDS * 32 > r.size) throw new DecodeError('p: the 17 words of CreateParams run past the end of the calldata');
  const templateId = r.small(32, 16, 'templateId');
  const vaultDataAt = r.offset(64, 'vaultData');
  const deadline = r.uint(96, 64, 'deadline');
  const factory = r.address(128, 'factory');
  const venue = r.small(160, 8, 'venue');
  const graduationProtectionSecs = r.uint(192, 64, 'graduationProtectionSecs');
  const sigAt = r.offset(224, 'sig');

  // CreateParams: a dynamic tuple; the three string offsets count from the start of the tuple
  const w = (i: number): number => pAt + 32 * i;
  const nameHex = r.dynamic(pAt + r.offset(w(0), 'p.name'), 'p.name');
  const symbolHex = r.dynamic(pAt + r.offset(w(1), 'p.symbol'), 'p.symbol');
  const metadataURIHex = r.dynamic(pAt + r.offset(w(2), 'p.metadataURI'), 'p.metadataURI');
  const name = text(nameHex);
  const symbol = text(symbolHex);
  const metadataURI = text(metadataURIHex);

  const p: CreateParams = {
    name: name.text,
    symbol: symbol.text,
    metadataURI: metadataURI.text,
    nameHex: '0x' + nameHex,
    symbolHex: '0x' + symbolHex,
    metadataURIHex: '0x' + metadataURIHex,
    textOk: name.ok && symbol.ok && metadataURI.ok,
    salt: r.bytes32(w(3), 'p.salt'),
    quote: r.address(w(4), 'p.quote'),
    graduation: r.word(w(5), 'p.graduation'),
    buyFeeBps: r.small(w(6), 16, 'p.buyFeeBps'),
    sellFeeBps: r.small(w(7), 16, 'p.sellFeeBps'),
    taxBuyBps: r.small(w(8), 16, 'p.taxBuyBps'),
    taxSellBps: r.small(w(9), 16, 'p.taxSellBps'),
    snipeStartBps: r.small(w(10), 16, 'p.snipeStartBps'),
    snipeMins: r.small(w(11), 16, 'p.snipeMins'),
    listingFee: r.word(w(12), 'p.listingFee'),
    firstBuy: r.word(w(13), 'p.firstBuy'),
    founderBps: r.small(w(14), 16, 'p.founderBps'),
    founderSecs: r.small(w(15), 32, 'p.founderSecs'),
    founderRoot: r.bytes32(w(16), 'p.founderRoot'),
  };

  return {
    p,
    templateId,
    vaultData: '0x' + r.dynamic(vaultDataAt, 'vaultData'),
    deadline,
    factory,
    venue,
    graduationProtectionSecs,
    sig: '0x' + r.dynamic(sigAt, 'sig'),
  };
}

// ───────────────────────────── encoding ─────────────────────────────

/** A dynamic value: length word, then the data right-padded with zeros to a whole number of words. */
const dyn = (hex: string): string => {
  const h = strip0x(hex).toLowerCase();
  return word(h.length / 2) + h.padEnd(Math.ceil(h.length / 64) * 64, '0');
};

/** ABI encoding of the `CreateParams` tuple (hex without 0x), as it appears in calldata and in the digest. */
export function encodeCreateParams(p: CreateParams): string {
  const tails = [dyn(p.nameHex), dyn(p.symbolHex), dyn(p.metadataURIHex)];
  let at = PARAM_WORDS * 32;
  const offsets = tails.map((t) => {
    const o = at;
    at += t.length / 2;
    return word(o);
  });
  return (
    offsets.join('') +
    strip0x(p.salt).toLowerCase().padStart(64, '0') +
    addressWord(p.quote) +
    word(p.graduation) +
    word(p.buyFeeBps) +
    word(p.sellFeeBps) +
    word(p.taxBuyBps) +
    word(p.taxSellBps) +
    word(p.snipeStartBps) +
    word(p.snipeMins) +
    word(p.listingFee) +
    word(p.firstBuy) +
    word(p.founderBps) +
    word(p.founderSecs) +
    strip0x(p.founderRoot).toLowerCase().padStart(64, '0') +
    tails.join('')
  );
}

/** The canonical `createToken` calldata for these arguments (0x hex, selector included). */
export function encodeCreateToken(c: CreateTokenCall): string {
  const p = encodeCreateParams(c.p);
  const vaultData = dyn(c.vaultData);
  const sig = dyn(c.sig);
  const pAt = HEAD_WORDS * 32;
  const vaultDataAt = pAt + p.length / 2;
  const sigAt = vaultDataAt + vaultData.length / 2;
  return (
    CREATE_TOKEN_SELECTOR +
    word(pAt) +
    word(c.templateId) +
    word(vaultDataAt) +
    word(c.deadline) +
    addressWord(c.factory) +
    word(c.venue) +
    word(c.graduationProtectionSecs) +
    word(sigAt) +
    p +
    vaultData +
    sig
  );
}

/**
 * Compares calldata with the canonical encoding of what it decodes to. The Solidity decoder ignores bytes
 * it is not pointed at, so calldata can carry data that a decoder never shows; this makes that visible.
 */
export function canonicalDifference(data: string, c: CreateTokenCall): string | null {
  const given = '0x' + strip0x(data.trim()).toLowerCase();
  const canon = encodeCreateToken(c);
  if (given === canon) return null;
  if (given.startsWith(canon)) {
    const extra = given.slice(canon.length);
    return `${extra.length / 2} extra byte(s) follow the encoded arguments: 0x${extra.length > 80 ? extra.slice(0, 80) + '...' : extra}`;
  }
  if (given.length !== canon.length) {
    return `the calldata is ${(given.length - 2) / 2} bytes; the canonical encoding of its arguments is ${(canon.length - 2) / 2} bytes`;
  }
  let i = 2;
  while (given[i] === canon[i]) i++;
  return `the calldata differs from the canonical encoding of its arguments at byte ${Math.floor((i - 2) / 2)}`;
}

/** `abi.decode(vaultData, (address))` for a Directed vault: exactly one word holding an address. */
export function decodeRecipient(vaultData: string): string {
  const h = strip0x(vaultData).toLowerCase();
  if (h.length !== 64) throw new DecodeError(`vaultData is ${h.length / 2} bytes; a Directed vault takes exactly 32 (one address)`);
  if (!/^0{24}/.test(h)) throw new DecodeError('vaultData has bits set above the 20 bytes of an address');
  return '0x' + h.slice(24);
}

// ───────────────────────────── the signed digest ─────────────────────────────

export interface DigestContext {
  chainId: bigint | number;
  manager: string;
  /** msg.sender of createToken: the launcher. */
  sender: string;
  /** IgnixManager.POOL_FEE() at the block the transaction runs in. */
  poolFee: bigint | number;
  /** IgnixManager.LAUNCH_FACTORY() at that block. */
  launchFactory: string;
}

/**
 * The digest IgnixManager.createToken recovers the platform signer from:
 *
 *   toEthSignedMessageHash(keccak256(abi.encode(block.chainid, address(this), msg.sender, p, templateId,
 *       vaultData, deadline, factory, venue, graduationProtectionSecs, POOL_FEE, LAUNCH_FACTORY)))
 */
export function launchDigest(c: CreateTokenCall, ctx: DigestContext): Uint8Array {
  const p = encodeCreateParams(c.p);
  const pAt = 12 * 32;
  const vaultDataAt = pAt + p.length / 2;
  const encoded =
    word(ctx.chainId) +
    addressWord(ctx.manager) +
    addressWord(ctx.sender) +
    word(pAt) +
    word(c.templateId) +
    word(vaultDataAt) +
    word(c.deadline) +
    addressWord(c.factory) +
    word(c.venue) +
    word(c.graduationProtectionSecs) +
    word(ctx.poolFee) +
    addressWord(ctx.launchFactory) +
    p +
    dyn(c.vaultData);
  const inner = keccak256(hexToBytes(encoded));
  const prefix = utf8.encode('\x19Ethereum Signed Message:\n32');
  const message = new Uint8Array(prefix.length + 32);
  message.set(prefix, 0);
  message.set(inner, prefix.length);
  return keccak256(message);
}
