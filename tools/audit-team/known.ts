// Known addresses (addresses.json, optionally completed by a deployment file), the wallets table of
// docs/WALLETS.md, and names for function selectors.

import { readFileSync } from 'node:fs';
import { keccak256 } from '../../packages/chain/src/keccak.ts';
import { CREATE_TOKEN_SIGNATURE } from '../launch-check/decode.ts';
import type { Deployment } from '../launch-check/deployment.ts';
import { bytesToHex, parseAddress, sameAddress } from '../launch-check/hex.ts';

export type Kind =
  | 'manager'
  | 'tapeoutFactory'
  | 'router'
  | 'wokb'
  | 'transistors'
  | 'circuits'
  | 'splitter'
  | 'keeperTank'
  | 'teamRegistry'
  | 'sealedVM'
  | 'fab'
  | 'kernelFactory'
  | 'lens'
  | 'kernel'
  | 'kernelVault'
  | 'kernelToken'
  | 'wallet'
  | 'other';

export interface Known {
  chainId: number;
  manager: string;
  tapeoutFactory: string;
  router: string;
  wokb: string;
  /** The account that deploys every Covenant contract; entry 0 of the TeamRegistry. Always audited. */
  deployer: string | null;
  /** The keeper wallet (it only ever settles). Always audited. */
  keeper: string | null;
  /** The Covenant Architect's OKX.AI agent wallet (an OKX Agentic Wallet). Always audited. */
  agentWallet: string | null;
  /** null = not deployed yet / not filled in. */
  splitter: string | null;
  keeperTank: string | null;
  /** When set, the audit reads the registry's list (count / at) and audits those wallets too. */
  teamRegistry: string | null;
  transistors: string | null;
  circuits: string | null;
  sealedVM: string | null;
  fab: string | null;
  kernelFactory: string | null;
  lens: string | null;
  kernels: string[];
  /** label -> address, for further contracts the team calls, so that they are not listed as unknown targets. */
  other: Record<string, string>;
  /**
   * EIP-7702 delegates that are known smart-wallet implementations: address -> "name (source)". A wallet whose code
   * is exactly the designator 0xef0100 || one of these is a smart wallet, not a FLAG; its user operations are audited.
   */
  smartWallets: Record<string, string>;
  /** ERC-4337 EntryPoints whose UserOperationEvent logs are scanned for smart wallets. */
  entryPoints: { address: string; label: string }[];
}

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConfigError';
  }
}

const TOP = new Set(['description', 'chainId', 'ignixManager', 'tapeoutFactory', 'uniswapV2Router', 'wokb', 'covenant', 'other', 'entryPoints', 'smartWalletImplementations']);
/** The Covenant contracts, in the order of the signing sessions (deploy/rehearse.sh). */
export const COVENANT_CONTRACTS = ['splitter', 'keeperTank', 'teamRegistry', 'transistors', 'circuits', 'sealedVM', 'fab', 'kernelFactory', 'lens'] as const;
const COVENANT = new Set<string>(['comment', 'deployer', 'keeper', 'agentWallet', ...COVENANT_CONTRACTS, 'kernels']);

export function parseKnown(text: string, where: string = 'addresses.json'): Known {
  let o: Record<string, unknown>;
  try {
    o = JSON.parse(text) as Record<string, unknown>;
  } catch (e) {
    throw new ConfigError(`${where}: not valid JSON (${(e as Error).message})`);
  }
  if (o === null || typeof o !== 'object' || Array.isArray(o)) throw new ConfigError(`${where}: must be a JSON object`);
  for (const k of Object.keys(o)) if (!TOP.has(k)) throw new ConfigError(`${where}: unknown key "${k}"`);
  const addr = (v: unknown, what: string): string => {
    if (typeof v !== 'string') throw new ConfigError(`${where}: ${what} must be an address`);
    try {
      return parseAddress(v, what);
    } catch (e) {
      throw new ConfigError(`${where}: ${(e as Error).message}`);
    }
  };
  const orNull = (v: unknown, what: string): string | null => (v === null || v === undefined ? null : addr(v, what));
  const c = (o.covenant ?? {}) as Record<string, unknown>;
  if (typeof c !== 'object' || Array.isArray(c)) throw new ConfigError(`${where}: covenant must be an object`);
  for (const k of Object.keys(c)) if (!COVENANT.has(k)) throw new ConfigError(`${where}: unknown key "covenant.${k}"`);
  const kernels = c.kernels ?? [];
  if (!Array.isArray(kernels)) throw new ConfigError(`${where}: covenant.kernels must be a list of addresses`);
  const other: Record<string, string> = {};
  const rawOther = (o.other ?? {}) as Record<string, unknown>;
  if (typeof rawOther !== 'object' || Array.isArray(rawOther)) throw new ConfigError(`${where}: other must be an object of label -> address`);
  for (const [label, v] of Object.entries(rawOther)) {
    if (v !== null) other[label] = addr(v, `other.${label}`);
  }
  if (o.chainId !== 196) throw new ConfigError(`${where}: chainId must be 196 (X Layer)`);
  if (c.comment !== undefined && typeof c.comment !== 'string') throw new ConfigError(`${where}: covenant.comment must be text`);
  // ERC-4337 EntryPoints: { "comment": "...", "<label>": "0x..." }
  const entryPoints: { address: string; label: string }[] = [];
  const rawEp = (o.entryPoints ?? {}) as Record<string, unknown>;
  if (typeof rawEp !== 'object' || Array.isArray(rawEp)) throw new ConfigError(`${where}: entryPoints must be an object of label -> address`);
  for (const [label, v] of Object.entries(rawEp)) {
    if (label === 'comment') continue;
    entryPoints.push({ address: addr(v, `entryPoints.${label}`), label: `EntryPoint ${label}` });
  }
  // known smart-wallet implementations: { "comment": "...", "0x...": { "name": "...", "source": "..." } }
  const smartWallets: Record<string, string> = {};
  const rawSw = (o.smartWalletImplementations ?? {}) as Record<string, unknown>;
  if (typeof rawSw !== 'object' || Array.isArray(rawSw)) throw new ConfigError(`${where}: smartWalletImplementations must be an object`);
  for (const [a, v] of Object.entries(rawSw)) {
    if (a === 'comment') continue;
    const impl = addr(a, `smartWalletImplementations key ${a}`);
    const e = v as Record<string, unknown>;
    if (!e || typeof e !== 'object' || typeof e.name !== 'string' || typeof e.source !== 'string' || !e.name || !e.source) {
      throw new ConfigError(`${where}: smartWalletImplementations.${a} must give a "name" and the "source" that identifies it`);
    }
    smartWallets[impl] = `${e.name} (${e.source})`;
  }
  return {
    chainId: 196,
    manager: addr(o.ignixManager, 'ignixManager'),
    tapeoutFactory: addr(o.tapeoutFactory, 'tapeoutFactory'),
    router: addr(o.uniswapV2Router, 'uniswapV2Router'),
    wokb: addr(o.wokb, 'wokb'),
    deployer: orNull(c.deployer, 'covenant.deployer'),
    keeper: orNull(c.keeper, 'covenant.keeper'),
    agentWallet: orNull(c.agentWallet, 'covenant.agentWallet'),
    splitter: orNull(c.splitter, 'covenant.splitter'),
    keeperTank: orNull(c.keeperTank, 'covenant.keeperTank'),
    teamRegistry: orNull(c.teamRegistry, 'covenant.teamRegistry'),
    transistors: orNull(c.transistors, 'covenant.transistors'),
    circuits: orNull(c.circuits, 'covenant.circuits'),
    sealedVM: orNull(c.sealedVM, 'covenant.sealedVM'),
    fab: orNull(c.fab, 'covenant.fab'),
    kernelFactory: orNull(c.kernelFactory, 'covenant.kernelFactory'),
    lens: orNull(c.lens, 'covenant.lens'),
    kernels: kernels.map((k, i) => addr(k, `covenant.kernels[${i}]`)),
    other,
    smartWallets,
    entryPoints,
  };
}

/**
 * Completes the known addresses with a deployment file (deploy/rehearsal.json format). An address both name
 * must be the same; a disagreement is a configuration error. The deployment's kernel joins the kernel list.
 */
export function withDeployment(known: Known, d: Deployment): Known {
  const out: Known = { ...known, kernels: [...known.kernels], other: { ...known.other }, smartWallets: { ...known.smartWallets }, entryPoints: [...known.entryPoints] };
  const merge = (key: 'deployer' | 'keeper' | 'agentWallet' | (typeof COVENANT_CONTRACTS)[number]): void => {
    const mine = known[key];
    const theirs = d[key];
    if (mine !== null && theirs !== null && !sameAddress(mine, theirs)) {
      throw new ConfigError(`addresses.json says covenant.${key} is ${mine}, the deployment file ${d.source} says ${theirs}`);
    }
    out[key] = mine ?? theirs;
  };
  merge('deployer');
  merge('keeper');
  merge('agentWallet');
  for (const k of COVENANT_CONTRACTS) merge(k);
  if (d.kernel !== null && !out.kernels.some((k) => sameAddress(k, d.kernel as string))) out.kernels.push(d.kernel);
  return out;
}

export const loadKnown = (path: string): Known => {
  let text: string;
  try {
    text = readFileSync(path, 'utf8');
  } catch (e) {
    throw new ConfigError(`cannot read ${path}: ${(e as Error).message}`);
  }
  return parseKnown(text, path);
};

export interface Wallet {
  address: string;
  role: string;
}

/**
 * The wallets declared in the markdown table of docs/WALLETS.md: every table row whose second column holds
 * an address. A row without an address (a role "to be added") is returned in `pending`.
 */
export function parseWalletsTable(markdown: string): { wallets: Wallet[]; pending: string[] } {
  const wallets: Wallet[] = [];
  const pending: string[] = [];
  for (const line of markdown.split('\n')) {
    if (!line.trim().startsWith('|')) continue;
    const cells = line.split('|').slice(1, -1).map((c) => c.trim());
    if (cells.length < 2) continue;
    if (/^:?-{3,}:?$/.test(cells[1]) || /^address$/i.test(cells[1])) continue; // separator and header rows
    const found = cells[1].match(/0x[0-9a-fA-F]{40}(?![0-9a-fA-F])/g);
    if (!found) {
      if (cells[0]) pending.push(cells[0]);
      continue;
    }
    for (const a of found) {
      let address: string;
      try {
        address = parseAddress(a, `docs/WALLETS.md (${cells[0]})`);
      } catch (e) {
        throw new ConfigError((e as Error).message);
      }
      if (!wallets.some((w) => w.address === address)) wallets.push({ address, role: cells[0] });
    }
  }
  return { wallets, pending };
}

// ───────────────────────────── selector names ─────────────────────────────

const utf8 = new TextEncoder();
export const selectorOf = (signature: string): string => bytesToHex(keccak256(utf8.encode(signature)).slice(0, 4));
export const topicOf = (signature: string): string => bytesToHex(keccak256(utf8.encode(signature)));

/** Every function these tools can name. The selector is computed from the signature, never typed by hand. */
const SIGNATURES: readonly string[] = [
  // IgnixManager (contracts/vendor/ignix-xlayer/src/launch/IgnixManager.sol)
  CREATE_TOKEN_SIGNATURE,
  'buy(address,uint256,uint256)',
  'buyTo(address,uint256,uint256,address)',
  'buyFounder(address,uint256,uint256,uint256,bytes32[])',
  'sell(address,uint256,uint256)',
  'sellFrom(address,address,address,uint256,uint256,uint256,bytes)',
  'sellFromOrigin(address,address,address,uint256,uint256)',
  'sellFromAdapter(address,address,uint256,uint256)',
  'cancelSellAuthorizations()',
  'claimCreatorFees(address)',
  'claimPlatformFees(address)',
  'transferCurveDividend(address,address,uint256)',
  // ERC-20 / ERC-721 / ERC-1155
  'approve(address,uint256)',
  'transfer(address,uint256)',
  'transferFrom(address,address,uint256)',
  'safeTransferFrom(address,address,uint256)',
  'safeTransferFrom(address,address,uint256,bytes)',
  'safeTransferFrom(address,address,uint256,uint256,bytes)',
  'safeBatchTransferFrom(address,address,uint256[],uint256[],bytes)',
  'setApprovalForAll(address,bool)',
  // WOKB
  'deposit()',
  'withdraw(uint256)',
  // Uniswap V2 Router02
  'swapExactETHForTokens(uint256,address[],address,uint256)',
  'swapExactETHForTokensSupportingFeeOnTransferTokens(uint256,address[],address,uint256)',
  'swapETHForExactTokens(uint256,address[],address,uint256)',
  'swapExactTokensForETH(uint256,uint256,address[],address,uint256)',
  'swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)',
  'swapTokensForExactETH(uint256,uint256,address[],address,uint256)',
  'swapExactTokensForTokens(uint256,uint256,address[],address,uint256)',
  'swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)',
  'swapTokensForExactTokens(uint256,uint256,address[],address,uint256)',
  'addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)',
  'addLiquidityETH(address,uint256,uint256,uint256,address,uint256)',
  'removeLiquidity(address,address,uint256,uint256,uint256,address,uint256)',
  'removeLiquidityETH(address,uint256,uint256,uint256,address,uint256)',
  // IGNIX Directed vault (contracts/probes/src/interfaces/IDirectedVault.sol)
  'claim(address)',
  'claimFor(address,address)',
  'sync()',
  // Covenant kernel (chips/INTERFACE.md section 10), KernelFactory, Fab (section 11)
  'settle()',
  'bind(address)',
  'withdrawCredit(address,address)',
  'burnLocked()',
  'create((address,uint32,address,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,bool,address),uint256,bytes32)',
  'tapeoutChip(bytes,bytes32)',
  'tapeoutChipTo(bytes,bytes32,address)',
  // Covenant issuance (contracts/issuance/src): Splitter, KeeperTank, TeamRegistry
  'pull()',
  'claimMaintainer()',
  'settleAndRefund(address)',
  'topUp(uint256)',
  'invite(address)',
  'declare(string)',
  // TapeOut (contracts/vendor/tapeout-xlayer/src)
  'createCPU(string,string,string,uint256,uint256)',
  'mint(uint256,uint256)',
  'tapeout(bytes,uint32,uint32)',
  'burnFrom(address,uint256,uint256)',
  'withdraw()',
  'sweepFees()',
  // ERC-4337 EntryPoint v0.7
  'handleOps((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)[],address)',
];

const NAMES = new Map<string, string>();
for (const s of SIGNATURES) {
  const sel = selectorOf(s);
  if (!NAMES.has(sel)) NAMES.set(sel, s.slice(0, s.indexOf('(')));
}

/** The function name for a selector, or null. */
export const selectorName = (selector: string): string | null => NAMES.get(selector.toLowerCase()) ?? null;

export const SEL = {
  createToken: selectorOf(CREATE_TOKEN_SIGNATURE),
  erc1155Transfer: selectorOf('safeTransferFrom(address,address,uint256,uint256,bytes)'),
  erc1155BatchTransfer: selectorOf('safeBatchTransferFrom(address,address,uint256[],uint256[],bytes)'),
} as const;

export const TOPIC = {
  transfer: topicOf('Transfer(address,address,uint256)'),
  approval: topicOf('Approval(address,address,uint256)'),
  trade: topicOf('Trade(address,address,bool,uint256,uint256,uint256,uint256,uint256,uint256,uint128)'),
  transferSingle: topicOf('TransferSingle(address,address,address,uint256,uint256)'),
  transferBatch: topicOf('TransferBatch(address,address,address,uint256[],uint256[])'),
} as const;
