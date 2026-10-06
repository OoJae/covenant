// What a smart-wallet team wallet did through ERC-4337: its user operations, found by their UserOperationEvent
// logs on the EntryPoints of addresses.json, each one audited from the logs of its own execution.
//
// A bundle (one handleOps transaction) validates every operation first, emits BeforeExecution(), then executes
// the operations in order; each execution ends with the EntryPoint's UserOperationEvent. So the logs of one
// operation's execution are the logs strictly between the previous BeforeExecution / UserOperationEvent of the
// same EntryPoint and its own UserOperationEvent. Logs before BeforeExecution (the validation phase) cannot be
// attributed to one operation; only the rules that name the wallet itself are applied to them.
//
// Only events are visible: debug_traceTransaction is not available on the public RPC, so a call or a value
// transfer inside an operation that emits nothing is not seen (NOTES.md, "What it cannot see").

import type { Chain, Receipt, RpcLog, ScanLog } from './chain.ts';
import { usdt0Amount, usdt0IntoKernels, type Classified, type Context, type Flag } from './classify.ts';
import { TOPIC, topicOf } from './known.ts';

export const UO_TOPIC = {
  userOperationEvent: topicOf('UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)'),
  beforeExecution: topicOf('BeforeExecution()'),
  revertReason: topicOf('UserOperationRevertReason(bytes32,address,uint256,bytes)'),
  tokenCreated: topicOf('TokenCreated(address,address,address,uint256,string,address,address,uint16)'),
  swapV2: topicOf('Swap(address,uint256,uint256,uint256,uint256,address)'),
} as const;

export interface UserOp {
  entryPoint: string;
  entryPointLabel: string;
  /** The UserOperationEvent, where it was found. */
  log: ScanLog;
  userOpHash: string;
  sender: string;
  paymaster: string;
  /** The 4337 nonce: key << 64 | sequence. */
  nonce: bigint;
  success: boolean;
  actualGasCost: bigint;
}

const topicAddr = (t: string | undefined): string => (t ? '0x' + t.slice(26).toLowerCase() : '');
const word = (data: string, i: number): bigint => BigInt('0x' + (data.replace(/^0x/, '').slice(64 * i, 64 * i + 64) || '0'));

export function decodeUserOpEvent(l: ScanLog, entryPointLabel: string): UserOp {
  if (l.topics[0] !== UO_TOPIC.userOperationEvent || l.topics.length !== 4) throw new Error(`log ${l.transactionHash}#${l.logIndex} is not a UserOperationEvent`);
  if (l.data.replace(/^0x/, '').length !== 4 * 64) throw new Error(`UserOperationEvent ${l.transactionHash}#${l.logIndex}: unexpected data length`);
  return {
    entryPoint: l.address,
    entryPointLabel,
    log: l,
    userOpHash: l.topics[1],
    sender: topicAddr(l.topics[2]),
    paymaster: topicAddr(l.topics[3]),
    nonce: word(l.data, 0),
    success: word(l.data, 1) !== 0n,
    actualGasCost: word(l.data, 2),
  };
}

/** The user operations of `wallet` on each EntryPoint, from block `from` to the audit block. */
export async function findUserOps(
  chain: Chain,
  wallet: string,
  entryPoints: readonly { address: string; label: string }[],
  from: number,
  log: (m: string) => void = () => {},
): Promise<UserOp[]> {
  const out: UserOp[] = [];
  const senderTopic = '0x' + wallet.replace(/^0x/, '').toLowerCase().padStart(64, '0');
  for (const ep of entryPoints) {
    const logs = await chain.scanLogs(ep.address, [UO_TOPIC.userOperationEvent, null, senderTopic], from, (done, total) => {
      if (total > 50) log(`${wallet}: ${ep.label}: ${done} of ${total} eth_getLogs chunks`);
    });
    for (const l of logs) {
      const op = decodeUserOpEvent(l, ep.label);
      if (op.sender !== wallet.toLowerCase()) throw new Error(`eth_getLogs returned a UserOperationEvent of ${op.sender} for sender ${wallet}`);
      out.push(op);
    }
  }
  out.sort((a, b) => a.log.blockNumber - b.log.blockNumber || a.log.logIndex - b.log.logIndex);
  return out;
}

export interface Segment {
  /** The logs of this operation's execution (between its delimiters). */
  execution: RpcLog[];
  /** The logs of the bundle's validation phase (before BeforeExecution). */
  validation: RpcLog[];
  /** False when no delimiter was found before the operation's event: then `execution` is every earlier log. */
  delimited: boolean;
}

/** The part of the bundle's receipt that belongs to one user operation. */
export function segmentOf(receipt: Receipt, op: UserOp): Segment {
  const logs = receipt.logs;
  const at = logs.findIndex((l) => l.address === op.entryPoint && l.topics[0] === UO_TOPIC.userOperationEvent && l.topics[1] === op.userOpHash);
  if (at < 0) throw new Error(`the receipt of ${op.log.transactionHash} does not hold UserOperationEvent ${op.userOpHash}`);
  const isDelimiter = (l: RpcLog): boolean => l.address === op.entryPoint && (l.topics[0] === UO_TOPIC.userOperationEvent || l.topics[0] === UO_TOPIC.beforeExecution);
  let start = -1;
  for (let i = at - 1; i >= 0; i--) {
    if (isDelimiter(logs[i])) {
      start = i;
      break;
    }
  }
  // the validation phase of this bundle: everything before the BeforeExecution that precedes this operation
  let before = -1;
  for (let i = at - 1; i >= 0; i--) {
    if (logs[i].address === op.entryPoint && logs[i].topics[0] === UO_TOPIC.beforeExecution) {
      before = i;
      break;
    }
  }
  return { execution: logs.slice(start + 1, at), validation: before >= 0 ? logs.slice(0, before) : [], delimited: start >= 0 };
}

const short = (a: string): string => a.slice(0, 6) + '...' + a.slice(-4);

/**
 * The rules of the audit applied to one user operation, from its logs:
 *   ignix-activity       an IGNIX Trade by the wallet, an IGNIX token Transfer / Approval to or from the wallet, or
 *                        any other IGNIX trade or token movement in the operation's execution (a kernel's own buy,
 *                        trader = a kernel, is expected and not flagged)
 *   ignix-call           any other IgnixManager event in the execution (TokenCreated by the wallet without a trade
 *                        is a launch with first buy 0, allowed as for transactions)
 *   first-buy            TokenCreated together with a Trade in the same execution
 *   dex-call             any WOKB event, or a Uniswap V2 Swap, in the execution
 *   transistor-transfer  a transfer of Covenant transistors to or from the wallet (validation phase included)
 *   kernel-usdt0         USD₮0 moved from the wallet to a kernel or a kernel's vault (validation phase included)
 * Events of kernels and of their vaults are named in the text; value sent to them is not visible (no event).
 */
export function classifyUserOp(op: UserOp, receipt: Receipt, ctx: Context, wallet: string, bundler: string | null): Classified {
  const flags: Flag[] = [];
  const undecided: Flag[] = [];
  const seg = segmentOf(receipt, op);
  const kernels = new Set([...ctx.targets].filter(([, t]) => t.kind === 'kernel').map(([a]) => a));
  const kindOf = (a: string): string | undefined => ctx.targets.get(a)?.kind;
  const notes: string[] = [];
  const add = (f: Flag, note: string): void => {
    if (!flags.includes(f)) flags.push(f);
    notes.push(note);
  };

  const ownIgnix = (l: RpcLog): boolean =>
    (l.address === ctx.manager && l.topics[0] === TOPIC.trade && topicAddr(l.topics[2]) === wallet) ||
    (ctx.ignixTokens.has(l.address) && (l.topics[0] === TOPIC.transfer || l.topics[0] === TOPIC.approval) && (topicAddr(l.topics[1]) === wallet || (l.topics[0] === TOPIC.transfer && topicAddr(l.topics[2]) === wallet)));
  const ownTransistors = (l: RpcLog): boolean => {
    if (ctx.transistors === null || l.address !== ctx.transistors) return false;
    if (l.topics[0] !== TOPIC.transferSingle && l.topics[0] !== TOPIC.transferBatch) return false;
    const from = topicAddr(l.topics[2]);
    const to = topicAddr(l.topics[3]);
    const zero = '0x0000000000000000000000000000000000000000';
    return from !== zero && to !== zero && (from === wallet || to === wallet);
  };

  // every log that is in the receipt happened (a failed execution leaves none of its own)
  {
    // rules that name the wallet: the execution and the validation phase
    for (const l of [...seg.validation, ...seg.execution]) {
      if (ownIgnix(l)) add('ignix-activity', `THE WALLET ${l.topics[0] === TOPIC.trade ? 'TRADED' : 'MOVED OR APPROVED'} IGNIX token ${short(l.address === ctx.manager ? topicAddr(l.topics[1]) : l.address)}`);
      if (ownTransistors(l)) add('transistor-transfer', 'COVENANT TRANSISTORS MOVED to or from the wallet');
      for (const m of usdt0IntoKernels([l], ctx, wallet)) {
        add('kernel-usdt0', `USD₮0 SENT FROM THE WALLET TO A KERNEL (${usdt0Amount(m.data)} to ${ctx.targets.get(topicAddr(m.topics[2]))?.label ?? topicAddr(m.topics[2])})`);
      }
      if (ctx.transistors === null && (l.topics[0] === TOPIC.transferSingle || l.topics[0] === TOPIC.transferBatch) && [topicAddr(l.topics[2]), topicAddr(l.topics[3])].includes(wallet) && !undecided.includes('transistor-transfer')) {
        undecided.push('transistor-transfer');
      }
    }
    // rules on everything the operation's execution caused
    const trades = seg.execution.filter((l) => l.address === ctx.manager && l.topics[0] === TOPIC.trade);
    const created = seg.execution.filter((l) => l.address === ctx.manager && l.topics[0] === UO_TOPIC.tokenCreated);
    for (const l of trades) {
      if (!kernels.has(topicAddr(l.topics[2])) && topicAddr(l.topics[2]) !== wallet) add('ignix-activity', `AN IGNIX TRADE by ${short(topicAddr(l.topics[2]))} happened inside this user operation`);
    }
    for (const l of seg.execution) {
      if (ctx.ignixTokens.has(l.address) && (l.topics[0] === TOPIC.transfer || l.topics[0] === TOPIC.approval) && !ownIgnix(l)) {
        const parties = [topicAddr(l.topics[1]), topicAddr(l.topics[2])];
        if (!parties.some((p) => kernels.has(p))) add('ignix-activity', `IGNIX token ${short(l.address)} MOVED inside this user operation`);
      }
    }
    if (created.length) {
      if (trades.some((l) => !kernels.has(topicAddr(l.topics[2])))) add('first-buy', 'createToken WITH A TRADE in the same operation (a first buy)');
      else notes.push(`createToken (TokenCreated, no trade: first buy 0)`);
    }
    const otherManager = seg.execution.filter((l) => l.address === ctx.manager && l.topics[0] !== TOPIC.trade && l.topics[0] !== UO_TOPIC.tokenCreated);
    if (otherManager.length) add('ignix-call', `the IgnixManager emitted ${otherManager.length} other event(s) inside this user operation`);
    if (trades.some((l) => kernels.has(topicAddr(l.topics[2])))) notes.push('a kernel bought on the curve (expected in a settle)');
    if (seg.execution.some((l) => kindOf(l.address) === 'wokb' || l.topics[0] === UO_TOPIC.swapV2)) add('dex-call', 'WOKB or a Uniswap V2 pair emitted an event inside this user operation');
    const touched = [...new Set(seg.execution.filter((l) => kindOf(l.address) === 'kernel' || kindOf(l.address) === 'kernelVault').map((l) => ctx.targets.get(l.address)?.label ?? l.address))];
    if (touched.length) notes.push(`events of ${touched.join(', ')}`);
  }

  const emitters = new Map<string, number>();
  for (const l of seg.execution) emitters.set(l.address, (emitters.get(l.address) ?? 0) + 1);
  const describe = [...emitters].map(([a, n]) => `${n} from ${ctx.targets.get(a)?.label ?? short(a)}`).join(', ');
  const text =
    `USER OPERATION ${op.userOpHash.slice(0, 10)}... through ${op.entryPointLabel}, bundled by ${bundler ? short(bundler) : 'an unknown sender'}` +
    (op.paymaster !== '0x0000000000000000000000000000000000000000' ? `, paymaster ${short(op.paymaster)}` : '') +
    `: ${op.success ? 'succeeded' : 'FAILED (its execution had no effect)'}; ` +
    (seg.delimited ? `${seg.execution.length} event(s) in its execution${describe ? ` (${describe})` : ''}` : `its logs could not be delimited: ${seg.execution.length} earlier event(s) of the bundle were checked as its own`) +
    (notes.length ? '; ' + notes.join('; ') : '');
  return {
    target: op.entryPoint,
    targetLabel: `${op.entryPointLabel} (user operation)`,
    selector: null,
    selectorName: null,
    classification: text,
    flags,
    unknownTarget: false,
    undecided,
    reverted: !op.success,
  };
}

