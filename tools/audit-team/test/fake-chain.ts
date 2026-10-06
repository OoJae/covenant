// A chain made of tables, for offline tests of the audit: blocks, transactions, receipts, code and a few
// contract views, served through the same `Rpc` interface the real client has.

import { RpcError, type Rpc, type RpcRequest } from '../../../packages/chain/src/index.ts';
import { keccak256 } from '../../../packages/chain/src/keccak.ts';
import { addressWord, bytesToHex, strip0x, word } from '../../launch-check/hex.ts';
import type { RpcAuthorization } from '../../launch-check/rlp.ts';
import type { RpcLog } from '../chain.ts';
import { selectorOf, type Known } from '../known.ts';

export const MANAGER = '0x96b51c57e5346d0c0198899243cf851d1e23c309';
export const ROUTER = '0x182a927119d56008d921126764bf884221b10f59';
export const WOKB = '0xe538905cf8410324e03a5a23c1c177a474d59b2b';
export const TAPEOUT = '0x1f09daefa827f02cbb40967cc91b259763760761';
export const ZERO = '0x0000000000000000000000000000000000000000';

export const known = (over: Partial<Known> = {}): Known => ({
  chainId: 196,
  manager: MANAGER,
  tapeoutFactory: TAPEOUT,
  router: ROUTER,
  wokb: WOKB,
  usdt0: null,
  deployer: null,
  keeper: null,
  agentWallet: null,
  splitter: null,
  keeperTank: null,
  teamRegistry: null,
  transistors: null,
  circuits: null,
  sealedVM: null,
  fab: null,
  kernelFactory: null,
  lens: null,
  kernelFactoryV2: null,
  lensV2: null,
  kernels: [],
  other: {},
  smartWallets: {},
  entryPoints: [],
  ...over,
});

export interface FakeTx {
  from: string;
  to: string | null;
  value?: bigint;
  input?: string;
  logs?: RpcLog[];
  reverted?: boolean;
  authorizationList?: RpcAuthorization[];
}

interface Stored {
  hash: string;
  from: string;
  to: string | null;
  nonce: number;
  value: string;
  input: string;
  type: string;
  blockNumber: number;
  transactionIndex: number;
  authorizationList?: RpcAuthorization[];
  logs: RpcLog[];
  reverted: boolean;
}

export const topicAddress = (a: string): string => '0x' + addressWord(a);

export class FakeChain {
  head: number;
  chainId = 196;
  private readonly blocks = new Map<number, Stored[]>();
  private readonly byHash = new Map<string, Stored>();
  /** Nonces used at each (address, block), from transactions and from authorisations. */
  private readonly uses: { address: string; block: number }[] = [];
  private readonly nonces = new Map<string, number>();
  readonly code = new Map<string, string>();
  /** address -> the first block at which it has its code (default: every block). */
  readonly codeFrom = new Map<string, number>();
  /** address -> creator, for IgnixManager.creatorOf / vaultOf */
  readonly ignixTokens = new Map<string, { creator: string; vault: string }>();
  /** `${to}:${selector}` -> return data, or a function of the calldata; null reverts */
  readonly views = new Map<string, string | null | ((data: string) => string | null)>();
  readonly seen: string[] = [];
  /** Methods that fail a number of times before answering. */
  readonly flaky = new Map<string, number>();
  /** Counts the node reports wrongly: `${address}:${block}` -> count. */
  readonly lies = new Map<string, number>();

  constructor(head: number) {
    this.head = head;
  }

  /** Adds a transaction to a block. Its nonce is the sender's next one. Blocks must be added in ascending order per sender. */
  add(block: number, tx: FakeTx): string {
    const from = tx.from.toLowerCase();
    const nonce = this.nonces.get(from) ?? 0;
    this.nonces.set(from, nonce + 1);
    const list = this.blocks.get(block) ?? [];
    const hash = bytesToHex(keccak256(new TextEncoder().encode(`${from}:${nonce}:${block}`)));
    const stored: Stored = {
      hash,
      from,
      to: tx.to ? tx.to.toLowerCase() : null,
      nonce,
      value: '0x' + (tx.value ?? 0n).toString(16),
      input: tx.input ?? '0x',
      type: tx.authorizationList ? '0x4' : '0x2',
      blockNumber: block,
      transactionIndex: list.length,
      authorizationList: tx.authorizationList,
      logs: tx.logs ?? [],
      reverted: tx.reverted ?? false,
    };
    list.push(stored);
    this.blocks.set(block, list);
    this.byHash.set(hash, stored);
    this.uses.push({ address: from, block });
    if (stored.to) this.code.set(stored.to, this.code.get(stored.to) ?? '0x');
    return hash;
  }

  /** Records that `address` used its next nonce in `block` without sending a transaction. Returns that nonce. */
  useNonce(address: string, block: number): number {
    const a = address.toLowerCase();
    const nonce = this.nonces.get(a) ?? 0;
    this.nonces.set(a, nonce + 1);
    this.uses.push({ address: a, block });
    return nonce;
  }

  nextNonce(address: string): number {
    return this.nonces.get(address.toLowerCase()) ?? 0;
  }

  count(address: string, block: number): number {
    const lie = this.lies.get(`${address.toLowerCase()}:${block}`);
    if (lie !== undefined) return lie;
    return this.uses.filter((u) => u.address === address.toLowerCase() && u.block <= block).length;
  }

  private answer(method: string, params: readonly unknown[]): unknown {
    this.seen.push(method);
    const left = this.flaky.get(method) ?? 0;
    if (left > 0) {
      this.flaky.set(method, left - 1);
      return new RpcError({ code: -32005, message: 'over rate limit' });
    }
    const blockOf = (tag: unknown): number => (tag === 'latest' ? this.head : Number(BigInt(tag as string)));
    switch (method) {
      case 'eth_chainId':
        return '0x' + this.chainId.toString(16);
      case 'eth_getBlockByNumber': {
        const n = blockOf(params[0]);
        if (n > this.head) return null;
        const txs = this.blocks.get(n) ?? [];
        return {
          number: '0x' + n.toString(16),
          timestamp: '0x' + (1_700_000_000 + n).toString(16),
          hash: '0x' + word(n),
          transactions: params[1]
            ? txs.map((t) => ({ hash: t.hash, from: t.from, to: t.to, nonce: '0x' + t.nonce.toString(16), value: t.value, input: t.input, type: t.type, transactionIndex: '0x' + t.transactionIndex.toString(16), authorizationList: t.authorizationList }))
            : txs.map((t) => t.hash),
        };
      }
      case 'eth_getTransactionCount':
        return '0x' + this.count(params[0] as string, blockOf(params[1])).toString(16);
      case 'eth_getTransactionReceipt': {
        const t = this.byHash.get(params[0] as string);
        if (!t) return null;
        return { status: t.reverted ? '0x0' : '0x1', gasUsed: '0x5208', contractAddress: null, blockNumber: '0x' + t.blockNumber.toString(16), logs: t.reverted ? [] : t.logs };
      }
      case 'eth_getCode': {
        const a = (params[0] as string).toLowerCase();
        if (blockOf(params[1] ?? 'latest') < (this.codeFrom.get(a) ?? 0)) return '0x';
        return this.code.get(a) ?? '0x';
      }
      case 'eth_getTransactionByHash': {
        const t = this.byHash.get(params[0] as string);
        return t ? { hash: t.hash, from: t.from, to: t.to, nonce: '0x' + t.nonce.toString(16), blockNumber: '0x' + t.blockNumber.toString(16), input: t.input, value: t.value, type: t.type } : null;
      }
      case 'eth_getLogs': {
        // like the public X Layer endpoint: at most 100 blocks per query
        const f = params[0] as { address?: string; topics?: (string | string[] | null)[]; fromBlock: string; toBlock: string };
        const from = blockOf(f.fromBlock);
        const to = Math.min(blockOf(f.toBlock), this.head);
        if (to - from + 1 > 100) return new RpcError({ code: -32602, message: 'block range greater than 100 max' });
        const out: unknown[] = [];
        for (let b = from; b <= to; b++) {
          let logIndex = 0;
          for (const t of this.blocks.get(b) ?? []) {
            if (t.reverted) continue;
            for (const l of t.logs) {
              const i = logIndex++;
              if (f.address && l.address.toLowerCase() !== f.address.toLowerCase()) continue;
              const fits = (want: string | string[] | null | undefined, got: string | undefined): boolean =>
                want === null || want === undefined || (Array.isArray(want) ? want.some((w) => w.toLowerCase() === got?.toLowerCase()) : want.toLowerCase() === got?.toLowerCase());
              if (!(f.topics ?? []).every((want, k) => fits(want, l.topics[k]))) continue;
              out.push({ address: l.address, topics: l.topics, data: l.data, blockNumber: '0x' + b.toString(16), transactionHash: t.hash, logIndex: '0x' + i.toString(16), removed: false });
            }
          }
        }
        return out;
      }
      case 'eth_call': {
        const { to, data } = params[0] as { to: string; data: string };
        const target = to.toLowerCase();
        const sel = data.slice(0, 10);
        const arg = '0x' + strip0x(data).slice(8 + 24, 8 + 64);
        if (target === MANAGER && sel === selectorOf('creatorOf(address)')) return '0x' + addressWord(this.ignixTokens.get(arg)?.creator ?? ZERO);
        if (target === MANAGER && sel === selectorOf('vaultOf(address)')) return '0x' + addressWord(this.ignixTokens.get(arg)?.vault ?? ZERO);
        const key = `${target}:${sel}`;
        if (!this.views.has(key)) return (this.code.get(target) ?? '0x') === '0x' ? '0x' : new RpcError({ code: 3, message: 'execution reverted', data: '0x' });
        const v = this.views.get(key);
        const ret = typeof v === 'function' ? v(data) : v;
        return ret === null || ret === undefined ? new RpcError({ code: 3, message: 'execution reverted', data: '0x' }) : ret;
      }
      default:
        return new RpcError({ code: -32601, message: `method ${method} is not available` });
    }
  }

  view(to: string, signature: string, ret: string | null | ((data: string) => string | null)): void {
    this.views.set(`${to.toLowerCase()}:${selectorOf(signature)}`, ret);
    if ((this.code.get(to.toLowerCase()) ?? '0x') === '0x') this.code.set(to.toLowerCase(), '0x60');
  }

  rpc(): Rpc {
    const batch = async (reqs: readonly RpcRequest[]): Promise<unknown[]> => {
      if (reqs.length > 10) throw new Error('a batch of more than 10 calls was sent');
      return reqs.map(([m, p]) => this.answer(m, p));
    };
    return {
      urls: ['fake://chain'],
      current: () => 'fake://chain',
      batch,
      send: async (m, p = []) => {
        const [r] = await batch([[m, p]]);
        if (r instanceof Error) throw r;
        return r;
      },
      call: async (to, data) => {
        const [r] = await batch([['eth_call', [{ to, data }, 'latest']]]);
        if (r instanceof Error) throw r;
        return r as string;
      },
    };
  }
}
