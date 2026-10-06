// X Layer addresses of the DeWEB contracts, the container address derivation, and the chain reads the
// plan and the verification share. Everything here is read-only: eth_call, eth_getStorageAt, eth_blockNumber.

import {
  MULTICALL3,
  RpcError,
  addressWord,
  createRpc,
  decAddress,
  decAggregate3,
  decBool,
  decUint,
  encAggregate3,
  strip,
  toBytes,
  word,
  type Rpc,
} from '../../../packages/chain/src/index.ts';
import { checksumAddress, keccak256Hex } from '../../../packages/chain/src/keccak.ts';
import {
  decBytesValue,
  decFileInfo,
  decNumber,
  decStringArray,
  decStringValue,
  encAccountOf,
  encAddressArg,
  encCanEdit,
  encFileInfo,
  encIsLive,
  encIsOpened,
  encNoArg,
  encPathsRange,
  encRead,
  encReadRange,
  encUintArg,
  explainRevert,
  type FileInfo,
} from './abi.ts';
import { RANGE_BYTES } from './site.ts';

/** X Layer mainnet. Source: TAP-10 "Deployments"; every value was read back from the chain (NOTES.md). */
export const XLAYER = {
  chainId: 196,
  /** The chain's number in on-chain names and gateway hosts (TAP-10 section 2.1). */
  areaCode: 2,
  factory: '0x1f09DAeFA827f02CBb40967cc91b259763760761',
  opener: '0x536adD8F30f03b69f6fbF29d425A816A0dC50106',
  registry: '0xd6EFb7adCc9c83dC4924Ad56f6a8E4e969b9ADB6',
  binding: '0x68809Fd2fb343aA57D0aeB7f33Defe477c9666f9',
  /** The only implementations the official gateway accepts behind the two proxies. */
  registryImplementation: '0xa85c4143d1D4A77f54b8e4ecC9E6D1418Afea45f',
  bindingImplementation: '0x5eBF29b80789e548907C707530C3C7607C4347Df',
  /** ERC-6551 registry and the account implementation the opener passes to it. */
  erc6551Registry: '0x000000006551c19487814612e58FE06813775758',
  containerImplementation: '0xAC4F791353eE9F06e2C50Ae4C34680D28Ea52a57',
  /** Fees read on 2026-10-04; the tools read the live values and only fall back to these with --assume-fresh. */
  openFee: 80_000_000_000_000_000n,
  monthlyFee: 26_000_000_000_000_000n,
  /** OKX's two public nodes: the ones a site may call without being listed as off-chain by the gateway. */
  rpc: ['https://rpc.xlayer.tech', 'https://xlayerrpc.okx.com'],
  /** A node of the second operator in the gateway's default list (TapeKit kernel/src/config.js). */
  secondOperatorRpc: 'https://xlayer.drpc.org',
  gateway: 'tapekit.org',
} as const;

export const IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';

const same = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();

/** `<id>.2.<processor number>.tape`: the on-chain name, also the string `bind` is paid for. */
export const onChainName = (circuitId: bigint, processorNumber: number): string => `${circuitId}.${XLAYER.areaCode}.${processorNumber}.tape`;
/** `<id>-2-<processor number>`: the first label of the gateway host. */
export const hostLabel = (circuitId: bigint, processorNumber: number): string => `${circuitId}-${XLAYER.areaCode}-${processorNumber}`;

/**
 * The container of a circuit: the ERC-6551 account address, a CREATE2 address of the ERC-6551 registry with
 * salt 0. Equal to `opener.accountOf(processor, circuitId)`; needs no chain access.
 */
export function containerAddress(processor: string, circuitId: bigint, chainId: number = XLAYER.chainId): string {
  const creationCode =
    '3d60ad80600a3d3981f3363d3d373d3d3d363d73' +
    strip(XLAYER.containerImplementation).toLowerCase() +
    '5af43d82803e903d91602b57fd5bf3' +
    word(0) + // salt
    word(chainId) +
    addressWord(processor) +
    word(circuitId);
  const codeHash = strip(keccak256Hex(toBytes(creationCode)));
  const preimage = 'ff' + strip(XLAYER.erc6551Registry).toLowerCase() + word(0) + codeHash;
  return checksumAddress('0x' + keccak256Hex(toBytes(preimage)).slice(-40));
}

/**
 * The repository's JSON-RPC client, with every request labelled `application/json`. The client's default is
 * to send no content type (that spares a browser a CORS preflight); these tools run in Node, and a strict
 * node such as anvil answers an unlabelled request with "Invalid request".
 */
export function nodeRpc(urls: readonly string[], timeout: number = 20_000): Rpc {
  const jsonFetch: typeof fetch = (input, init) => fetch(input, { ...init, headers: { ...(init?.headers as Record<string, string> | undefined), 'content-type': 'application/json' } });
  return createRpc(urls, { fetch: jsonFetch, timeout });
}

/** A chain reader pinned to one block, so a set of reads cannot mix old and new state. */
export interface Reader {
  rpc: Rpc;
  /** Block number all reads are made at. */
  block: number;
  /** One eth_call at the pinned block. A revert is thrown as an Error with a readable reason. */
  call(to: string, data: string): Promise<string>;
  /** Many calls through Multicall3 at the pinned block; a reverted call is returned as an Error. */
  multi(calls: readonly { to: string; data: string }[]): Promise<(string | Error)[]>;
  storageAt(address: string, slot: string): Promise<string>;
}

/**
 * Pins to the node's head minus 2 (as the gateway does) unless `block` is given.
 * `urls` are tried in turn; they should belong to one operator's nodes or be equivalent.
 */
export async function createReader(urls: readonly string[] = XLAYER.rpc, block?: number, timeout: number = 20_000): Promise<Reader> {
  const rpc = nodeRpc(urls, timeout);
  const chainId = Number(BigInt((await rpc.send('eth_chainId')) as string));
  if (chainId !== XLAYER.chainId) throw new Error(`${rpc.current()} is chain ${chainId}, not X Layer (196)`);
  const pinned = block ?? Number(BigInt((await rpc.send('eth_blockNumber')) as string)) - 2;
  const tag = '0x' + pinned.toString(16);
  const call = async (to: string, data: string): Promise<string> => {
    try {
      return await rpc.call(to, data, tag);
    } catch (e) {
      if (e instanceof RpcError && e.data !== undefined) throw new Error(explainRevert(e.data));
      throw e;
    }
  };
  const multi = async (calls: readonly { to: string; data: string }[]): Promise<(string | Error)[]> => {
    const out: (string | Error)[] = [];
    for (let o = 0; o < calls.length; o += 100) {
      const sub = decAggregate3(await call(MULTICALL3, encAggregate3(calls.slice(o, o + 100))));
      for (const r of sub) out.push(r.success ? r.data : new Error(explainRevert(r.data)));
    }
    return out;
  };
  const storageAt = async (address: string, slot: string): Promise<string> => (await rpc.send('eth_getStorageAt', [address, slot, tag])) as string;
  return { rpc, block: pinned, call, multi, storageAt };
}

/** Everything the plan and the verification need to know about one circuit's container. */
export interface Target {
  processor: string;
  circuitId: bigint;
  /** Index of the processor in `factory.cpuAt`. */
  processorNumber: number;
  processorName: string;
  holder: string;
  container: string;
  /** `<id>.2.<n>.tape` */
  name: string;
  /** `<id>-2-<n>` */
  host: string;
  opened: boolean;
  /** The official gateway shows the site: `isLive(name, container)` or `isContainerLive(container)`. */
  live: boolean;
  /** Unix time until which the container is paid (0 = never paid). */
  paidUntil: number;
  openFee: bigint;
  monthlyFee: bigint;
  /** Both proxies point at the implementations the official gateway accepts. */
  implementationsAccepted: boolean;
  /** Block the values were read at; undefined for an assumed (offline) target. */
  block?: number;
}

const ok = (v: string | Error, what: string): string => {
  if (v instanceof Error) throw new Error(`${what}: ${v.message}`);
  return v;
};

/** The processor's index in the factory. Checks `claimed` when given, otherwise scans every index. */
export async function processorNumberOf(reader: Reader, processor: string, claimed?: number): Promise<number> {
  const count = decNumber(await reader.call(XLAYER.factory, encNoArg('cpuCount')));
  if (claimed !== undefined) {
    if (claimed >= count || !same(decAddress(await reader.call(XLAYER.factory, encUintArg('cpuAt', claimed))), processor)) {
      throw new Error(`processor number ${claimed} is not ${processor} in the factory`);
    }
    return claimed;
  }
  const all = await reader.multi(Array.from({ length: count }, (_, i) => ({ to: XLAYER.factory, data: encUintArg('cpuAt', i) })));
  const i = all.findIndex((r) => !(r instanceof Error) && same(decAddress(r), processor));
  if (i < 0) throw new Error(`${processor} is not a processor of the TapeOut factory (${count} processors read)`);
  return i;
}

/** Reads the target at the reader's pinned block. Throws, in plain words, when the circuit does not exist. */
export async function inspect(reader: Reader, processor: string, circuitId: bigint, processorNumber?: number): Promise<Target> {
  if (circuitId < 1n) throw new Error('circuit ids start at 1');
  const container = containerAddress(processor, circuitId);
  const [isCpu, holder, account, opened, openFee, monthlyFee, procName, paidUntil, containerLive] = await reader.multi([
    { to: XLAYER.factory, data: encAddressArg('isCPU', processor) },
    { to: processor, data: encUintArg('ownerOf', circuitId) },
    { to: XLAYER.opener, data: encAccountOf(processor, circuitId) },
    { to: XLAYER.opener, data: encIsOpened(processor, circuitId) },
    { to: XLAYER.opener, data: encNoArg('FEE') },
    { to: XLAYER.binding, data: encNoArg('monthlyFee') },
    { to: processor, data: encNoArg('name') },
    { to: XLAYER.binding, data: encAddressArg('containerPaidUntil', container) },
    { to: XLAYER.binding, data: encAddressArg('isContainerLive', container) },
  ]);
  if (isCpu instanceof Error || !decBool(isCpu)) throw new Error(`${processor} is not a processor of the TapeOut factory`);
  if (holder instanceof Error) throw new Error(`processor ${processor} has no circuit ${circuitId}`);
  if (!same(decAddress(ok(account, 'accountOf')), container)) {
    throw new Error(`opener.accountOf answers ${decAddress(ok(account, 'accountOf'))}, the ERC-6551 derivation gives ${container}`);
  }
  const number = await processorNumberOf(reader, processor, processorNumber);
  const name = onChainName(circuitId, number);
  const nameLive = decBool(await reader.call(XLAYER.binding, encIsLive(name, container)));
  const [registryImpl, bindingImpl] = await Promise.all([
    reader.storageAt(XLAYER.registry, IMPLEMENTATION_SLOT),
    reader.storageAt(XLAYER.binding, IMPLEMENTATION_SLOT),
  ]);
  return {
    processor: checksumAddress(processor),
    circuitId,
    processorNumber: number,
    processorName: procName instanceof Error ? '' : decStringValue(procName),
    holder: checksumAddress(decAddress(holder)),
    container,
    name,
    host: hostLabel(circuitId, number),
    opened: decBool(ok(opened, 'isOpened')),
    live: nameLive || decBool(ok(containerLive, 'isContainerLive')),
    paidUntil: decNumber(ok(paidUntil, 'containerPaidUntil')),
    openFee: decUint(ok(openFee, 'FEE')),
    monthlyFee: decUint(ok(monthlyFee, 'monthlyFee')),
    implementationsAccepted:
      same('0x' + strip(registryImpl).slice(-40), XLAYER.registryImplementation) &&
      same('0x' + strip(bindingImpl).slice(-40), XLAYER.bindingImplementation),
    block: reader.block,
  };
}

/** A target that needs no chain access: a container that was never opened, with the fees as last read. */
export function assumeFresh(processor: string, circuitId: bigint, processorNumber: number, holder: string): Target {
  return {
    processor: checksumAddress(processor),
    circuitId,
    processorNumber,
    processorName: '',
    holder: checksumAddress(holder),
    container: containerAddress(processor, circuitId),
    name: onChainName(circuitId, processorNumber),
    host: hostLabel(circuitId, processorNumber),
    opened: false,
    live: false,
    paidUntil: 0,
    openFee: XLAYER.openFee,
    monthlyFee: XLAYER.monthlyFee,
    implementationsAccepted: true,
  };
}

/** True when `who` may write to the container now (the holder, or an operator the holder set). */
export const canEdit = async (reader: Reader, container: string, who: string): Promise<boolean> =>
  decBool(await reader.call(XLAYER.registry, encCanEdit(container, who)));

/** Every path the registry lists for the container, in pages of 200 (as the gateway reads them). */
export async function listPaths(reader: Reader, container: string): Promise<string[]> {
  const count = decNumber(await reader.call(XLAYER.registry, encAddressArg('pathCount', container)));
  const out: string[] = [];
  for (let from = 0; from < count; from += 200) {
    out.push(...decStringArray(await reader.call(XLAYER.registry, encPathsRange(container, from, 200))));
  }
  return out;
}

export const fallbackPathOf = async (reader: Reader, container: string): Promise<string> =>
  decStringValue(await reader.call(XLAYER.registry, encAddressArg('fallbackPath', container)));

export const fileInfoOf = async (reader: Reader, container: string, path: string): Promise<FileInfo> =>
  decFileInfo(await reader.call(XLAYER.registry, encFileInfo(container, path)));

/**
 * The file's bytes as the gateway reads them: one `read` up to 96 KiB, `readRange` segments of 98,304
 * bytes above that. `size` is the size `fileInfo` declared.
 */
export async function readFile(reader: Reader, container: string, path: string, size: number): Promise<Uint8Array> {
  if (size <= RANGE_BYTES) return decBytesValue(await reader.call(XLAYER.registry, encRead(container, path)));
  const parts: Uint8Array[] = [];
  for (let offset = 0; offset < size; offset += RANGE_BYTES) {
    parts.push(decBytesValue(await reader.call(XLAYER.registry, encReadRange(container, path, offset, RANGE_BYTES))));
  }
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}
