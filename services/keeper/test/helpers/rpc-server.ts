// A local JSON-RPC endpoint backed by the scripted World, so the real HTTP client and the real entry
// point can be exercised without touching X Layer.

import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { keccak256, parseTransaction } from 'viem';
import type { Address, Hex } from 'viem';
import { CALLDATA, remainingOfCalldata } from '../../src/abi.ts';
import { RevertError } from '../../src/errors.ts';
import type { SentTx, World } from './fake-chain.ts';

const hex = (n: bigint | number): string => `0x${BigInt(n).toString(16)}`;
const word = (n: bigint | number): string => `0x${BigInt(n).toString(16).padStart(64, '0')}`;

class NodeError extends Error {
  readonly code: number;
  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

function handle(world: World, method: string, params: unknown[]): unknown {
  switch (method) {
    case 'eth_chainId':
      return hex(world.chain);
    case 'eth_getCode':
      return world.code.has(String(params[0]).toLowerCase()) ? '0x6080' : '0x';
    case 'eth_getBlockByNumber':
      return { number: hex(world.block), baseFeePerGas: hex(world.baseFee) };
    case 'eth_getBalance':
      return hex(world.balances.get(String(params[0]).toLowerCase()) ?? 0n);
    case 'eth_getTransactionCount': {
      const pooled = new Set([...world.pool.values()].map((t) => t.nonce)).size;
      return hex(params[1] === 'pending' ? world.nonceLatest + pooled + world.foreignPending : world.nonceLatest);
    }
    case 'eth_call':
    case 'eth_estimateGas': {
      const call = params[0] as { to: Address; data: Hex };
      const k = world.kernels.get(call.to.toLowerCase());
      if (k && call.data !== CALLDATA.settle) {
        if (k.viewRevert) throw new RevertError(k.viewRevert);
        if (call.data === CALLDATA.epochNow) return word(k.epochNow);
        if (call.data === CALLDATA.lastEpoch) return word(k.lastEpoch);
        if (call.data === CALLDATA.minSettleGas) return word(k.minSettleGas);
        if (call.data === CALLDATA.chipId) return word(k.chipId);
        throw new RevertError('no such function');
      }
      if (!world.code.has(call.to.toLowerCase())) return '0x';
      // KeeperTank.remainingOf(uint256)
      if (world.tank && call.to.toLowerCase() === world.tank.toLowerCase() && call.data.startsWith(remainingOfCalldata(0n).slice(0, 10))) {
        return word(world.tankRemainingWei);
      }
      const target = world.check(call.to, call.data);
      if (method === 'eth_estimateGas') return hex(world.estimate);
      return target.via === 'direct' ? word(world.kernel(target.kernel).count + 1) : '0x';
    }
    case 'eth_sendRawTransaction': {
      const raw = params[0] as Hex;
      const hash = keccak256(raw);
      if (world.pool.has(hash) || world.receipts.has(hash)) throw new NodeError(-32000, 'already known');
      const p = parseTransaction(raw);
      if ((p.nonce ?? 0) < world.nonceLatest) throw new NodeError(-32000, 'nonce too low');
      const tx: SentTx = {
        raw,
        hash,
        to: p.to as Address,
        data: (p.data ?? '0x') as Hex,
        gas: p.gas ?? 0n,
        nonce: p.nonce ?? 0,
        chainId: p.chainId ?? 0,
        value: p.value ?? 0n,
        maxFeePerGas: p.maxFeePerGas ?? 0n,
        maxPriorityFeePerGas: p.maxPriorityFeePerGas ?? 0n,
        type: String(p.type),
      };
      world.sent.push(tx);
      world.pool.set(hash, tx);
      if (world.autoMine) world.mine(hash);
      return hash;
    }
    case 'eth_getTransactionReceipt': {
      const r = world.receipts.get(params[0] as Hex);
      if (!r) return null;
      return {
        transactionHash: r.transactionHash,
        status: r.status === 'success' ? '0x1' : '0x0',
        blockNumber: hex(r.blockNumber),
        gasUsed: hex(r.gasUsed),
        effectiveGasPrice: hex(r.effectiveGasPrice),
        l1Fee: hex(r.l1Fee),
        logs: r.logs,
      };
    }
    default:
      throw new NodeError(-32601, `the method ${method} does not exist`);
  }
}

export interface RpcServer {
  url: string;
  requests: Array<{ method: string; params: unknown[] }>;
  close(): Promise<void>;
}

export async function startRpcServer(world: World): Promise<RpcServer> {
  const requests: Array<{ method: string; params: unknown[] }> = [];
  const server = createServer((req, res) => {
    let body = '';
    req.on('data', (chunk: Buffer) => (body += chunk.toString('utf8')));
    req.on('end', () => {
      const { id, method, params } = JSON.parse(body) as { id: number; method: string; params: unknown[] };
      requests.push({ method, params });
      let reply: Record<string, unknown>;
      try {
        reply = { result: handle(world, method, params) };
      } catch (err) {
        if (err instanceof RevertError) reply = { error: { code: 3, message: `execution reverted: ${err.reason}` } };
        else if (err instanceof NodeError) reply = { error: { code: err.code, message: err.message } };
        else reply = { error: { code: -32603, message: String(err) } };
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ jsonrpc: '2.0', id, ...reply }));
    });
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${port}`,
    requests,
    close: () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  };
}
