// Calldata builders and return-data decoders for the DeWEB contracts on X Layer: container opener,
// SiteRegistry and DomainBinding. Hand-written on top of the repository's own codec helpers.
// Every signature and selector is listed in SIGNATURES; test/abi.test.ts recomputes each selector with
// the repository's keccak256, and NOTES.md records the `cast sig` output they were first checked against.

import { addressWord, bytesTail, decUint, strip, toBytes, toHex, word } from '../../../packages/chain/src/index.ts';

export const SIGNATURES = {
  // container opener (CircuitAccountOpener)
  open: ['open(address,uint256)', '0a0e5c9d'],
  accountOf: ['accountOf(address,uint256)', '0c1905e5'],
  isOpened: ['isOpened(address,uint256)', '8b508494'],
  FEE: ['FEE()', 'c57981b5'],
  // SiteRegistry
  putFile: ['putFile(address,string,string,bytes32,bytes)', 'fab2ed82'],
  appendChunk: ['appendChunk(address,string,uint256,bytes)', 'e2b51347'],
  removeFile: ['removeFile(address,string)', '0a9c1871'],
  setFallback: ['setFallback(address,string)', '4dc21ad0'],
  setOperator: ['setOperator(address,address,uint256)', 'c88cb026'],
  fileInfo: ['fileInfo(address,string)', '6c609107'],
  read: ['read(address,string)', 'ccaa7afb'],
  readRange: ['readRange(address,string,uint256,uint256)', '15a4cae2'],
  pathCount: ['pathCount(address)', 'b554782b'],
  pathsRange: ['pathsRange(address,uint256,uint256)', 'b056072c'],
  fallbackPath: ['fallbackPath(address)', 'a76c7713'],
  canEdit: ['canEdit(address,address)', 'bcfe519c'],
  isOwner: ['isOwner(address,address)', '7ddc02d4'],
  // DomainBinding
  bind: ['bind(string,address,uint256)', '69e292ce'],
  monthlyFee: ['monthlyFee()', '8cfd3e40'],
  isLive: ['isLive(string,address)', 'd6b062cd'],
  isContainerLive: ['isContainerLive(address)', 'dcca979e'],
  containerPaidUntil: ['containerPaidUntil(address)', '9ebfd859'],
  // processor factory and processor
  cpuCount: ['cpuCount()', 'a94da8a7'],
  cpuAt: ['cpuAt(uint256)', '4bc7cbbd'],
  isCPU: ['isCPU(address)', '5f5a364f'],
  ownerOf: ['ownerOf(uint256)', '6352211e'],
  name: ['name()', '06fdde03'],
} as const satisfies Record<string, readonly [signature: string, selector: string]>;

const sel = (name: keyof typeof SIGNATURES): string => '0x' + SIGNATURES[name][1];

/** A dynamic `string` value as an ABI tail: length word, then the UTF-8 bytes padded to 32. */
const stringTail = (s: string): string => bytesTail(toHex(new TextEncoder().encode(s)));
const tailBytes = (tail: string): number => tail.length / 2;

// ------------------------------------------------------------------ calldata

export const encOpen = (processor: string, circuitId: bigint): string => sel('open') + addressWord(processor) + word(circuitId);

/** putFile(address container, string path, string contentType, bytes32 sha256Hash, bytes data) */
export function encPutFile(container: string, path: string, contentType: string, sha256: string, data: Uint8Array): string {
  const p = stringTail(path);
  const c = stringTail(contentType);
  const head = 5 * 32;
  return (
    sel('putFile') +
    addressWord(container) +
    word(head) +
    word(head + tailBytes(p)) +
    strip(sha256).padStart(64, '0') +
    word(head + tailBytes(p) + tailBytes(c)) +
    p +
    c +
    bytesTail(toHex(data))
  );
}

/** appendChunk(address container, string path, uint256 expectIndex, bytes data) */
export function encAppendChunk(container: string, path: string, expectIndex: number, data: Uint8Array): string {
  const p = stringTail(path);
  const head = 4 * 32;
  return sel('appendChunk') + addressWord(container) + word(head) + word(expectIndex) + word(head + tailBytes(p)) + p + bytesTail(toHex(data));
}

const encContainerString = (name: 'removeFile' | 'setFallback' | 'fileInfo' | 'read', container: string, s: string): string =>
  sel(name) + addressWord(container) + word(64) + stringTail(s);

export const encRemoveFile = (container: string, path: string): string => encContainerString('removeFile', container, path);
export const encSetFallback = (container: string, path: string): string => encContainerString('setFallback', container, path);
export const encFileInfo = (container: string, path: string): string => encContainerString('fileInfo', container, path);
export const encRead = (container: string, path: string): string => encContainerString('read', container, path);

/** readRange(address container, string path, uint256 offset, uint256 len) */
export const encReadRange = (container: string, path: string, offset: number, len: number): string =>
  sel('readRange') + addressWord(container) + word(128) + word(offset) + word(len) + stringTail(path);

/** bind(string name, address container, uint256 months) */
export const encBind = (name: string, container: string, months: number): string =>
  sel('bind') + word(96) + addressWord(container) + word(months) + stringTail(name);

/** isLive(string name, address container) */
export const encIsLive = (name: string, container: string): string => sel('isLive') + word(64) + addressWord(container) + stringTail(name);

export const encAccountOf = (processor: string, circuitId: bigint): string => sel('accountOf') + addressWord(processor) + word(circuitId);
export const encIsOpened = (processor: string, circuitId: bigint): string => sel('isOpened') + addressWord(processor) + word(circuitId);
export const encPathsRange = (container: string, from: number, n: number): string => sel('pathsRange') + addressWord(container) + word(from) + word(n);
export const encCanEdit = (container: string, who: string): string => sel('canEdit') + addressWord(container) + addressWord(who);
/** A call that takes one address: pathCount, fallbackPath, isContainerLive, containerPaidUntil, isCPU. */
export const encAddressArg = (name: 'pathCount' | 'fallbackPath' | 'isContainerLive' | 'containerPaidUntil' | 'isCPU', a: string): string =>
  sel(name) + addressWord(a);
/** A call that takes one uint256: cpuAt, ownerOf. */
export const encUintArg = (name: 'cpuAt' | 'ownerOf', v: bigint | number): string => sel(name) + word(v);
/** A call without arguments: FEE, monthlyFee, cpuCount, name. */
export const encNoArg = (name: 'FEE' | 'monthlyFee' | 'cpuCount' | 'name'): string => sel(name);

// ------------------------------------------------------------------ return data

/** Reads past the end are refused, so short or empty return data throws instead of decoding to garbage. */
const cut = (r: string, offset: number, n: number): string => {
  const s = r.slice(offset * 2, (offset + n) * 2);
  if (s.length < n * 2) throw new Error('ABI: return data too short');
  return s;
};
const num = (r: string, offset: number): number => {
  const v = BigInt('0x' + cut(r, offset, 32));
  if (v > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('ABI: value too large for an offset or length');
  return Number(v);
};
const dynBytes = (r: string, offset: number): Uint8Array => toBytes(cut(r, offset + 32, num(r, offset)));
const text = (b: Uint8Array): string => new TextDecoder().decode(b);

export interface FileInfo {
  size: number;
  contentType: string;
  /** 0x-prefixed lower-case; all zeros when the owner declared no hash. */
  sha256: string;
  updatedAt: number;
  /** 0 means the file does not exist. */
  chunkCount: number;
}

/** fileInfo returns (uint32 size, string contentType, bytes32 sha256Hash, uint40 updatedAt, uint256 chunkCount) */
export function decFileInfo(ret: string): FileInfo {
  const r = strip(ret);
  return {
    size: num(r, 0),
    contentType: text(dynBytes(r, num(r, 32))),
    sha256: '0x' + cut(r, 64, 32).toLowerCase(),
    updatedAt: num(r, 96),
    chunkCount: num(r, 128),
  };
}

/** A single dynamic `bytes` return value, as bytes. */
export function decBytesValue(ret: string): Uint8Array {
  const r = strip(ret);
  return dynBytes(r, num(r, 0));
}

/** A single `string` return value. */
export const decStringValue = (ret: string): string => text(decBytesValue(ret));

/** A single `string[]` return value. */
export function decStringArray(ret: string): string[] {
  const r = strip(ret);
  const base = num(r, 0) + 32; // first byte after the array length; element offsets count from here
  const n = num(r, base - 32);
  const out: string[] = [];
  for (let i = 0; i < n; i++) out.push(text(dynBytes(r, base + num(r, base + 32 * i))));
  return out;
}

export const decNumber = (ret: string): number => {
  const v = decUint(ret);
  if (v > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('ABI: value too large for a number');
  return Number(v);
};

// ------------------------------------------------------------------ revert data

/** Custom errors of the opener, the SiteRegistry and the DomainBinding, by selector. */
export const ERRORS: Readonly<Record<string, string>> = {
  '30cd7471': 'NotOwner(): the sender may not act for this container',
  '6d36408a': 'NotOpened(): the container is not opened',
  '218e0a07': 'TooLarge(): more than 24,000 bytes in a chunk, more than 350 chunks, or an operator period above 30 days',
  '2a9df442': 'NoSuchFile(): no file at this path',
  ef3ff4ae: 'BadIndex(): the chunk index is not the next one',
  b4f54111: 'DeployFailed(): the chunk contract could not be created',
  '5c69a867': 'NotRegisteredCPU(): the processor is not registered with the factory',
  '538b8132': 'NoNesting(): the circuit is held by another container',
  '1da42b26': 'AlreadyOpened(): the container is already opened',
  a9bcda2c: 'SelfOwnership(): the circuit is held by its own container',
  f04f3db2: 'FeeTooLow(sent, need): less than the opening fee was sent',
  '4033e4e3': 'FeeTransferFailed()',
  bdbbb533: 'BadPayment(): months not in 1..120, or the value is not months x monthlyFee',
  '9d135ed2': 'BadDomain(): the name must be lower case and contain a dot',
  '13a09949': 'NotContainer(): not an opened TapeOut container',
  '1cf9b207': 'TooFarAhead(): more than ten years paid ahead',
};

/** A readable reason for revert data of these contracts; falls back to the raw hex. */
export function explainRevert(data: string | undefined): string {
  const r = strip(data ?? '');
  const known = ERRORS[r.slice(0, 8).toLowerCase()];
  if (known) return known;
  if (r.startsWith('08c379a0')) {
    try {
      return decStringValue(r.slice(8));
    } catch {
      // fall through
    }
  }
  return r ? `reverted with 0x${r}` : 'reverted without data';
}
