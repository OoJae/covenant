// The on-chain TeamRegistry (contracts/issuance/src/TeamRegistry.sol): an append-only list of the team's
// wallets, entry 0 being the deployer. The audit reads it with `count()` and `at(i)` and audits every listed
// wallet in addition to the table of docs/WALLETS.md.

import { strip0x } from '../launch-check/hex.ts';
import type { Chain } from './chain.ts';
import { selectorOf, type Known, type Wallet } from './known.ts';

export interface RegistryEntry {
  index: number;
  wallet: string;
  role: string;
  /** Unix seconds of the declaration. */
  timestamp: number;
}

/** What the audit learned from the registry, for the report. */
export interface RegistryView {
  address: string;
  entries: RegistryEntry[];
  /** Listed on-chain, missing from docs/WALLETS.md. */
  onlyInRegistry: string[];
  /** Declared in docs/WALLETS.md (or added as the deployer), missing from the registry. */
  onlyInDoc: string[];
  /** Entry 0 is the configured deployer (null when no deployer is configured). */
  entry0IsDeployer: boolean | null;
}

/** The registry never lists more than this many wallets; a larger count means the address is something else. */
export const MAX_ENTRIES = 1000;

const SEL_COUNT = selectorOf('count()');
const SEL_AT = selectorOf('at(uint256)');

export class RegistryError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'RegistryError';
  }
}

/** `count()`: one word. */
export function decodeCount(ret: string): number {
  const h = strip0x(ret);
  if (h.length !== 64) throw new RegistryError(`TeamRegistry.count() returned ${h.length / 2} bytes; 32 expected (is covenant.teamRegistry a TeamRegistry?)`);
  const n = BigInt('0x' + h);
  if (n > BigInt(MAX_ENTRIES)) throw new RegistryError(`TeamRegistry.count() is ${n}: not a team registry`);
  return Number(n);
}

/** `at(i)` returns (address wallet, string role, uint256 timestamp): decoded strictly. */
export function decodeAt(ret: string, index: number): RegistryEntry {
  const h = strip0x(ret);
  const word = (i: number): bigint => {
    if (h.length < (i + 1) * 64) throw new RegistryError(`TeamRegistry.at(${index}) returned too few bytes`);
    return BigInt('0x' + h.slice(i * 64, i * 64 + 64));
  };
  const w = word(0);
  if (w >> 160n) throw new RegistryError(`TeamRegistry.at(${index}): the first word is not an address`);
  const offset = word(1);
  if (offset !== 96n) throw new RegistryError(`TeamRegistry.at(${index}): the role is not where (address, string, uint256) puts it`);
  const timestamp = word(2);
  const len = word(3);
  if (len > 64n) throw new RegistryError(`TeamRegistry.at(${index}): a role of ${len} bytes (the registry accepts at most 64)`);
  if (h.length !== (4 + Math.ceil(Number(len) / 32)) * 64) throw new RegistryError(`TeamRegistry.at(${index}) returned ${h.length / 2} bytes, not the encoding of (address, string, uint256)`);
  const bytesHex = h.slice(4 * 64, 4 * 64 + Number(len) * 2);
  const bytes = new Uint8Array(Number(len));
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(bytesHex.slice(2 * i, 2 * i + 2), 16);
  return { index, wallet: '0x' + w.toString(16).padStart(40, '0'), role: new TextDecoder().decode(bytes), timestamp: Number(timestamp) };
}

/** Reads every entry of the registry at the audit block. */
export async function readRegistry(chain: Chain, registry: string): Promise<RegistryEntry[]> {
  const [c] = await chain.calls([{ to: registry, data: SEL_COUNT }]);
  if (typeof c !== 'string') throw new RegistryError(`TeamRegistry.count() at ${registry} reverted: is covenant.teamRegistry a TeamRegistry?`);
  const n = decodeCount(c);
  const replies = await chain.calls(Array.from({ length: n }, (_, i) => ({ to: registry, data: SEL_AT + i.toString(16).padStart(64, '0') })));
  return replies.map((r, i) => {
    if (typeof r !== 'string') throw new RegistryError(`TeamRegistry.at(${i}) reverted`);
    return decodeAt(r, i);
  });
}

/**
 * The wallets to audit: the declared table, every registry entry, and the deployer. A wallet named in more
 * than one place is audited once, with every role it was given.
 */
export function mergeWallets(
  declared: readonly Wallet[],
  registry: { address: string; entries: readonly RegistryEntry[] } | null,
  deployer: string | null,
  keeper: string | null = null,
): { wallets: Wallet[]; view: RegistryView | null } {
  const wallets: Wallet[] = declared.map((w) => ({ ...w }));
  const add = (address: string, role: string): void => {
    const w = wallets.find((x) => x.address === address);
    if (w) {
      if (!w.role.includes(role)) w.role += `; ${role}`;
    } else wallets.push({ address, role });
  };
  if (deployer !== null && !wallets.some((w) => w.address === deployer)) add(deployer, 'deployer (addresses / deployment file)');
  if (keeper !== null && !wallets.some((w) => w.address === keeper)) add(keeper, 'keeper (addresses / deployment file)');
  if (!registry) return { wallets, view: null };
  const inDoc = new Set(wallets.map((w) => w.address));
  for (const e of registry.entries) add(e.wallet, `TeamRegistry #${e.index}: ${e.role}`);
  const listed = new Set(registry.entries.map((e) => e.wallet));
  return {
    wallets,
    view: {
      address: registry.address,
      entries: [...registry.entries],
      onlyInRegistry: registry.entries.map((e) => e.wallet).filter((a) => !inDoc.has(a)),
      onlyInDoc: [...inDoc].filter((a) => !listed.has(a)),
      entry0IsDeployer: deployer === null ? null : registry.entries[0]?.wallet === deployer,
    },
  };
}

/** The wallets to audit by default: docs/WALLETS.md, the deployer, the keeper, and the registry when its address is known. */
export async function withRegistry(chain: Chain, known: Known, declared: readonly Wallet[]): Promise<{ wallets: Wallet[]; view: RegistryView | null }> {
  const entries = known.teamRegistry ? await readRegistry(chain, known.teamRegistry) : null;
  return mergeWallets(declared, entries && known.teamRegistry ? { address: known.teamRegistry, entries } : null, known.deployer, known.keeper);
}
