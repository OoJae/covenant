// The JSON-RPC client against a scripted fetch: request shapes, result decoding and error classification.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { encodeAbiParameters, toFunctionSelector } from 'viem';
import { CALLDATA, knownErrorName } from '../src/abi.ts';
import { JsonRpcChainClient, classifyNodeError, decodeRevert, networkErrorKind } from '../src/chain.ts';
import {
  InsufficientFundsError,
  NonceTooLowError,
  RevertError,
  RpcError,
  TxRejectedError,
  UnderpricedError,
} from '../src/errors.ts';

const KERNEL = '0x00000000000000000000000000000000000000A1';
const WALLET = '0x00000000000000000000000000000000000000d4';
const URL_WITH_KEY = 'https://rpc.example/v2/API-KEY-123';

interface Call {
  method: string;
  params: unknown[];
}

type Handler = (call: Call) => { result?: unknown; error?: { code: number; message: string; data?: string } } | 'http500' | 'throw' | 'notjson';

function client(handler: Handler): { c: JsonRpcChainClient; calls: Call[] } {
  const calls: Call[] = [];
  const c = new JsonRpcChainClient(URL_WITH_KEY, {
    timeoutMs: 1000,
    fetch: async (url, init) => {
      assert.equal(url, URL_WITH_KEY);
      assert.equal(init.method, 'POST');
      const body = JSON.parse(init.body) as { jsonrpc: string; id: number; method: string; params: unknown[] };
      assert.equal(body.jsonrpc, '2.0');
      calls.push({ method: body.method, params: body.params });
      const r = handler({ method: body.method, params: body.params });
      if (r === 'throw') throw Object.assign(new TypeError(`fetch failed for ${URL_WITH_KEY}`), { cause: { code: 'ECONNREFUSED' } });
      if (r === 'http500') return { ok: false, status: 500, json: async () => ({}) };
      if (r === 'notjson') return { ok: true, status: 200, json: async () => Promise.reject(new SyntaxError('bad json')) };
      return { ok: true, status: 200, json: async () => ({ jsonrpc: '2.0', id: body.id, ...r }) };
    },
  });
  return { c, calls };
}

const word = (n: bigint | number): string => `0x${BigInt(n).toString(16).padStart(64, '0')}`;

test('the label is the host only', () => {
  const { c } = client(() => ({ result: '0xc4' }));
  assert.equal(c.label, 'rpc.example');
});

test('reads: chain id, code, kernel views, base fee, balance, nonces', async () => {
  const { c, calls } = client(({ method, params }) => {
    if (method === 'eth_chainId') return { result: '0xc4' };
    if (method === 'eth_getCode') return { result: params[0] === KERNEL ? '0x6080' : '0x' };
    if (method === 'eth_call') {
      const data = (params[0] as { data: string }).data;
      if (data === CALLDATA.epochNow) return { result: word(12) };
      if (data === CALLDATA.lastEpoch) return { result: word(11) };
      if (data === CALLDATA.minSettleGas) return { result: word(12_000_000) };
      if (data === CALLDATA.chipId) return { result: word(3151) };
    }
    if (method === 'eth_getBlockByNumber') return { result: { baseFeePerGas: '0x1312d00' } };
    if (method === 'eth_getBalance') return { result: '0xb1a2bc2ec50000' };
    if (method === 'eth_getTransactionCount') return { result: params[1] === 'pending' ? '0x9' : '0x8' };
    return { error: { code: -32601, message: 'method not found' } };
  });
  assert.equal(await c.chainId(), 196);
  assert.equal(await c.hasCode(KERNEL), true);
  assert.equal(await c.hasCode(WALLET), false);
  assert.deepEqual(await c.epochs(KERNEL), { epochNow: 12, lastEpoch: 11 });
  assert.equal(await c.minSettleGas(KERNEL), 12_000_000n);
  assert.equal(await c.chipId(KERNEL), 3151n);
  assert.equal(await c.baseFee(), 20_000_000n);
  assert.equal(await c.balance(WALLET), 50_000_000_000_000_000n);
  assert.deepEqual(await c.nonces(WALLET), { latest: 8, pending: 9 });
  assert.deepEqual(calls.find((x) => x.method === 'eth_getBlockByNumber')?.params, ['latest', false]);
});

test('a view that returns no data means the address is not a kernel', async () => {
  const { c } = client(() => ({ result: '0x' }));
  await assert.rejects(c.epochs(KERNEL), (e: unknown) => e instanceof RevertError && /epochNow\(\) returned no data/.test(e.reason));
});

test('estimateGas and simulate send from, to, data, zero value and the fee fields when given', async () => {
  const { c, calls } = client(({ method }) => (method === 'eth_estimateGas' ? { result: '0x4c4b40' } : { result: '0x' }));
  const call = { from: WALLET, to: KERNEL, data: CALLDATA.settle } as const;
  assert.equal(await c.estimateGas(call), 5_000_000n);
  assert.deepEqual(calls[0]?.params, [{ from: WALLET, to: KERNEL, data: '0x11da60b4', value: '0x0' }]);

  await c.simulate({ ...call, gas: 11_000_000n, maxFeePerGas: 41_000_000n, maxPriorityFeePerGas: 1_000_000n });
  assert.deepEqual(calls[1]?.params, [
    { from: WALLET, to: KERNEL, data: '0x11da60b4', value: '0x0', gas: '0xa7d8c0', maxFeePerGas: '0x2719c40', maxPriorityFeePerGas: '0xf4240' },
    'latest',
  ]);
});

test('a revert carries its reason; it is not an RPC fault', async () => {
  const data = `0x08c379a0${encodeAbiParameters([{ type: 'string' }], ['epoch already settled']).slice(2)}`;
  const { c } = client(() => ({ error: { code: 3, message: 'execution reverted: epoch already settled', data } }));
  await assert.rejects(
    c.simulate({ from: WALLET, to: KERNEL, data: CALLDATA.settle }),
    (e: unknown) => e instanceof RevertError && e.reason === 'epoch already settled' && e.data === data,
  );
  await assert.rejects(c.estimateGas({ from: WALLET, to: KERNEL, data: CALLDATA.settle }), RevertError);
});

test('custom errors of the kernel and the tank are reported by name', async () => {
  for (const sig of ['EpochNotElapsed()', 'NotBound()', 'InsufficientGas()', 'StepFailed()', 'KernelDoesNotHoldChip()', 'RefundFailed()']) {
    const data = toFunctionSelector(sig);
    assert.equal(knownErrorName(data), sig);
    assert.equal(decodeRevert(data, 'execution reverted'), sig);
    const { c } = client(() => ({ error: { code: 3, message: 'execution reverted', data } }));
    await assert.rejects(
      c.estimateGas({ from: WALLET, to: KERNEL, data: CALLDATA.settle }),
      (e: unknown) => e instanceof RevertError && e.reason === sig,
    );
  }
  // An error with arguments is matched on its selector.
  const bindCheck = `${toFunctionSelector('BindCheck(uint8)')}${'0'.repeat(63)}7`;
  assert.equal(decodeRevert(bindCheck, 'execution reverted'), 'BindCheck(uint8)');
  assert.equal(knownErrorName('0xdeadbeef'), null);
});

test('the selectors the immutable tank calls are the frozen ones', () => {
  // contracts/issuance/src/interfaces/IKernelMin.sol: chipId() 0x0351e494, settle() 0x11da60b4
  assert.equal(CALLDATA.chipId, '0x0351e494');
  assert.equal(CALLDATA.settle, '0x11da60b4');
});

test('tankRemaining reads KeeperTank.remainingOf(chipId)', async () => {
  const { c, calls } = client(() => ({ result: word(777) }));
  assert.equal(await c.tankRemaining(KERNEL, 42n), 777n);
  const sent = calls[0]?.params[0] as { to: string; data: string };
  assert.equal(sent.to, KERNEL);
  assert.equal(sent.data, `${toFunctionSelector('remainingOf(uint256)')}${(42).toString(16).padStart(64, '0')}`);
});

test('decodeRevert: Error(string), Panic, custom error, bare message', () => {
  const data = `0x08c379a0${encodeAbiParameters([{ type: 'string' }], ['nope']).slice(2)}`;
  assert.equal(decodeRevert(data, 'execution reverted'), 'nope');
  assert.equal(decodeRevert(`0x4e487b71${'0'.repeat(62)}11`, 'execution reverted'), 'panic 0x11');
  assert.equal(decodeRevert('0xdeadbeef', 'execution reverted'), 'custom error 0xdeadbeef');
  assert.equal(decodeRevert(undefined, 'execution reverted: too early'), 'too early');
  assert.equal(decodeRevert(undefined, 'execution reverted'), 'no reason given');
  assert.equal(decodeRevert(null, 'out of gas'), 'out of gas');
});

test('classification of node errors', () => {
  const k = (method: string, code: number, message: string): Error => classifyNodeError('h', method, code, message);
  assert.ok(k('eth_call', 3, 'execution reverted') instanceof RevertError);
  assert.ok(k('eth_call', -32000, 'execution reverted') instanceof RevertError);
  assert.ok(k('eth_estimateGas', -32000, 'gas required exceeds allowance (50000000)') instanceof RevertError);
  assert.ok(k('eth_call', -32000, 'out of gas') instanceof RevertError);
  assert.ok(k('eth_estimateGas', -32000, 'insufficient funds for gas * price + value') instanceof InsufficientFundsError);
  assert.ok(k('eth_sendRawTransaction', -32000, 'nonce too low') instanceof NonceTooLowError);
  assert.ok(k('eth_sendRawTransaction', -32000, 'replacement transaction underpriced') instanceof UnderpricedError);
  assert.ok(k('eth_sendRawTransaction', -32000, 'insufficient funds for gas * price + value') instanceof InsufficientFundsError);
  assert.ok(k('eth_sendRawTransaction', -32602, 'rlp: too few elements for types.DynamicFeeTx') instanceof TxRejectedError);
  assert.ok(k('eth_sendRawTransaction', -32000, 'max fee per gas less than block base fee') instanceof TxRejectedError);
  // Rate limits, internal errors and unknown methods are faults of the endpoint: try another one.
  assert.ok(k('eth_call', -32005, 'rate limit exceeded') instanceof RpcError);
  assert.ok(k('eth_call', -32603, 'internal error') instanceof RpcError);
  assert.ok(k('eth_getBalance', 3, 'execution reverted') instanceof RpcError);
  assert.ok(k('eth_sendRawTransaction', -32000, 'txpool is full') instanceof RpcError);
});

test('sendRaw: accepted, already known, and the rejections', async () => {
  let answer: ReturnType<Handler> = { result: '0xabc' };
  const { c } = client(() => answer);
  await c.sendRaw('0x02ab');
  answer = { error: { code: -32000, message: 'already known' } };
  await c.sendRaw('0x02ab'); // the node has it: success
  answer = { error: { code: -32000, message: 'nonce too low' } };
  await assert.rejects(c.sendRaw('0x02ab'), NonceTooLowError);
  answer = { error: { code: -32000, message: 'replacement transaction underpriced' } };
  await assert.rejects(c.sendRaw('0x02ab'), UnderpricedError);
});

test('transport failures are RpcError and never contain the URL', async () => {
  for (const mode of ['throw', 'http500', 'notjson'] as const) {
    const { c } = client(() => mode);
    await assert.rejects(c.chainId(), (e: unknown) => {
      assert.ok(e instanceof RpcError, `${mode} should be an RpcError`);
      assert.doesNotMatch(e.message, /API-KEY-123/);
      assert.match(e.message, /rpc\.example/);
      return true;
    });
  }
  const { c } = client(() => 'throw');
  await assert.rejects(c.chainId(), /ECONNREFUSED/);
});

test('networkErrorKind returns a code or a fixed label, never free text', () => {
  assert.equal(networkErrorKind(Object.assign(new Error('x'), { name: 'TimeoutError' })), 'timeout');
  assert.equal(networkErrorKind({ cause: { code: 'ENOTFOUND' } }), 'ENOTFOUND');
  assert.equal(networkErrorKind({ cause: { errors: [{ code: 'ECONNREFUSED' }] } }), 'ECONNREFUSED');
  assert.equal(networkErrorKind(new TypeError('fetch failed: https://rpc.example/v2/API-KEY-123')), 'network error');
  assert.equal(networkErrorKind({ cause: { code: 'https://rpc.example/v2/API-KEY-123' } }), 'network error');
});

test('receipt: null when unknown; status, gas, fee and logs when mined', async () => {
  const hash = `0x${'ab'.repeat(32)}` as const;
  let answer: ReturnType<Handler> = { result: null };
  const { c } = client(() => answer);
  assert.equal(await c.receipt(hash), null);

  answer = {
    result: {
      status: '0x1',
      blockNumber: '0x10',
      gasUsed: '0x401640',
      effectiveGasPrice: '0x1406f40',
      l1Fee: '0x5',
      logs: [{ address: KERNEL, topics: ['0x01'], data: '0x' }, { bogus: true }],
    },
  };
  assert.deepEqual(await c.receipt(hash), {
    transactionHash: hash,
    status: 'success',
    blockNumber: 16n,
    gasUsed: 4_200_000n,
    effectiveGasPrice: 21_000_000n,
    l1Fee: 5n,
    logs: [{ address: KERNEL, topics: ['0x01'], data: '0x' }],
  });

  answer = { result: { status: '0x0', blockNumber: '0x11', gasUsed: '0x5208' } };
  const reverted = await c.receipt(hash);
  assert.equal(reverted?.status, 'reverted');
  assert.equal(reverted?.effectiveGasPrice, 0n);
  assert.equal(reverted?.l1Fee, 0n);
});
