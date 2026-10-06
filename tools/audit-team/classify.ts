// Classification of one transaction of a team wallet. Pure: the chain facts it needs are in `Context`.
//
// FLAGS (each one makes the audit fail):
//   ignix-call           a call to IgnixManager other than createToken
//   first-buy            a createToken whose decoded firstBuy is not 0 (or whose calldata does not decode)
//   dex-call             a call to the Uniswap V2 router or to WOKB
//   ignix-token-call     a transaction to a token launched through IgnixManager (approve, transfer, ...)
//   ignix-activity       an IGNIX trade or token movement inside a transaction to some other contract,
//                        seen in the receipt's logs (for example a sale through a DEX aggregator)
//   kernel-value         native value sent to a kernel or to its vault
//   kernel-usdt0         USD₮0 sent from the wallet to a kernel or to its vault (a v2 kernel routes it as tax: a team
//                        payment would fund buys of the team's token), seen in the receipt's Transfer logs, or a
//                        USD₮0 transfer / transferFrom / transferWithAuthorization call naming one (also when reverted)
//   transistor-transfer  an ERC-1155 safeTransferFrom / safeBatchTransferFrom of Covenant transistors
// WARNING (listed, not a flag):
//   unknown target       the target is not in the known list

import { DecodeError, decodeCreateToken } from '../launch-check/decode.ts';
import { createAddress } from '../launch-check/rlp.ts';
import type { Receipt, RpcLog, Tx } from './chain.ts';
import { SEL, TOPIC, selectorName, type Kind } from './known.ts';

export type Flag = 'ignix-call' | 'first-buy' | 'dex-call' | 'ignix-token-call' | 'ignix-activity' | 'kernel-value' | 'kernel-usdt0' | 'transistor-transfer';

export interface Target {
  kind: Kind | 'ignixToken' | 'ignixVault' | 'unknown';
  label: string;
  /** For an unknown target: does it have code at the audit block? */
  isContract?: boolean;
}

export interface Context {
  /** Every address the audit can name, lower case. */
  targets: Map<string, Target>;
  /** Addresses for which IgnixManager.creatorOf() is non-zero: tokens launched through IGNIX. */
  ignixTokens: Set<string>;
  manager: string;
  /** null when addresses.json does not name it yet. */
  transistors: string | null;
  /** True when at least one kernel, or the KernelFactory, is configured. */
  kernelsKnown: boolean;
  /** USD₮0 (lower case), or null when addresses.json does not name it: then the kernel-usdt0 rule is not applied. */
  usdt0?: string | null;
}

/** A kernel (v1 or v2) or a kernel's vault, as far as the audit knows its targets. */
export const isKernelish = (ctx: Context, a: string): boolean => {
  const k = ctx.targets.get(a)?.kind;
  return k === 'kernel' || k === 'kernelVault';
};

/** The recipient (and the payer, when the call names one) of a USD₮0 transfer call, or null for any other call. */
export function usdt0CallParties(input: string): { from: string | null; to: string } | null {
  const sel = input.slice(0, 10).toLowerCase();
  const arg = (i: number): string => '0x' + input.slice(10 + 64 * i + 24, 10 + 64 * i + 64).toLowerCase();
  if (input.length < 10 + 64 * 2) return null;
  if (sel === SEL.transfer) return { from: null, to: arg(0) };
  if (sel === SEL.transferFrom || sel === SEL.transferWithAuthorization || sel === SEL.transferWithAuthorizationBytes) return { from: arg(0), to: arg(1) };
  return null;
}

/** USD₮0 Transfer logs, among `logs`, that move USD₮0 from `wallet` to a kernel or a kernel's vault. */
export function usdt0IntoKernels(logs: readonly RpcLog[], ctx: Context, wallet: string): RpcLog[] {
  if (!ctx.usdt0) return [];
  return logs.filter((l) => l.address === ctx.usdt0 && l.topics[0] === TOPIC.transfer && l.topics.length === 3 && addrOfTopic(l.topics[1]) === wallet && isKernelish(ctx, addrOfTopic(l.topics[2])));
}

/** A USD₮0 amount (6 decimals) from a Transfer log's data. */
export function usdt0Amount(data: string): string {
  const v = BigInt(data.length > 2 ? '0x' + data.slice(2, 66) : '0x0');
  const frac = (v % 1_000_000n).toString().padStart(6, '0').replace(/0+$/, '');
  return `${v / 1_000_000n}${frac ? '.' + frac : ''} USD₮0`;
}

export interface Classified {
  target: string | null;
  targetLabel: string;
  selector: string | null;
  selectorName: string | null;
  classification: string;
  flags: Flag[];
  /** True when the target is not in the known list. */
  unknownTarget: boolean;
  /** Rules that could not be decided for this transaction because an address is not configured. */
  undecided: Flag[];
  reverted: boolean;
}

const addrOfTopic = (t: string | undefined): string => (t ? '0x' + t.slice(26).toLowerCase() : '');
const ZERO = '0x0000000000000000000000000000000000000000';
const short = (a: string): string => a.slice(0, 6) + '...' + a.slice(-4);

function okb(wei: bigint): string {
  const whole = wei / 10n ** 18n;
  const frac = (wei % 10n ** 18n).toString().padStart(18, '0').replace(/0+$/, '');
  return whole.toString() + (frac ? '.' + frac : '') + ' OKB';
}

/** Is this log an ERC-1155 transfer that moves tokens to or from `wallet` (not a mint, not a burn)? */
function is1155Move(l: RpcLog, wallet: string): boolean {
  if (l.topics[0] !== TOPIC.transferSingle && l.topics[0] !== TOPIC.transferBatch) return false;
  const from = addrOfTopic(l.topics[2]);
  const to = addrOfTopic(l.topics[3]);
  return from !== ZERO && to !== ZERO && (from === wallet || to === wallet);
}

export function classify(tx: Tx, receipt: Receipt, ctx: Context): Classified {
  const wallet = tx.from;
  const flags: Flag[] = [];
  const undecided: Flag[] = [];
  const reverted = receipt.status !== '0x1';
  const value = BigInt(tx.value);
  const selector = tx.input.length >= 10 ? tx.input.slice(0, 10).toLowerCase() : null;
  const fn = selector ? selectorName(selector) : null;
  const call = selector ? (fn ? `${fn}()` : `function ${selector}`) : value > 0n ? 'plain transfer' : 'empty call';
  let unknownTarget = false;
  let text: string;
  let label: string;

  if (tx.to === null) {
    const created = receipt.contractAddress?.toLowerCase() ?? createAddress(wallet, tx.nonce);
    const t = ctx.targets.get(created);
    const named = t !== undefined && t.kind !== 'unknown';
    label = named ? t.label : 'new contract';
    text = `contract creation: deployed ${created}${named ? ` (${t.label})` : ''}`;
    return finish(created, label, null, null, text);
  }

  const target = ctx.targets.get(tx.to) ?? { kind: 'unknown' as const, label: 'unknown target', isContract: undefined };
  label = target.label;

  switch (target.kind) {
    case 'manager': {
      if (selector === SEL.createToken) {
        try {
          const c = decodeCreateToken(tx.input);
          if (c.p.firstBuy !== 0n) {
            flags.push('first-buy');
            text = `createToken "${c.p.symbol}" WITH A FIRST BUY of ${okb(c.p.firstBuy)}`;
          } else {
            text = `createToken "${c.p.symbol}", first buy 0`;
          }
        } catch (e) {
          flags.push('first-buy');
          text = `createToken whose calldata could not be decoded (${e instanceof DecodeError ? e.message : String(e)}): the first buy is unknown`;
        }
      } else {
        flags.push('ignix-call');
        text = `IgnixManager call other than createToken: ${call}`;
      }
      break;
    }
    case 'router':
    case 'wokb':
      flags.push('dex-call');
      text = `${target.kind === 'router' ? 'Uniswap V2 router' : 'WOKB'} call: ${call}`;
      break;
    case 'ignixToken':
    case 'kernelToken':
      flags.push('ignix-token-call');
      text = `call to an IGNIX-launched token: ${call}`;
      break;
    case 'kernel':
    case 'kernelVault':
      if (value > 0n) {
        flags.push('kernel-value');
        text = `${okb(value)} SENT to ${target.kind === 'kernel' ? 'a kernel' : "a kernel's vault"}: ${call}`;
      } else {
        text = `${target.kind === 'kernel' ? 'kernel' : "kernel's vault"}: ${call}`;
      }
      break;
    case 'transistors':
      if (selector === SEL.erc1155Transfer || selector === SEL.erc1155BatchTransfer) {
        flags.push('transistor-transfer');
        text = `TRANSISTOR TRANSFER: ${call}`;
      } else {
        text = `Covenant Transistors: ${call}`;
      }
      break;
    case 'wallet':
      text = `to a declared team wallet: ${call}`;
      break;
    case 'unknown':
      unknownTarget = true;
      text = `unknown target (${target.label !== 'unknown target' ? target.label : target.isContract === false ? 'an address without code' : 'a contract that is not in the known list'}): ${call}`;
      if (target.isContract !== false) {
        if (!ctx.kernelsKnown && value > 0n) undecided.push('kernel-value');
        if (ctx.transistors === null && (selector === SEL.erc1155Transfer || selector === SEL.erc1155BatchTransfer)) undecided.push('transistor-transfer');
      }
      break;
    case 'ignixVault':
      unknownTarget = true;
      text = `unknown target (${target.label}): ${call}`;
      break;
    default:
      text = `${target.label}: ${call}`;
  }

  // ── what the receipt's logs show, for transactions no rule above has flagged
  if (!flags.length && !reverted) {
    const trades = receipt.logs.filter((l) => l.address === ctx.manager && l.topics[0] === TOPIC.trade);
    const tokenLogs = receipt.logs.filter((l) => ctx.ignixTokens.has(l.address) && (l.topics[0] === TOPIC.transfer || l.topics[0] === TOPIC.approval));
    const ownTrade = trades.find((l) => addrOfTopic(l.topics[2]) === wallet);
    const ownMove = tokenLogs.find((l) => addrOfTopic(l.topics[1]) === wallet || (l.topics[0] === TOPIC.transfer && addrOfTopic(l.topics[2]) === wallet));
    const expectedHere = target.kind === 'kernel' || target.kind === 'keeperTank' || (target.kind === 'manager' && selector === SEL.createToken);
    if (ownTrade) {
      flags.push('ignix-activity');
      const isBuy = BigInt('0x' + ownTrade.data.slice(2, 66)) !== 0n;
      text += `; THE WALLET ${isBuy ? 'BOUGHT' : 'SOLD'} IGNIX token ${short(addrOfTopic(ownTrade.topics[1]))} on the curve inside this transaction`;
    } else if (ownMove) {
      flags.push('ignix-activity');
      text += `; IGNIX token ${short(ownMove.address)} MOVED TO OR FROM THE WALLET (or was approved by it) inside this transaction`;
    } else if (!expectedHere && (trades.length || tokenLogs.length)) {
      flags.push('ignix-activity');
      text += `; AN IGNIX TRADE OR TOKEN TRANSFER happened inside this transaction (${trades.length} Trade event(s), ${tokenLogs.length} token event(s))`;
    }
  }

  // ── USD₮0 into a kernel or a kernel's vault: what the receipt's logs show, and, also for a reverted call, what a
  //    USD₮0 transfer call names
  if (ctx.usdt0) {
    const moved = reverted ? [] : usdt0IntoKernels(receipt.logs, ctx, wallet);
    const parties = tx.to === ctx.usdt0 ? usdt0CallParties(tx.input) : null;
    const named = parties !== null && isKernelish(ctx, parties.to);
    if (moved.length) {
      flags.push('kernel-usdt0');
      const where = moved.map((l) => `${usdt0Amount(l.data)} to ${ctx.targets.get(addrOfTopic(l.topics[2]))?.label ?? addrOfTopic(l.topics[2])}`).join(', ');
      text += `; USD₮0 SENT FROM THE WALLET TO A KERNEL (${where}): a kernel routes it as tax, so a team payment funds buys of the team's token`;
    } else if (named) {
      flags.push('kernel-usdt0');
      const p = parties as { from: string | null; to: string };
      text += `; THE WALLET CALLED A USD₮0 TRANSFER INTO A KERNEL (payer ${p.from === null || p.from === wallet ? 'the wallet' : p.from}, recipient ${ctx.targets.get(p.to)?.label ?? p.to})`;
    }
  }

  // ── transistor transfers seen in logs (a marketplace or operator moving them for the wallet)
  if (!flags.includes('transistor-transfer') && !reverted) {
    if (ctx.transistors !== null) {
      if (receipt.logs.some((l) => l.address === ctx.transistors && is1155Move(l, wallet))) {
        flags.push('transistor-transfer');
        text += '; COVENANT TRANSISTORS MOVED to or from the wallet inside this transaction';
      }
    } else if (receipt.logs.some((l) => is1155Move(l, wallet)) && !undecided.includes('transistor-transfer')) {
      undecided.push('transistor-transfer');
    }
  }

  return finish(tx.to, label, selector, fn, text);

  function finish(to: string | null, targetLabel: string, sel: string | null, name: string | null, classification: string): Classified {
    return {
      target: to,
      targetLabel,
      selector: sel,
      selectorName: name,
      classification: classification + (reverted ? ' [REVERTED: it had no effect]' : ''),
      flags,
      unknownTarget,
      undecided,
      reverted,
    };
  }
}
