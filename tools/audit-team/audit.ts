// The audit itself: for each declared wallet, find every transaction it has ever sent (walk.ts), fetch the
// receipts, learn what each target is, classify (classify.ts) and count the rules.

import { kernel as kernelCalls, kernelFactory as factoryCalls } from '../launch-check/kernel-abi.ts';
import { addressWord, strip0x } from '../launch-check/hex.ts';
import { createAddress } from '../launch-check/rlp.ts';
import type { AuthorizationUse, Chain, Receipt, ScanLog, Tx } from './chain.ts';
import { classify, isKernelish, usdt0Amount, usdt0CallParties, type Classified, type Context, type Flag, type Target } from './classify.ts';
import { TOPIC, selectorOf, type Known, type Wallet } from './known.ts';
import type { RegistryView } from './registry.ts';
import { classifyUserOp, findUserOps, type UserOp } from './userops.ts';
import { walkNonces, type NonceBlock, type WalkResult } from './walk.ts';

export type RuleId = Flag | 'delegation' | 'unexplained-nonce';

export const RULES: readonly { id: RuleId; title: string }[] = [
  { id: 'ignix-call', title: 'calls to IgnixManager other than createToken' },
  { id: 'first-buy', title: 'createToken with a first buy (or with calldata that does not decode)' },
  { id: 'dex-call', title: 'calls to the Uniswap V2 router or to WOKB' },
  { id: 'ignix-token-call', title: 'transactions to a token launched through IgnixManager (approve, transfer, ...)' },
  { id: 'ignix-activity', title: 'IGNIX trades or token movements inside transactions to other contracts (seen in logs)' },
  { id: 'kernel-value', title: 'native value sent to a kernel or to its vault' },
  { id: 'kernel-usdt0', title: 'USD₮0 sent from a team wallet to a kernel or to its vault (by its own transaction or user operation, or by an EIP-3009 authorisation or allowance anyone executed, such as an x402 payment)' },
  { id: 'transistor-transfer', title: 'transfers of Covenant transistors (ERC-1155 safeTransferFrom / safeBatchTransferFrom)' },
  { id: 'delegation', title: 'wallets that are neither plain accounts nor known smart wallets (contract code, or an EIP-7702 delegation to an unknown implementation)' },
  { id: 'unexplained-nonce', title: 'nonces that no transaction of the wallet explains' },
];

/** One line of the report: a transaction, a nonce used by an EIP-7702 authorisation, or a user operation. */
export interface Row extends Classified {
  wallet: string;
  role: string;
  block: number;
  timestamp: number;
  /** The account nonce (transactions, authorisations), or the user operation's 4337 sequence number. */
  nonce: number;
  /** The transaction: the wallet's own, the one that carried the authorisation, or the bundle. */
  hash: string;
  /** Wei sent; '' for a user operation, whose value is not visible in its logs, and for a USD₮0 transfer. */
  valueWei: string;
  /** 'usdt0Transfer': USD₮0 moved from the wallet by a transaction it did not send (an EIP-3009 authorisation, such
   *  as an x402 payment, or an allowance), found by the USD₮0 scan. */
  kind: 'transaction' | 'authorization' | 'userOperation' | 'usdt0Transfer';
  /** How a finding names this row: "nonce 3", "user op 0x1234abcd...". */
  ref: string;
  /** User operations only. */
  userOpHash?: string;
  /** Order inside the block (transaction index, or log index for a user operation). */
  position: number;
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
  /** Set when the code is exactly an EIP-7702 designator to a known smart-wallet implementation. */
  smartWallet: { implementation: string; label: string } | null;
  /** The user-operation scan of this wallet, or null when the wallet never had code (no scan is needed). */
  userOps: UserOpScan | null;
}

export interface UserOpScan {
  scanned: boolean;
  /** Why it was not scanned, when it was not. */
  why?: string;
  /** EntryPoints scanned (with code at the audit block) and those skipped (no code there, so no operation). */
  entryPoints: string[];
  skipped: string[];
  from: number;
  to: number;
  found: number;
}

/** The scan for USD₮0 that other accounts moved out of the team wallets (EIP-3009 authorisations, allowances). */
export interface Usdt0Scan {
  scanned: boolean;
  /** Why it was not scanned, when it was not. */
  why?: string;
  /** Blocks scanned: from the creation of the KernelFactoryV2 (no v2 kernel exists before it) to the audit block. */
  from: number;
  to: number;
  /** USD₮0 transfers from the team wallets found in transactions they did not send. */
  found: number;
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
  /** The USD₮0 scan (kernel v2), or null when neither USD₮0 nor a KernelFactoryV2 is configured. */
  usdt0Scan: Usdt0Scan | null;
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
  const walks: WalkResult[] = [];
  for (const [wi, wallet] of wallets.entries()) {
    const walk = await locate(chain, wallet.address, opts.maxNonces);
    walks.push(walk);
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
    const designated = /^0xef0100[0-9a-f]{40}$/i.test(codes[wi]) ? '0x' + codes[wi].slice(8).toLowerCase() : null;
    const smartWallet = designated && known.smartWallets[designated] ? { implementation: designated, label: known.smartWallets[designated] } : null;
    reports.push({ wallet, transactionCount, audited: walk.total, found, rows: [], code: codes[wi], unexplained, walk: { rounds: walk.rounds, probes: walk.probes }, smartWallet, userOps: null });
  }

  // ── 1b. user operations of every wallet that has, or had, code (an EIP-7702 delegation or a contract)
  const ops: { wallet: Wallet; op: UserOp }[] = [];
  const epCodes = await chain.codes(known.entryPoints.map((e) => e.address));
  const liveEntryPoints = known.entryPoints.filter((_, i) => epCodes[i] !== '0x');
  const deadEntryPoints = known.entryPoints.filter((_, i) => epCodes[i] === '0x');
  for (const [wi, report] of reports.entries()) {
    const hadCode = report.code !== '0x' || auths.some((a) => a.wallet.address === report.wallet.address);
    if (!hadCode) continue;
    const scan: UserOpScan = { scanned: false, entryPoints: liveEntryPoints.map((e) => e.label), skipped: deadEntryPoints.map((e) => e.label), from: 0, to: chain.head, found: 0 };
    report.userOps = scan;
    const first = walks[wi].blocks[0]?.block;
    if (opts.maxNonces !== undefined) {
      scan.why = 'only the first nonces were audited (--max-nonces)';
      incomplete.push(`${report.wallet.address} has code, but its user operations were NOT scanned (--max-nonces)`);
      continue;
    }
    if (!known.entryPoints.length) {
      scan.why = 'no EntryPoint is configured in addresses.json';
      incomplete.push(`${report.wallet.address} has code, but no EntryPoint is configured: its user operations were NOT scanned`);
      continue;
    }
    if (first === undefined || walks[wi].atFloor !== 0) {
      scan.why = 'the block of its first activity is unknown';
      incomplete.push(`${report.wallet.address} has code, but the block of its first activity is unknown: its user operations were NOT scanned`);
      continue;
    }
    scan.from = first;
    const found = await findUserOps(chain, report.wallet.address, liveEntryPoints, first, log);
    scan.scanned = true;
    scan.found = found.length;
    log(`${report.wallet.address}: ${found.length} user operation(s) through ${scan.entryPoints.join(', ')} in blocks ${first}..${chain.head}`);
    for (const op of found) ops.push({ wallet: report.wallet, op });
  }
  const opHashes = [...new Set(ops.map((o) => o.op.log.transactionHash))];
  const opReceiptList = await chain.receipts(opHashes);
  const opReceipts = new Map(opHashes.map((h, i) => [h, opReceiptList[i]]));
  const opCarriers = await chain.batch(opHashes.map((h) => ['eth_getTransactionByHash', [h]] as const), true);
  const bundlerOf = new Map(opHashes.map((h, i) => [h, ((opCarriers[i] as { from?: string } | null)?.from ?? null)?.toLowerCase() ?? null]));
  const opTimes = await chain.blockTimes(ops.map((o) => o.op.log.blockNumber));

  // ── 2. receipts
  const receipts = await chain.receipts(all.map((x) => x.tx.hash));

  // ── 2b. USD₮0 that other accounts moved out of the team wallets: an EIP-3009 authorisation (an x402 payment is one)
  //    or an allowance needs no transaction, no nonce and no user operation of the wallet. Every USD₮0 Transfer from a
  //    team wallet, from the creation of the KernelFactoryV2 (no kernel quoted in USD₮0 exists before it) to the audit
  //    block, in a transaction the wallet did not send itself.
  let usdt0Scan: Usdt0Scan | null = null;
  const moved: ScanLog[] = [];
  if (known.usdt0 && known.kernelFactoryV2) {
    usdt0Scan = { scanned: false, from: 0, to: chain.head, found: 0 };
    const start = await chain.firstCodeBlock(known.kernelFactoryV2);
    if (start === null) {
      usdt0Scan.why = `the KernelFactoryV2 ${known.kernelFactoryV2} has no code at the audit block`;
      incomplete.push(`USD₮0 moved from the team wallets by authorisations was NOT scanned: ${usdt0Scan.why}`);
    } else if (opts.maxNonces !== undefined) {
      usdt0Scan.why = 'only the first nonces were audited (--max-nonces)';
      incomplete.push(`USD₮0 moved from the team wallets by authorisations was NOT scanned (--max-nonces)`);
    } else {
      usdt0Scan.from = start;
      const own = new Set([...all.map((x) => x.tx.hash), ...ops.map((o) => o.op.log.transactionHash)]);
      const walletTopics = wallets.map((w) => '0x' + w.address.replace(/^0x/, '').toLowerCase().padStart(64, '0'));
      const logs = await chain.scanLogs(known.usdt0, [TOPIC.transfer, walletTopics, null], start, (done, total) => {
        if (total > 50) log(`USD₮0 transfers from the team wallets: ${done} of ${total} eth_getLogs chunks`);
      });
      for (const l of logs) if (!own.has(l.transactionHash)) moved.push(l);
      usdt0Scan.scanned = true;
      usdt0Scan.found = moved.length;
      log(`USD₮0: ${moved.length} transfer(s) from the team wallets in transactions they did not send, blocks ${start}..${chain.head}`);
    }
  } else if (known.kernelFactoryV2 && !known.usdt0) {
    usdt0Scan = { scanned: false, why: 'usdt0 is not configured in addresses.json', from: 0, to: chain.head, found: 0 };
    incomplete.push('a KernelFactoryV2 is configured but usdt0 is not: USD₮0 sent to v2 kernels cannot be checked');
  }

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
  put(known.kernelFactoryV2, 'kernelFactory', 'Covenant KernelFactoryV2 (kernel v2, USD₮0 quote)');
  put(known.lensV2, 'lens', 'Covenant LensV2');
  put(known.usdt0, 'other', 'USD₮0');
  for (const ep of known.entryPoints) put(ep.address, 'other', `ERC-4337 ${ep.label}`);
  known.kernels.forEach((k, i) => put(k, 'kernel', `Covenant kernel #${i + 1}`));
  for (const [label, a] of Object.entries(known.other)) put(a, 'other', label);
  for (const w of wallets) put(w.address, 'wallet', `team wallet: ${w.role}`);

  const unknown = [...new Set(all.map((x) => x.tx.to).filter((t): t is string => t !== null && !targets.has(t)))];
  const emitters = [...new Set([...receipts, ...opReceiptList].flatMap((r) => r.logs.map((l) => l.address)).filter((a) => !targets.has(a) && !unknown.includes(a)))];
  const candidates = [...unknown, ...emitters];

  // IgnixManager.creatorOf(x) != 0 means x is a token launched through IGNIX
  const creators = await chain.calls(candidates.map((a) => ({ to: known.manager, data: selectorOf('creatorOf(address)') + addressWord(a) })));
  const ignixTokens = new Set<string>();
  candidates.forEach((a, i) => {
    const c = wordAddress(creators[i]);
    if (c === null) throw new Error(`IgnixManager.creatorOf(${a}) did not return an address: the rule "transaction to an IGNIX token" cannot be checked`);
    if (c !== ZERO) ignixTokens.add(a);
  });

  // where USD₮0 from a team wallet went: Transfer logs in the wallets' own receipts, USD₮0 transfer calls, the scan
  const usdTo = new Set<string>();
  if (known.usdt0) {
    const fromWallet = (l: { address: string; topics: string[] }): boolean =>
      l.address === known.usdt0 && l.topics[0] === TOPIC.transfer && l.topics.length === 3 && wallets.some((w) => w.address === '0x' + l.topics[1].slice(26).toLowerCase());
    for (const r of [...receipts, ...opReceiptList]) for (const l of r.logs) if (fromWallet(l)) usdTo.add('0x' + l.topics[2].slice(26).toLowerCase());
    for (const { tx } of all) {
      const p = tx.to === known.usdt0 ? usdt0CallParties(tx.input) : null;
      if (p) usdTo.add(p.to);
    }
    for (const l of moved) usdTo.add('0x' + l.topics[2].slice(26).toLowerCase());
  }
  const usdUnknown = [...usdTo].filter((a) => !targets.has(a) && !unknown.includes(a));

  // kernels: the configured list (both flagships), plus anything either KernelFactory says is one
  const kernels = new Set(known.kernels);
  for (const [factory, label] of [[known.kernelFactory, 'KernelFactory'], [known.kernelFactoryV2, 'KernelFactoryV2']] as const) {
    const ask = [...unknown, ...usdUnknown].filter((a) => !kernels.has(a));
    if (!factory || !ask.length) continue;
    const f = factoryCalls(factory);
    const is = await chain.calls(ask.map((a) => f.isKernel(a)));
    ask.forEach((a, i) => {
      const r = is[i];
      if (typeof r !== 'string') throw new Error(`${label}.isKernel(${a}) reverted: the rules "value or USD₮0 sent to a kernel" cannot be checked (re-check kernel-abi.ts)`);
      if (f.isKernel(a).decode(r)) {
        kernels.add(a);
        targets.set(a, { kind: 'kernel', label: `Covenant kernel (per the ${label})` });
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

  // the other USD₮0 recipients: named for the report (a kernel's vault is already named above)
  for (const a of usdUnknown) if (!targets.has(a)) targets.set(a, { kind: 'other', label: 'a USD₮0 recipient that is not a kernel' });

  const ctx: Context = { targets, ignixTokens, manager: known.manager, transistors: known.transistors, kernelsKnown: kernels.size > 0 || known.kernelFactory !== null || known.kernelFactoryV2 !== null, usdt0: known.usdt0 };

  // ── 4. classify
  all.forEach(({ wallet, tx }, i) => {
    const c = classify(tx, receipts[i], ctx);
    const report = reports.find((r) => r.wallet.address === wallet.address) as WalletReport;
    report.rows.push({ ...c, wallet: wallet.address, role: wallet.role, block: tx.blockNumber, timestamp: tx.timestamp, nonce: tx.nonce, hash: tx.hash, valueWei: BigInt(tx.value).toString(), kind: 'transaction', ref: `nonce ${tx.nonce}`, position: tx.transactionIndex });
  });
  ops.forEach(({ wallet, op }, i) => {
    const c = classifyUserOp(op, opReceipts.get(op.log.transactionHash) as Receipt, ctx, wallet.address, bundlerOf.get(op.log.transactionHash) ?? null);
    const report = reports.find((r) => r.wallet.address === wallet.address) as WalletReport;
    report.rows.push({
      ...c,
      wallet: wallet.address,
      role: wallet.role,
      block: op.log.blockNumber,
      timestamp: opTimes[i],
      nonce: Number(op.nonce & 0xffffffffffffffffn),
      hash: op.log.transactionHash,
      valueWei: '',
      kind: 'userOperation',
      ref: `user op ${op.userOpHash.slice(0, 10)}...`,
      userOpHash: op.userOpHash,
      position: op.log.logIndex,
    });
  });
  // USD₮0 that other accounts moved out of the team wallets
  const movedTimes = await chain.blockTimes(moved.map((l) => l.blockNumber));
  moved.forEach((l, i) => {
    const from = '0x' + l.topics[1].slice(26).toLowerCase();
    const to = '0x' + l.topics[2].slice(26).toLowerCase();
    const wallet = wallets.find((w) => w.address === from) as Wallet;
    const report = reports.find((r) => r.wallet.address === from) as WalletReport;
    const intoKernel = isKernelish(ctx, to);
    report.rows.push({
      wallet: wallet.address,
      role: wallet.role,
      block: l.blockNumber,
      timestamp: movedTimes[i],
      nonce: -1,
      hash: l.transactionHash,
      valueWei: '',
      kind: 'usdt0Transfer',
      ref: `USD₮0 transfer ${l.transactionHash.slice(0, 10)}...`,
      position: l.logIndex,
      target: to,
      targetLabel: targets.get(to)?.label ?? 'USD₮0 recipient',
      selector: null,
      selectorName: null,
      classification:
        `${usdt0Amount(l.data)} moved from the wallet by a transaction it did not send (an EIP-3009 authorisation, such as an x402 payment, or an allowance)` +
        (intoKernel ? ` INTO ${targets.get(to)?.label}: a kernel routes it as tax, so a team payment funds buys of the team's token` : ''),
      flags: intoKernel ? ['kernel-usdt0'] : [],
      unknownTarget: false,
      undecided: [],
      reverted: false,
    });
  });
  for (const { wallet, use, block, timestamp } of auths) {
    const report = reports.find((r) => r.wallet.address === wallet.address) as WalletReport;
    const knownImpl = known.smartWallets[use.delegate];
    report.rows.push({
      ref: `nonce ${use.nonce}`,
      position: -1,
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
        (use.delegate === ZERO
          ? 'EIP-7702 AUTHORISATION that clears the wallet\'s delegation'
          : knownImpl
            ? `EIP-7702 authorisation: the wallet delegated its code to ${use.delegate}, a known smart-wallet implementation: ${knownImpl}`
            : `EIP-7702 AUTHORISATION: the wallet delegated its code to ${use.delegate}, an UNKNOWN implementation`) + ` (carried by a transaction from ${use.carrierFrom})`,
      flags: [],
      unknownTarget: false,
      undecided: [],
      reverted: false,
    });
  }
  // chronological: block, then the order inside the block (an authorisation is applied before its transaction runs)
  for (const r of reports) r.rows.sort((a, b) => a.block - b.block || a.position - b.position || a.nonce - b.nonce);

  // ── 5. rules
  const rows = reports.flatMap((r) => r.rows);
  const rules: RuleResult[] = RULES.map(({ id, title }) => {
    let hits: Row[] = [];
    let examples: string[] = [];
    let notChecked: string | null = null;
    if (id === 'delegation') {
      // code that is exactly a designator to a known smart-wallet implementation is a smart wallet, not a finding
      const coded = reports.filter((r) => r.code !== '0x' && r.smartWallet === null);
      hits = rows.filter((r) => r.kind === 'authorization' && r.target !== ZERO && !known.smartWallets[r.target as string]);
      examples = [
        ...coded.map((r) => `${r.wallet.address} has code at block ${chain.head}${/^0xef0100[0-9a-f]{40}$/i.test(r.code) ? ` (EIP-7702 delegation to 0x${r.code.slice(8)}, not a known smart-wallet implementation)` : ' (it is a contract)'}`),
        ...hits.map((r) => `${short(r.wallet)} ${r.ref}`),
      ];
      return { id, title, count: coded.length + hits.length, reverted: 0, notChecked, examples };
    }
    if (id === 'unexplained-nonce') {
      const n = reports.reduce((s, r) => s + r.unexplained.length, 0);
      examples = reports.filter((r) => r.unexplained.length).map((r) => `${short(r.wallet.address)} nonce(s) ${r.unexplained.join(', ')}`);
      return { id, title, count: n, reverted: 0, notChecked, examples };
    }
    hits = rows.filter((r) => r.flags.includes(id));
    examples = hits.slice(0, 8).map((r) => `${short(r.wallet)} ${r.ref}`);
    const undecided = rows.filter((r) => r.undecided.includes(id));
    if (undecided.length) {
      notChecked =
        id === 'kernel-value'
          ? `no kernel and no KernelFactory is configured in addresses.json, and ${undecided.length} transaction(s) sent value to contracts that are not in the known list (${undecided.slice(0, 5).map((r) => `${short(r.wallet)} ${r.ref}`).join('; ')})`
          : `covenant.transistors is not configured in addresses.json, and ${undecided.length} transaction(s) look like ERC-1155 transfers (${undecided.slice(0, 5).map((r) => `${short(r.wallet)} ${r.ref}`).join('; ')})`;
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
    usdt0Scan,
    exitCode: flagged ? 1 : incomplete.length ? 2 : 0,
    stats: chain.stats,
  };
}
