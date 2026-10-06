// The ordered list of transactions that publishes a site into one circuit's container.
// Same rules as `plan` in sim/src/SitePublisher.sol (which the human's forge script executes):
//   1. open the container, if it is not opened
//   2. every file that is not already on chain byte for byte: putFile, then appendChunk per further
//      24,000 bytes. Files that are not HTML first, HTML last, each group sorted by path
//   3. setFallback, if a fallback path is asked for and differs
//   4. removeFile for each on-chain path that is not in the directory, if pruning is asked for
//   5. bind (name activation), if months > 0 and the container is not activated (or renew is set)

import { decFileInfo, encAppendChunk, encBind, encFileInfo, encOpen, encPutFile, encRemoveFile, encSetFallback, type FileInfo } from './abi.ts';
import { XLAYER, fallbackPathOf, listPaths, readFile, type Reader, type Target } from './chain.ts';
import { estimateGas, type GasContext, type GasInput } from './gas.ts';
import { chunkCountOf, chunksOf, type SiteFile } from './site.ts';

export type StepKind = 'open' | 'putFile' | 'appendChunk' | 'setFallback' | 'removeFile' | 'bind';

/** The numbers sim/src/SitePublisher.sol uses for the same kinds (K_OPEN ... K_BIND). */
export const KIND_NUMBER: Readonly<Record<StepKind, number>> = { open: 1, putFile: 2, appendChunk: 3, setFallback: 4, removeFile: 5, bind: 6 };

export interface Step {
  kind: StepKind;
  /** Contract the transaction is sent to. */
  target: string;
  /** Function signature. */
  fn: string;
  /** Short description of the arguments. */
  args: string;
  /** OKB sent with the call, in wei. */
  value: bigint;
  /** Calldata, 0x-prefixed. */
  data: string;
  /** The same text the forge script prints for this step. */
  label: string;
  /** Estimated gas used (see gas.ts for what the estimate is and how far off it can be). */
  gas: number;
  /** True when the estimate is a rough one (replacing or removing an existing file, renewing a name). */
  gasIsRough: boolean;
}

export interface Options {
  /** Months of name activation to pay for when the container is not activated. 0 = never bind. */
  months: number;
  /** Pay for `months` more even though the container is already activated. */
  renew: boolean;
  /** When not empty: make this path the fallback. Empty = leave it as it is. */
  fallbackPath: string;
  /** Remove on-chain paths that are not in the directory. */
  prune: boolean;
}

export const DEFAULT_OPTIONS: Options = { months: 1, renew: false, fallbackPath: '', prune: false };

/** What the container holds now, as far as the plan needs it. */
export interface OnChainSite {
  /** Every path the registry lists, in the registry's order. */
  paths: string[];
  fallback: string;
  /** `fileInfo` of every listed path. */
  info: Map<string, FileInfo>;
  /** Local paths whose on-chain copy is identical (metadata and bytes). */
  identical: Set<string>;
}

export const EMPTY_SITE: OnChainSite = { paths: [], fallback: '', info: new Map(), identical: new Set() };

const sameBytes = (a: Uint8Array, b: Uint8Array): boolean => a.length === b.length && a.every((v, i) => v === b[i]);

/** Reads what the plan depends on. For a container that is not opened there is nothing to read. */
export async function readOnChainSite(reader: Reader, target: Target, files: readonly SiteFile[]): Promise<OnChainSite> {
  if (!target.opened) return EMPTY_SITE;
  const site: OnChainSite = { paths: await listPaths(reader, target.container), fallback: await fallbackPathOf(reader, target.container), info: new Map(), identical: new Set() };
  const infos = await reader.multi(site.paths.map((p) => ({ to: XLAYER.registry, data: encFileInfo(target.container, p) })));
  site.paths.forEach((p, i) => {
    const r = infos[i];
    if (r instanceof Error) throw new Error(`fileInfo of ${p}: ${r.message}`);
    site.info.set(p, decFileInfo(r));
  });
  for (const f of files) {
    const info = site.info.get(f.path);
    if (!info || info.chunkCount === 0) continue;
    const sameMeta = info.size === f.data.length && info.chunkCount === chunkCountOf(f.data.length) && info.sha256 === f.sha256 && info.contentType === f.contentType;
    if (sameMeta && sameBytes(await readFile(reader, target.container, f.path, info.size), f.data)) site.identical.add(f.path);
  }
  return site;
}

export function buildPlan(target: Target, files: readonly SiteFile[], options: Options = DEFAULT_OPTIONS, onChain: OnChainSite = EMPTY_SITE): Step[] {
  if (!Number.isInteger(options.months) || options.months < 0 || options.months > 120) throw new Error('months must be an integer from 0 to 120');
  const steps: Step[] = [];
  // what the gas estimate needs to know about the state each step runs in
  const ctx: GasContext = { paths: [...onChain.paths], existing: onChain.info };
  const add = (s: Omit<Step, 'gas' | 'gasIsRough'>, about: Omit<GasInput, 'kind' | 'data'> = {}): void => {
    const g = estimateGas({ kind: s.kind, data: s.data, ...about }, ctx);
    steps.push({ ...s, gas: g.gas, gasIsRough: g.rough });
  };

  if (!target.opened) {
    add({
      kind: 'open',
      target: XLAYER.opener,
      fn: 'open(address,uint256)',
      args: `processor ${target.processor}, circuit ${target.circuitId}`,
      value: target.openFee,
      data: encOpen(target.processor, target.circuitId),
      label: `open the container of circuit ${target.circuitId}`,
    });
  }

  for (const f of files) {
    if (onChain.identical.has(f.path)) continue;
    const chunks = chunksOf(f.data);
    chunks.forEach((chunk, c) => {
      const what = `${f.path} chunk ${c + 1}/${chunks.length} (${chunk.length} bytes)`;
      if (c === 0) {
        add({
          kind: 'putFile',
          target: XLAYER.registry,
          fn: 'putFile(address,string,string,bytes32,bytes)',
          args: `${f.path}, ${f.contentType}, sha256 ${f.sha256.slice(0, 10)}…, first ${chunk.length} of ${f.data.length} bytes`,
          value: 0n,
          data: encPutFile(target.container, f.path, f.contentType, f.sha256, chunk),
          label: `putFile ${what}`,
        }, { path: f.path, contentType: f.contentType, chunkBytes: chunk.length });
      } else {
        add({
          kind: 'appendChunk',
          target: XLAYER.registry,
          fn: 'appendChunk(address,string,uint256,bytes)',
          args: `${f.path}, index ${c}, ${chunk.length} bytes`,
          value: 0n,
          data: encAppendChunk(target.container, f.path, c, chunk),
          label: `appendChunk ${what}`,
        }, { path: f.path, contentType: f.contentType, chunkBytes: chunk.length });
      }
    });
  }

  if (options.fallbackPath !== '') {
    if (!files.some((f) => f.path === options.fallbackPath)) throw new Error(`the fallback path is not a file of the site: ${options.fallbackPath}`);
    if (!target.opened || onChain.fallback !== options.fallbackPath) {
      add({
        kind: 'setFallback',
        target: XLAYER.registry,
        fn: 'setFallback(address,string)',
        args: options.fallbackPath,
        value: 0n,
        data: encSetFallback(target.container, options.fallbackPath),
        label: `setFallback ${options.fallbackPath}`,
      }, { path: options.fallbackPath });
    }
  }

  if (options.prune) {
    for (const path of staleFiles(files, onChain)) {
      add({
        kind: 'removeFile',
        target: XLAYER.registry,
        fn: 'removeFile(address,string)',
        args: path,
        value: 0n,
        data: encRemoveFile(target.container, path),
        label: `removeFile ${path}`,
      }, { path });
    }
  }

  if (options.months !== 0 && (!target.live || options.renew)) {
    add({
      kind: 'bind',
      target: XLAYER.binding,
      fn: 'bind(string,address,uint256)',
      args: `${target.name}, container, ${options.months} x 30 days`,
      value: BigInt(options.months) * target.monthlyFee,
      data: encBind(target.name, target.container, options.months),
      label: `bind ${target.name} for ${options.months} x 30 days`,
    }, { renewal: target.paidUntil !== 0 });
  }
  return steps;
}

/** On-chain paths that are not in the directory, in the registry's order. */
export function staleFiles(files: readonly SiteFile[], onChain: OnChainSite): string[] {
  const local = new Set(files.map((f) => f.path));
  return onChain.paths.filter((p) => !local.has(p));
}

export interface Totals {
  transactions: number;
  gas: number;
  /** OKB paid to the protocol (opening fee, name fee), in wei. */
  value: bigint;
  /** gas x gas price, in wei. */
  gasCost: bigint;
  /** value + gasCost, in wei. */
  total: bigint;
}

export function totalsOf(steps: readonly Step[], gasPriceWei: bigint): Totals {
  const gas = steps.reduce((n, s) => n + s.gas, 0);
  const value = steps.reduce((n, s) => n + s.value, 0n);
  const gasCost = BigInt(gas) * gasPriceWei;
  return { transactions: steps.length, gas, value, gasCost, total: value + gasCost };
}

/** Wei as OKB with every digit that matters and no rounding. */
export function okb(wei: bigint): string {
  const s = wei.toString().padStart(19, '0');
  const frac = s.slice(-18).replace(/0+$/, '');
  return s.slice(0, -18) + (frac ? '.' + frac : '');
}
