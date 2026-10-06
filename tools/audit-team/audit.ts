// The audit itself: for each declared wallet, find every transaction it has ever sent (walk.ts), fetch the
// receipts, learn what each target is, classify (classify.ts) and count the rules.

import { kernel as kernelCalls, kernelFactory as factoryCalls } from '../launch-check/kernel-abi.ts';
import { addressWord, strip0x } from '../launch-check/hex.ts';
import { createAddress } from '../launch-check/rlp.ts';
import type { AuthorizationUse, Chain, Receipt, Tx } from './chain.ts';
import { classify, type Classified, type Context, type Flag, type Target } from './classify.ts';
import { selectorOf, type Known, type Wallet } from './known.ts';
import type { RegistryView } from './registry.ts';
import { walkNonces, type NonceBlock, type WalkResult } from './walk.ts';

export type RuleId = Flag | 'delegation' | 'unexplained-nonce';

export const RULES: readonly { id: RuleId; title: string }[] = [
  { id: 'ignix-call', title: 'calls to IgnixManager other than createToken' },
  { id: 'first-buy', title: 'createToken with a first buy (or with calldata that does not decode)' },
  { id: 'dex-call', title: 'calls to the Uniswap V2 router or to WOKB' },
  { id: 'ignix-token-call', title: 'transactions to a token launched through IgnixManager (approve, transfer, ...)' },
  { id: 'ignix-activity', title: 'IGNIX trades or token movements inside transactions to other contracts (seen in logs)' },
  { id: 'kernel-value', title: 'native value sent to a kernel or to its vault' },
  { id: 'transistor-transfer', title: 'transfers of Covenant transistors (ERC-1155 safeTransferFrom / safeBatchTransferFrom)' },
  { id: 'delegation', title: 'wallets that are not plain externally owned accounts (code or an EIP-7702 delegation)' },
  { id: 'unexplained-nonce', title: 'nonces that no transaction of the wallet explains' },
];

/** One line of the report: a transaction, or a nonce used by an EIP-7702 authorisation. */
export interface Row extends Classified {
  wallet: string;
  role: string;
  block: number;
  timestamp: number;
  nonce: number;
  hash: string;
  valueWei: string;
  kind: 'transaction' | 'authorization';
}

export interface WalletReport {
  wallet: Wallet;
  /** eth_getTransactionCount at the audit block. */
  transactionCount: number;
  /** Nonces the audit looked at (transactionCount unless capped). */
  audited: number;
  /** Transactions found among them. */
  found: number;
  rows: Row[];
  /** Runtime code at the audit block ("0x" for a plain account). */
  code: string;
  /** Nonces in the audited range that nothing explains. */
  unexplained: number[];
  walk: { rounds: number; probes: number };
}

export interface RuleResult {
  id: RuleId;
  title: string;
  count: number;
  reverted: number;
  /** Set when the rule could not be decided for some transactions. */
  notChecked: string | null;
  examples: string[];
}

export interface AuditResult {
  chainId: number;
  block: number;
  blockTime: number;
  rpc: string;
  wallets: WalletReport[];
  pendingRoles: string[];
  rules: RuleResult[];
  unknownTargets: number;
  /** Which optional addresses were configured (for the notes on the verdict lines). */
  rulesContext: { kernelsKnown: boolean; transistorsKnown: boolean };
  /** The on-chain TeamRegistry, when its address was configured and the wallets were not given by hand. */
  registry: RegistryView | null;
  /** True when the wallets came from --wallet (then neither the table nor the registry was read). */
  walletsByHand: boolean;
  /** Reasons the audit is not complete (a cap, an unconfigured address that mattered, ...). */
  incomplete: string[];
  /** 0 clean, 1 flagged, 2 incomplete without a flag. */
  exitCode: 0 | 1 | 2;
  stats: Chain['stats'];
}

export interface AuditOptions {
  /** Audit only the first N nonces of each wallet. The result is then never "clean". */
  maxNonces?: number;
  pendingRoles?: readonly string[];
  log?: (message: string) => void;
  /** What the registry listed (see registry.ts); its wallets must already be in `wallets`. */
  registry?: RegistryView | null;
  walletsByHand?: boolean;
}

const ZERO = '0x0000000000000000000000000000000000000000';
const short = (a: string): string => a.slice(0, 6) + '...' + a.slice(-4);

/**
 * Finds the block of every nonce of `address` up to the audit block.
 *
 * The part of the chain that can no longer change (up to the safe head) is walked once and remembered:
 * a later run asks only whether the count at the remembered block is still the remembered count, then
 * walks the blocks after it. With `cap`, only the first `cap` nonces are located and nothing is remembered.
 */
async function locate(chain: Chain, address: string, cap: number | undefined): Promise<WalkResult> {
  const probe = async (blocks: readonly number[]): Promise<number[]> => {
    const c = await chain.counts(address, blocks);
    return cap === undefined ? c : c.map((x) => Math.min(x, cap));
  };
  if (cap !== undefined) return walkNonces(probe, chain.head);

  const safe = chain.safeHead();
  let base = chain.storedWalk(address);
  if (base) {
    const [still] = await chain.counts(address, [base.head]);
    if (still !== base.total) base = null; // the remembered walk is not what the chain says: start again
  }
  const older = await walkNonces(probe, safe, { floor: base ? base.head : 0 });
  const blocks: NonceBlock[] = [...(base ? base.blocks.map(([block, firstNonce, lastNonce]) => ({ block, firstNonce, lastNonce })) : []), ...older.blocks];
  const atFloor = base ? base.atFloor : older.atFloor;
  chain.storeWalk(address, { head: safe, atFloor, total: older.total, blocks: blocks.map((b) => [b.block, b.firstNonce, b.lastNonce]) });
  const newer = await walkNonces(probe, chain.head, { floor: safe });
  return { total: newer.total, atFloor, blocks: [...blocks, ...newer.blocks], rounds: older.rounds + newer.rounds, probes: older.probes + newer.probes + (base ? 1 : 0) };
}

/** A 32-byte return word as an address, or null if the data is anything else. */
const wordAddress = (ret: unknown): string | null => {
  if (typeof ret !== 'string') return null;
  const h = strip0x(ret);
  if (h.length !== 64 || !/^0{24}/.test(h)) return null;
  return '0x' + h.slice(24);
};

export async function runAudit(chain: Chain, known: Known, wallets: readonly Wallet[], opts: AuditOptions = {}): Promise<AuditResult> {
  const log = opts.log ?? (() => {});
  if (chain.chainId !== known.chainId) throw new Error(`the node is chain ${chain.chainId}, not ${known.chainId} (X Layer)`);
  const incomplete: string[] = [];
  const registry = opts.registry ?? null;
  if (registry && registry.entry0IsDeployer === false) {
    incomplete.push(`entry 0 of the TeamRegistry ${registry.address} is ${registry.entries[0]?.wallet ?? 'missing'}, not the deployer ${known.deployer}: covenant.teamRegistry is not the Covenant registry, so the list of team wallets cannot be trusted`);
  }
  if (registry) for (const e of registry.entries) if (!wallets.some((w) => w.address === e.wallet)) throw new Error(`TeamRegistry wallet ${e.wallet} is not among the wallets to audit`);

  // ── 1. every transaction of every wallet
  const reports: WalletReport[] = [];
  const all: { wallet: Wallet; tx: Tx }[] = [];
  const auths: { wallet: Wallet; use: AuthorizationUse; block: number; timestamp: number }[] = [];
  const codes = await chain.codes(wallets.map((w) => w.address));
  for (const [wi, wallet] of wallets.entries()) {
    const walk = await locate(chain, wallet.address, opts.maxNonces);
    const [transactionCount] = await chain.counts(wallet.address, [chain.head]);
    log(`${wallet.address}: ${transactionCount} nonce(s) at block ${chain.head}; located ${walk.total} in ${walk.blocks.length} block(s) with ${walk.probes} count queries`);
    if (walk.atFloor !== 0) incomplete.push(`${wallet.address} already had nonce ${walk.atFloor} at block 0: those nonces cannot be located`);
    if (walk.total < transactionCount) {
      incomplete.push(`${wallet.address}: only the first ${walk.total} of ${transactionCount} nonces were audited (--max-nonces); ${transactionCount - walk.total} later transaction(s) were NOT looked at`);
    }

    const blocks = await chain.walletBlocks(wallet.address, walk.blocks.map((b) => b.block));
    const unexplained: number[] = [];
    let found = 0;
    walk.blocks.forEach((nb, i) => {
      const wb = blocks[i];
      for (let n = nb.firstNonce; n <= nb.lastNonce; n++) {
        const tx = wb.txs.find((t) => t.nonce === n);
        if (tx) {
          all.push({ wallet, tx });
          found++;
          continue;
        }
        const use = wb.authorizations.find((a) => a.nonce === n);
        if (use) auths.push({ wallet, use, block: nb.block, timestamp: wb.timestamp });
        else unexplained.push(n);
      }
    });
    reports.push({ wallet, transactionCount, audited: walk.total, found, rows: [], code: codes[wi], unexplained, walk: { rounds: walk.rounds, probes: walk.probes } });
  }

  // ── 2. receipts
  const receipts = await chain.receipts(all.map((x) => x.tx.hash));

  // ── 3. what every target and every log emitter is
  const targets = new Map<string, Target>();
  const put = (address: string | null, kind: Target['kind'], label: string): void => {
    if (address && !targets.has(address)) targets.set(address, { kind, label });
  };
  put(known.manager, 'manager', 'IgnixManager');
  put(known.router, 'router', 'Uniswap V2 router');
  put(known.wokb, 'wokb', 'WOKB');
  put(known.tapeoutFactory, 'tapeoutFactory', 'TapeOut factory');
  put(known.transistors, 'transistors', 'Covenant Transistors');
  put(known.circuits, 'circuits', 'Covenant Circuits');
  put(known.splitter, 'splitter', 'Covenant Splitter');
  put(known.keeperTank, 'keeperTank', 'Covenant KeeperTank');
  put(known.teamRegistry, 'teamRegistry', 'Covenant TeamRegistry');
  put(known.sealedVM, 'sealedVM', 'Covenant SealedVM');
  put(known.fab, 'fab', 'Covenant Fab');
  put(known.kernelFactory, 'kernelFactory', 'Covenant KernelFactory');
  put(known.lens, 'lens', 'Covenant Lens');
  known.kernels.forEach((k, i) => put(k, 'kernel', `Covenant kernel #${i + 1}`));
  for (const [label, a] of Object.entries(known.other)) put(a, 'other', label);
  for (const w of wallets) put(w.address, 'wallet', `team wallet: ${w.role}`);

  const unknown = [...new Set(all.map((x) => x.tx.to).filter((t): t is string => t !== null && !targets.has(t)))];
  const emitters = [...new Set(receipts.flatMap((r) => r.logs.map((l) => l.address)).filter((a) => !targets.has(a) && !unknown.includes(a)))];
  const candidates = [...unknown, ...emitters];

  // IgnixManager.creatorOf(x) != 0 means x is a token launched through IGNIX
  const creators = await chain.calls(candidates.map((a) => ({ to: known.manager, data: selectorOf('creatorOf(address)') + addressWord(a) })));
  const ignixTokens = new Set<string>();
  candidates.forEach((a, i) => {
    const c = wordAddress(creators[i]);
    if (c === null) throw new Error(`IgnixManager.creatorOf(${a}) did not return an address: the rule "transaction to an IGNIX token" cannot be checked`);
    if (c !== ZERO) ignixTokens.add(a);
  });

  // kernels: the configured list, plus anything the KernelFactory says is one
  const kernels = new Set(known.kernels);
  if (known.kernelFactory && unknown.length) {
    const f = factoryCalls(known.kernelFactory);
    const is = await chain.calls(unknown.map((a) => f.isKernel(a)));
    unknown.forEach((a, i) => {
      const r = is[i];
      if (typeof r !== 'string') throw new Error(`KernelFactory.isKernel(${a}) reverted: the rule "value sent to a kernel" cannot be checked (re-check kernel-abi.ts)`);
      if (f.isKernel(a).decode(r)) {
        kernels.add(a);
        targets.set(a, { kind: 'kernel', label: 'Covenant kernel (per the KernelFactory)' });
      }
    });
  }
  // each kernel's vault and token
  const kernelList = [...kernels];
  if (kernelList.length) {
    const reads = await chain.calls(kernelList.flatMap((k) => [kernelCalls(k).vault(), kernelCalls(k).token()]));
    kernelList.forEach((k, i) => {
      const vault = wordAddress(reads[2 * i]);
      const token = wordAddress(reads[2 * i + 1]);
      if (vault === null || token === null) throw new Error(`kernel ${k} did not answer vault() and token(): the rule "value sent to a kernel or its vault" cannot be checked (re-check kernel-abi.ts)`);
      if (vault !== ZERO) targets.set(vault, { kind: 'kernelVault', label: `vault of kernel ${short(k)}` });
      if (token !== ZERO) {
        targets.set(token, { kind: 'kernelToken', label: `token of kernel ${short(k)}` });
        ignixTokens.add(token);
      }
    });
  }

  // the remaining unknown targets: code or not, IGNIX token, IGNIX vault
  const rest = unknown.filter((a) => !targets.has(a));
  const restCodes = await chain.codes(rest);
  // a Directed vault answers TOKEN(); it is an IGNIX vault if the Manager's vaultOf(that token) is this address
  const vaultTokens = await chain.calls(rest.map((a) => ({ to: a, data: selectorOf('TOKEN()') })));
  const claims = rest.map((a, i) => ({ address: a, token: restCodes[i] === '0x' ? null : wordAddress(vaultTokens[i]) })).filter((c): c is { address: string; token: string } => c.token !== null && c.token !== ZERO);
  const vaultOf = await chain.calls(claims.map((c) => ({ to: known.manager, data: selectorOf('vaultOf(address)') + addressWord(c.token) })));
  const vaults = new Map<string, string>();
  claims.forEach((c, i) => {
    if (wordAddress(vaultOf[i]) === c.address) vaults.set(c.address, c.token);
  });
  rest.forEach((a, i) => {
    if (ignixTokens.has(a)) targets.set(a, { kind: 'ignixToken', label: 'IGNIX-launched token' });
    else if (vaults.has(a)) targets.set(a, { kind: 'ignixVault', label: `IGNIX vault of token ${short(vaults.get(a) as string)}` });
    else targets.set(a, { kind: 'unknown', label: 'unknown target', isContract: restCodes[i] !== '0x' });
  });
  // contracts the wallets deployed themselves
  for (const { wallet, tx } of all) {
    if (tx.to !== null) continue;
    const created = createAddress(wallet.address, tx.nonce);
    const t = targets.get(created);
    if (!t) targets.set(created, { kind: 'unknown', label: `a contract deployed by ${short(wallet.address)} at nonce ${tx.nonce}`, isContract: true });
    else if (t.kind === 'unknown') t.label = `a contract deployed by ${short(wallet.address)} at nonce ${tx.nonce}`;
  }

  const ctx: Context = { targets, ignixTokens, manager: known.manager, transistors: known.transistors, kernelsKnown: kernels.size > 0 || known.kernelFactory !== null };

  // ── 4. classify
  all.forEach(({ wallet, tx }, i) => {
    const c = classify(tx, receipts[i], ctx);
    const report = reports.find((r) => r.wallet.address === wallet.address) as WalletReport;
    report.rows.push({ ...c, wallet: wallet.address, role: wallet.role, block: tx.blockNumber, timestamp: tx.timestamp, nonce: tx.nonce, hash: tx.hash, valueWei: BigInt(tx.value).toString(), kind: 'transaction' });
  });
  for (const { wallet, use, block, timestamp } of auths) {
    const report = reports.find((r) => r.wallet.address === wallet.address) as WalletReport;
    report.rows.push({
      wallet: wallet.address,
      role: wallet.role,
      block,
      timestamp,
      nonce: use.nonce,
      hash: use.carrier,
      valueWei: '0',
      kind: 'authorization',
      target: use.delegate,
      targetLabel: use.delegate === ZERO ? 'delegation cleared' : 'delegate contract',
      selector: null,
      selectorName: null,
      classification:
        (use.delegate === ZERO ? 'EIP-7702 AUTHORISATION that clears the wallet\'s delegation' : `EIP-7702 AUTHORISATION: the wallet delegated its code to ${use.delegate}`) +
        ` (carried by a transaction from ${use.carrierFrom})`,
      flags: [],
      unknownTarget: false,
      undecided: [],
      reverted: false,
    });
  }
  for (const r of reports) r.rows.sort((a, b) => a.nonce - b.nonce);

  // ── 5. rules
  const rows = reports.flatMap((r) => r.rows);
  const rules: RuleResult[] = RULES.map(({ id, title }) => {
    let hits: Row[] = [];
    let examples: string[] = [];
    let notChecked: string | null = null;
    if (id === 'delegation') {
      const coded = reports.filter((r) => r.code !== '0x');
      hits = rows.filter((r) => r.kind === 'authorization');
      examples = [
        ...coded.map((r) => `${r.wallet.address} has code at block ${chain.head}${/^0xef0100[0-9a-f]{40}$/i.test(r.code) ? ` (EIP-7702 delegation to 0x${r.code.slice(8)})` : ' (it is a contract)'}`),
        ...hits.map((r) => `${short(r.wallet)} nonce ${r.nonce}`),
      ];
      return { id, title, count: coded.length + hits.length, reverted: 0, notChecked, examples };
    }
    if (id === 'unexplained-nonce') {
      const n = reports.reduce((s, r) => s + r.unexplained.length, 0);
      examples = reports.filter((r) => r.unexplained.length).map((r) => `${short(r.wallet.address)} nonce(s) ${r.unexplained.join(', ')}`);
      return { id, title, count: n, reverted: 0, notChecked, examples };
    }
    hits = rows.filter((r) => r.flags.includes(id));
    examples = hits.slice(0, 8).map((r) => `${short(r.wallet)} nonce ${r.nonce}`);
    const undecided = rows.filter((r) => r.undecided.includes(id));
    if (undecided.length) {
      notChecked =
        id === 'kernel-value'
          ? `no kernel and no KernelFactory is configured in addresses.json, and ${undecided.length} transaction(s) sent value to contracts that are not in the known list (${undecided.slice(0, 5).map((r) => `${short(r.wallet)} nonce ${r.nonce}`).join('; ')})`
          : `covenant.transistors is not configured in addresses.json, and ${undecided.length} transaction(s) look like ERC-1155 transfers (${undecided.slice(0, 5).map((r) => `${short(r.wallet)} nonce ${r.nonce}`).join('; ')})`;
    }
    return { id, title, count: hits.length, reverted: hits.filter((r) => r.reverted).length, notChecked, examples };
  });
  for (const r of rules) if (r.notChecked) incomplete.push(`rule "${r.title}" could not be decided: ${r.notChecked}`);

  const flagged = rules.some((r) => r.count > 0);
  return {
    chainId: chain.chainId,
    block: chain.head,
    blockTime: chain.headTimestamp,
    rpc: chain.rpc.current(),
    wallets: reports,
    pendingRoles: [...(opts.pendingRoles ?? [])],
    rules,
    unknownTargets: rows.filter((r) => r.unknownTarget).length,
    rulesContext: { kernelsKnown: ctx.kernelsKnown, transistorsKnown: known.transistors !== null },
    registry,
    walletsByHand: opts.walletsByHand ?? false,
    incomplete,
    exitCode: flagged ? 1 : incomplete.length ? 2 : 0,
    stats: chain.stats,
  };
}
