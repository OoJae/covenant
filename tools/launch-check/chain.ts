// Reads the chain facts launch-check needs, all at ONE block, with read-only JSON-RPC calls
// (eth_chainId, eth_getBlockByNumber, eth_call, eth_getCode, eth_getBalance). Nothing is ever sent.

import { RpcError, createRpc, revertReason, type Rpc, type RpcOptions } from '../../packages/chain/src/index.ts';
import { TAPEOUT_FACTORY, got, missing, type ChainFacts, type Fact, type TxInput } from './checks.ts';
import { MANAGER, selectorOf, type CreateTokenCall } from './decode.ts';
import { addressWord, strip0x, word } from './hex.ts';
import { kernelFactory as factoryCalls, kernel as kernelCalls, type Call } from './kernel-abi.ts';

export const DEFAULT_RPCS = ['https://rpc.xlayer.tech', 'https://xlayerrpc.okx.com'] as const;

/**
 * The repository's JSON-RPC client, with every request labelled `application/json`.
 * packages/chain sends requests without a content type (a browser optimisation); the X Layer endpoints
 * accept that, but other nodes (anvil, for one) answer "Invalid request". A command-line tool has no reason
 * to be clever here, and --rpc may point anywhere.
 */
export function connect(urls: readonly string[], opts: RpcOptions = {}): Rpc {
  const base = opts.fetch ?? fetch;
  const jsonFetch: typeof fetch = (input, init) => base(input, { ...init, headers: { ...(init?.headers as Record<string, string> | undefined), 'content-type': 'application/json' } });
  return createRpc(urls, { ...opts, fetch: jsonFetch });
}

const describe = (e: unknown): string => {
  if (e instanceof RpcError) {
    if (e.data !== undefined) {
      const why = revertReason(e.data);
      return why === 'reverted' ? 'the call reverted without a reason (no such function, or a check failed)' : `the call reverted (${why})`;
    }
    return `RPC error ${e.code}: ${e.message}`;
  }
  return e instanceof Error ? e.message : String(e);
};

/** One 32-byte return word, strictly: any other length is an error. */
function oneWord(ret: unknown, what: string): bigint {
  if (typeof ret !== 'string') throw new Error(`${what}: the node returned no data`);
  const h = strip0x(ret);
  if (h.length !== 64) {
    throw new Error(`${what} returned ${h.length / 2} bytes; 32 expected${h.length === 0 ? ' (no contract at that address, or no such function)' : ''}`);
  }
  return BigInt('0x' + h);
}
const asAddress = (ret: unknown, what: string): string => {
  const w = oneWord(ret, what);
  if (w >> 160n !== 0n) throw new Error(`${what} did not return an address`);
  return '0x' + w.toString(16).padStart(40, '0');
};

type Req = readonly [string, readonly unknown[]];

/** Turns one entry of a batch reply into a fact. */
function fact<T>(reply: unknown, what: string, decode: (r: unknown) => T): Fact<T> {
  if (reply instanceof Error) return missing(`${what}: ${describe(reply)}`);
  if (reply === undefined) return missing(`${what}: no reply from the node`);
  try {
    return got(decode(reply));
  } catch (e) {
    return missing((e as Error).message);
  }
}

const codeSize = (r: unknown): number => {
  if (typeof r !== 'string') throw new Error('eth_getCode returned no data');
  return strip0x(r).length / 2;
};

/** `rpc.batch` that never throws: a transport failure becomes an error in every slot. */
async function batch(rpc: Rpc, reqs: readonly Req[]): Promise<unknown[]> {
  try {
    return await rpc.batch(reqs);
  } catch (e) {
    const err = e instanceof Error ? e : new Error(String(e));
    return reqs.map(() => err);
  }
}

/** Facts in which nothing after the block could be read, each carrying the same reason. */
function unread(rpcUrl: string, chainId: Fact<bigint>, block: ChainFacts['block'], localTime: bigint, circuits: Fact<string>, why: string): ChainFacts {
  return {
    rpcUrl,
    chainId,
    block,
    localTime,
    signer: missing(why),
    poolFee: missing(why),
    launchFactory: missing(why),
    registeredFactory: missing(why),
    launchPausedUntil: missing(why),
    launcherBalance: missing(why),
    kernelCodeSize: missing(why),
    kernelToken: missing(why),
    kernelChipId: missing(why),
    kernelEnvelope: missing(why),
    kernelGlobals: missing(why),
    circuits,
    circuitsCodeSize: missing(why),
    circuitsIsProcessor: missing(why),
    circuitsTransistors: missing(why),
    chipOwner: missing(why),
    kernelIsKernel: missing(why),
  };
}

export async function readChain(
  rpc: Rpc,
  tx: TxInput,
  call: CreateTokenCall | null,
  circuits: Fact<string>,
  localTime: bigint = BigInt(Math.floor(Date.now() / 1000)),
  /** The deployment's KernelFactory, or null when none was given. */
  kernelFactory: string | null = null,
): Promise<ChainFacts> {
  // 1. which chain, which block
  const [rChain, rBlock] = await batch(rpc, [
    ['eth_chainId', []],
    ['eth_getBlockByNumber', ['latest', false]],
  ]);
  const chainId = fact(rChain, 'eth_chainId', (r) => BigInt(r as string));
  const block = fact(rBlock, 'eth_getBlockByNumber(latest)', (r) => {
    const b = r as { number?: string; timestamp?: string; hash?: string } | null;
    if (!b || !b.number || !b.timestamp || !b.hash) throw new Error('eth_getBlockByNumber(latest) returned no block');
    return { number: BigInt(b.number), timestamp: BigInt(b.timestamp), hash: b.hash };
  });
  if (!block.ok) return unread(rpc.current(), chainId, block, localTime, circuits, `the latest block could not be read (${block.error})`);

  const facts = unread(rpc.current(), chainId, block, localTime, circuits, 'not read');
  const at = '0x' + block.value.number.toString(16);
  const ethCall = (to: string, data: string): Req => ['eth_call', [{ to, data }, at]];
  const viaCall = <T>(c: Call<T>): Req => ethCall(c.to, c.data);
  const k = kernelCalls(tx.kernel);

  // 2. everything that needs no earlier answer
  const reqs: Req[] = [
    ethCall(MANAGER, selectorOf('signer()')), // 0
    ethCall(MANAGER, selectorOf('POOL_FEE()')), // 1
    ethCall(MANAGER, selectorOf('LAUNCH_FACTORY()')), // 2
    ethCall(MANAGER, selectorOf('REGISTRY()')), // 3
    ethCall(MANAGER, selectorOf('pausedUntil(uint256)') + word(0)), // 4
    ['eth_getBalance', [tx.from, at]], // 5
    ['eth_getCode', [tx.kernel, at]], // 6
    viaCall(k.token()), // 7
    viaCall(k.chipId()), // 8
    viaCall(k.envelope()), // 9
    viaCall(k.globals()), // 10
  ];
  if (circuits.ok) {
    reqs.push(['eth_getCode', [circuits.value, at]]); // 11
    reqs.push(ethCall(TAPEOUT_FACTORY, selectorOf('isCPU(address)') + addressWord(circuits.value))); // 12
    reqs.push(ethCall(circuits.value, selectorOf('transistors()'))); // 13
  }
  const isKernelAt = reqs.length;
  if (kernelFactory !== null) reqs.push(viaCall(factoryCalls(kernelFactory).isKernel(tx.kernel)));
  const r = await batch(rpc, reqs);
  facts.rpcUrl = rpc.current();

  facts.signer = fact(r[0], 'IgnixManager.signer()', (x) => asAddress(x, 'IgnixManager.signer()'));
  facts.poolFee = fact(r[1], 'IgnixManager.POOL_FEE()', (x) => oneWord(x, 'IgnixManager.POOL_FEE()'));
  facts.launchFactory = fact(r[2], 'IgnixManager.LAUNCH_FACTORY()', (x) => asAddress(x, 'IgnixManager.LAUNCH_FACTORY()'));
  const registry = fact(r[3], 'IgnixManager.REGISTRY()', (x) => asAddress(x, 'IgnixManager.REGISTRY()'));
  facts.launchPausedUntil = fact(r[4], 'IgnixManager.pausedUntil(0)', (x) => oneWord(x, 'IgnixManager.pausedUntil(0)'));
  facts.launcherBalance = fact(r[5], 'eth_getBalance(launcher)', (x) => BigInt(x as string));
  facts.kernelCodeSize = fact(r[6], 'eth_getCode(kernel)', codeSize);
  facts.kernelToken = fact(r[7], 'kernel.token()', (x) => k.token().decode(x as string));
  facts.kernelChipId = fact(r[8], 'kernel.chipId()', (x) => k.chipId().decode(x as string));
  facts.kernelEnvelope = fact(r[9], 'kernel.envelope()', (x) => k.envelope().decode(x as string));
  facts.kernelGlobals = fact(r[10], 'kernel.globals()', (x) => k.globals().decode(x as string));
  if (circuits.ok) {
    facts.circuitsCodeSize = fact(r[11], 'eth_getCode(Circuits)', codeSize);
    facts.circuitsIsProcessor = fact(r[12], 'TapeOutFactory.isCPU(Circuits)', (x) => oneWord(x, 'TapeOutFactory.isCPU(Circuits)') !== 0n);
    facts.circuitsTransistors = fact(r[13], 'Circuits.transistors()', (x) => asAddress(x, 'Circuits.transistors()'));
  } else {
    facts.circuitsCodeSize = missing(circuits.error);
    facts.circuitsIsProcessor = missing(circuits.error);
    facts.circuitsTransistors = missing(circuits.error);
  }
  if (kernelFactory !== null) {
    const c = factoryCalls(kernelFactory).isKernel(tx.kernel);
    facts.kernelIsKernel = fact(r[isKernelAt], 'KernelFactory.isKernel(kernel)', (x) => c.decode(x as string));
  } else {
    facts.kernelIsKernel = missing('no KernelFactory address was given');
  }

  // 3. the two reads that need an earlier answer
  const second: Req[] = [];
  const factoryReq = call !== null && registry.ok ? ethCall(registry.value, selectorOf('factoryOf(uint16)') + word(call.templateId)) : null;
  const ownerReq = circuits.ok && facts.kernelChipId.ok ? ethCall(circuits.value, selectorOf('ownerOf(uint256)') + word(facts.kernelChipId.value)) : null;
  if (factoryReq) second.push(factoryReq);
  if (ownerReq) second.push(ownerReq);
  const r2 = second.length ? await batch(rpc, second) : [];
  let i = 0;
  if (factoryReq) facts.registeredFactory = fact(r2[i++], 'VaultRegistry.factoryOf(templateId)', (x) => asAddress(x, 'VaultRegistry.factoryOf(templateId)'));
  else facts.registeredFactory = missing(call === null ? 'the calldata did not decode' : !registry.ok ? registry.error : 'not read');
  if (ownerReq) facts.chipOwner = fact(r2[i++], 'Circuits.ownerOf(chipId)', (x) => asAddress(x, 'Circuits.ownerOf(chipId)'));
  else facts.chipOwner = missing(!circuits.ok ? circuits.error : !facts.kernelChipId.ok ? facts.kernelChipId.error : 'not read');

  return facts;
}
