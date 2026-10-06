// The JSON-RPC client against a scripted fetch: batching, failover, reverts, timeouts.

import { describe, expect, test } from 'vitest';
import { decodeFunctionData, encodeErrorResult, encodeFunctionResult, parseAbi, type Hex } from 'viem';
import { CallError, createRpc, isRevert, MULTICALL3, processor, read, readAll, RpcError } from '../src/index.ts';

const A = 'https://a.example';
const B = 'https://b.example';

interface Msg {
  jsonrpc: string;
  id: number;
  method: string;
  params: unknown[];
}
type Handler = (url: string, body: Msg | Msg[], hit: number) => Response | Promise<Response>;

function scripted(handler: Handler) {
  const log: { url: string; body: Msg | Msg[] }[] = [];
  const fn = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const body = JSON.parse(String(init?.body)) as Msg | Msg[];
    log.push({ url, body });
    return handler(url, body, log.length);
  }) as typeof fetch;
  return { fn, log };
}

const json = (v: unknown, status = 200): Response =>
  new Response(JSON.stringify(v), { status, headers: { 'content-type': 'application/json' } });
const ok = (m: Msg, result: unknown) => ({ jsonrpc: '2.0', id: m.id, result });
const answer = (body: Msg | Msg[], f: (m: Msg) => unknown): Response =>
  json(Array.isArray(body) ? body.map((m) => ok(m, f(m))) : ok(body, f(body)));
const echo = (body: Msg | Msg[]): Response => answer(body, (m) => m.params[0]);

const REVERT = encodeErrorResult({ abi: parseAbi(['error Error(string)']), errorName: 'Error', args: ['has latch: use step'] });

describe('the text/plain form', () => {
  test('an endpoint that answers it with HTTP 200 and "invalid request" is asked again as JSON, and from then on only so', async () => {
    const types: (string | null)[] = [];
    const fn = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      const h = new Headers(init?.headers);
      types.push(h.get('content-type'));
      const body = JSON.parse(String(init?.body)) as Msg | Msg[];
      if (h.get('content-type') !== 'application/json') return json({ jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Invalid request' } });
      return echo(body);
    }) as typeof fetch;
    const rpc = createRpc([A], { fetch: fn });
    expect(await rpc.batch([['m', [1]], ['m', [2]]])).toEqual([1, 2]);
    expect(await rpc.send('m', [3])).toBe(3);
    expect(types).toEqual([null, 'application/json', 'application/json']);
  });
});

describe('batching', () => {
  test('25 calls go out as HTTP requests of 10, 10 and 5, results in call order', async () => {
    const { fn, log } = scripted((_u, body) => echo(body));
    const rpc = createRpc([A], { fetch: fn });
    const out = await rpc.batch(Array.from({ length: 25 }, (_, i) => ['m', [i]] as const));
    expect(out).toEqual(Array.from({ length: 25 }, (_, i) => i));
    expect(log.map((l) => (Array.isArray(l.body) ? l.body.length : 1))).toEqual([10, 10, 5]);
  });

  test('never more than 10 per request, whatever maxBatch says', async () => {
    const { fn, log } = scripted((_u, body) => echo(body));
    const rpc = createRpc([A], { fetch: fn, maxBatch: 500 });
    await rpc.batch(Array.from({ length: 31 }, (_, i) => ['m', [i]] as const));
    expect(log.map((l) => (Array.isArray(l.body) ? l.body.length : 1))).toEqual([10, 10, 10, 1]);
  });

  test('a smaller maxBatch is honoured', async () => {
    const { fn, log } = scripted((_u, body) => echo(body));
    const rpc = createRpc([A], { fetch: fn, maxBatch: 4 });
    await rpc.batch(Array.from({ length: 9 }, (_, i) => ['m', [i]] as const));
    expect(log.map((l) => (Array.isArray(l.body) ? l.body.length : 1))).toEqual([4, 4, 1]);
  });

  test('a single call is sent as an object, with JSON-RPC 2.0 framing', async () => {
    const { fn, log } = scripted((_u, body) => echo(body));
    const rpc = createRpc([A], { fetch: fn });
    expect(await rpc.send('eth_chainId', ['x'])).toBe('x');
    expect(Array.isArray(log[0].body)).toBe(false);
    const m = log[0].body as Msg;
    expect(m.jsonrpc).toBe('2.0');
    expect(m.method).toBe('eth_chainId');
    expect(typeof m.id).toBe('number');
  });

  test('replies are matched by id, not by position', async () => {
    const { fn } = scripted((_u, body) => json((body as Msg[]).map((m) => ok(m, m.params[0])).reverse()));
    const rpc = createRpc([A], { fetch: fn });
    expect(await rpc.batch([['m', ['a']], ['m', ['b']], ['m', ['c']]])).toEqual(['a', 'b', 'c']);
  });

  test('ids are unique across requests', async () => {
    const { fn, log } = scripted((_u, body) => echo(body));
    const rpc = createRpc([A], { fetch: fn });
    await rpc.batch(Array.from({ length: 15 }, (_, i) => ['m', [i]] as const));
    await rpc.send('m', [1]);
    const ids = log.flatMap((l) => (Array.isArray(l.body) ? l.body.map((m) => m.id) : [l.body.id]));
    expect(new Set(ids).size).toBe(16);
  });

  test('an empty batch makes no request', async () => {
    const { fn, log } = scripted((_u, body) => echo(body));
    expect(await createRpc([A], { fetch: fn }).batch([])).toEqual([]);
    expect(log.length).toBe(0);
  });

  test('eth_call sends {to, data} and the block tag', async () => {
    const { fn, log } = scripted((_u, body) => answer(body, () => '0x01'));
    const rpc = createRpc([A], { fetch: fn });
    expect(await rpc.call('0xabc', '0x1234')).toBe('0x01');
    expect((log[0].body as Msg).params).toEqual([{ to: '0xabc', data: '0x1234' }, 'latest']);
    await rpc.call('0xabc', '0x1234', '0x10');
    expect((log[1].body as Msg).params[1]).toBe('0x10');
  });
});

describe('content type', () => {
  const contentType = (init?: RequestInit): string | null => new Headers(init?.headers).get('content-type');

  test('requests carry no content-type header, so a browser sends them without a preflight', async () => {
    const seen: (string | null)[] = [];
    const fn = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      seen.push(contentType(init));
      return echo(JSON.parse(String(init?.body)) as Msg);
    }) as typeof fetch;
    const rpc = createRpc([A], { fetch: fn });
    await rpc.send('m', [1]);
    await rpc.batch([['m', [1]], ['m', [2]]]);
    expect(seen).toEqual([null, null]);
  });

  test('an endpoint that refuses that is asked again with application/json, and only that way afterwards', async () => {
    const seen: [string, string | null][] = [];
    const fn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const type = contentType(init);
      seen.push([String(input), type]);
      if (String(input) === A && type !== 'application/json') return json({ error: 'unsupported media type' }, 415);
      return echo(JSON.parse(String(init?.body)) as Msg);
    }) as typeof fetch;
    const rpc = createRpc([A, B], { fetch: fn });
    expect(await rpc.send('m', [1])).toBe(1);
    expect(await rpc.send('m', [2])).toBe(2);
    expect(rpc.current()).toBe(A); // no failover was needed
    expect(seen).toEqual([
      [A, null],
      [A, 'application/json'],
      [A, 'application/json'],
    ]);
  });

  test('an endpoint that is simply down is not asked twice per attempt once it has been switched', async () => {
    const { fn, log } = scripted((url, body) => (url === A ? json({}, 503) : echo(body)));
    const rpc = createRpc([A, B], { fetch: fn });
    expect(await rpc.send('m', [1])).toBe(1);
    // A: plain, then application/json (both 503); B answers
    expect(log.map((l) => l.url)).toEqual([A, A, B]);
  });
});

describe('failover', () => {
  test('a network error moves to the next endpoint, which then stays first choice', async () => {
    const { fn, log } = scripted((url, body) => {
      if (url === A) throw new TypeError('fetch failed');
      return echo(body);
    });
    const rpc = createRpc([A, B], { fetch: fn });
    expect(rpc.current()).toBe(A);
    expect(await rpc.send('m', [1])).toBe(1);
    expect(rpc.current()).toBe(B);
    expect(await rpc.send('m', [2])).toBe(2);
    expect(log.map((l) => l.url)).toEqual([A, B, B]);
  });

  for (const status of [429, 500, 502, 503]) {
    test(`HTTP ${status} moves to the next endpoint`, async () => {
      const { fn, log } = scripted((url, body) => (url === A ? json({ error: 'nope' }, status) : echo(body)));
      const rpc = createRpc([A, B], { fetch: fn });
      expect(await rpc.send('m', [7])).toBe(7);
      // A is asked twice the first time it answers with an error status (see "content type")
      expect(log.map((l) => l.url)).toEqual([A, A, B]);
      expect(rpc.current()).toBe(B);
    });
  }

  test('a body that is not JSON moves to the next endpoint', async () => {
    const { fn, log } = scripted((url, body) => (url === A ? new Response('<html>gateway</html>') : echo(body)));
    const rpc = createRpc([A, B], { fetch: fn });
    expect(await rpc.send('m', [7])).toBe(7);
    expect(log.map((l) => l.url)).toEqual([A, B]);
  });

  test('a batch refused as a whole (error -32014) moves to the next endpoint', async () => {
    const refuse = { jsonrpc: '2.0', error: { code: -32014, message: 'too many RPC calls in batch request' }, id: null };
    const { fn, log } = scripted((url, body) => (url === A ? json(refuse) : echo(body)));
    const rpc = createRpc([A, B], { fetch: fn });
    expect(await rpc.batch([['m', [1]], ['m', [2]]])).toEqual([1, 2]);
    expect(log.map((l) => l.url)).toEqual([A, B]);
  });

  test('a timeout aborts the request and moves on', async () => {
    const { fn, log } = scripted((url, body) => {
      if (url !== A) return echo(body);
      return new Promise<Response>(() => {}); // never answers
    });
    // honour the abort signal the way fetch does
    const withAbort = ((input: RequestInfo | URL, init?: RequestInit) =>
      Promise.race([
        fn(input, init),
        new Promise<Response>((_, reject) => init?.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))),
      ])) as typeof fetch;
    const rpc = createRpc([A, B], { fetch: withAbort, timeout: 30 });
    expect(await rpc.send('m', [5])).toBe(5);
    expect(log.map((l) => l.url)).toEqual([A, B]);
  });

  test('when every endpoint fails, each is tried `1 + retries` times and the last error is thrown', async () => {
    const { fn, log } = scripted(() => json({}, 503));
    const rpc = createRpc([A, B], { fetch: fn, retries: 1 });
    await expect(rpc.send('m', [1])).rejects.toThrow('HTTP 503');
    // first round: each endpoint twice (plain, then application/json); second round: once each
    expect(log.map((l) => l.url)).toEqual([A, A, B, B, A, B]);
    const none = scripted(() => json({}, 503));
    await expect(createRpc([A, B], { fetch: none.fn, retries: 0 }).send('m', [1])).rejects.toThrow('HTTP 503');
    expect(none.log.map((l) => l.url)).toEqual([A, A, B, B]);
  });

  test('a recovered endpoint is used again after the other one fails', async () => {
    let aDown = true;
    let bDown = false;
    const { fn, log } = scripted((url, body) => {
      if ((url === A && aDown) || (url === B && bDown)) return json({}, 500);
      return echo(body);
    });
    const rpc = createRpc([A, B], { fetch: fn });
    await rpc.send('m', [1]); // A fails (asked twice), B answers
    aDown = false;
    bDown = true;
    await rpc.send('m', [2]); // B fails (asked twice), A answers
    expect(log.map((l) => l.url)).toEqual([A, A, B, B, B, A]);
    expect(rpc.current()).toBe(A);
  });

  test('createRpc refuses an empty endpoint list', () => {
    expect(() => createRpc([])).toThrow('no endpoint');
  });
});

describe('JSON-RPC errors', () => {
  test('a revert is final: no retry, reason data preserved', async () => {
    const { fn, log } = scripted((_u, body) =>
      json({ jsonrpc: '2.0', id: (body as Msg).id, error: { code: 3, message: 'execution reverted: has latch: use step', data: REVERT } }),
    );
    const rpc = createRpc([A, B], { fetch: fn });
    const err = await rpc.call('0xabc', '0x').catch((e: unknown) => e);
    expect(err).toBeInstanceOf(RpcError);
    expect(isRevert(err)).toBe(true);
    expect((err as RpcError).code).toBe(3);
    expect((err as RpcError).data).toBe(REVERT);
    expect(log.length).toBe(1);
  });

  test('a revert reported without data is still recognised by its message', () => {
    expect(isRevert(new RpcError({ code: -32000, message: 'execution reverted' }))).toBe(true);
    expect(isRevert(new RpcError({ code: -32005, message: 'rate limited' }))).toBe(false);
    expect(isRevert(new Error('execution reverted'))).toBe(false);
  });

  test('a node-side error on one call is retried once, on the other endpoint, for that call only', async () => {
    const { fn, log } = scripted((url, body) => {
      const list = Array.isArray(body) ? body : [body];
      const replies = list.map((m) =>
        url === A && m.params[0] === 'flaky'
          ? { jsonrpc: '2.0', id: m.id, error: { code: -32603, message: 'internal error' } }
          : ok(m, m.params[0]),
      );
      return json(Array.isArray(body) ? replies : replies[0]);
    });
    const rpc = createRpc([A, B], { fetch: fn });
    expect(await rpc.batch([['m', ['x']], ['m', ['flaky']], ['m', ['y']]])).toEqual(['x', 'flaky', 'y']);
    expect(log.map((l) => l.url)).toEqual([A, B]);
    expect(Array.isArray(log[1].body) ? log[1].body.length : 1).toBe(1);
  });

  test('a node-side error that persists is returned in place, and thrown by send', async () => {
    const { fn, log } = scripted((_u, body) => {
      const list = Array.isArray(body) ? body : [body];
      const replies = list.map((m) => ({ jsonrpc: '2.0', id: m.id, error: { code: -32603, message: 'internal error' } }));
      return json(Array.isArray(body) ? replies : replies[0]);
    });
    const rpc = createRpc([A, B], { fetch: fn });
    const [r] = await rpc.batch([['m', [1]]]);
    expect(r).toBeInstanceOf(RpcError);
    expect((r as RpcError).code).toBe(-32603);
    expect(log.length).toBe(2);
    await expect(rpc.send('m', [1])).rejects.toThrow('internal error');
  });

  test('a call missing from the reply becomes an error for that call', async () => {
    // The node answers only calls whose parameter is 1 and stays silent about the rest.
    const { fn, log } = scripted((_u, body) => {
      const list = Array.isArray(body) ? body : [body];
      return json(list.filter((m) => m.params[0] === 1).map((m) => ok(m, 'only')));
    });
    const rpc = createRpc([A], { fetch: fn });
    const out = await rpc.batch([['m', [1]], ['m', [2]]]);
    expect(out[0]).toBe('only');
    expect(out[1]).toBeInstanceOf(RpcError);
    expect((out[1] as RpcError).message).toBe('no reply for this call');
    expect(log.length).toBe(2); // the silent call was asked for once more
  });

  test('a null result is a result, not an error', async () => {
    const { fn } = scripted((_u, body) => answer(body, () => null));
    expect(await createRpc([A], { fetch: fn }).send('eth_getTransactionReceipt', ['0x00'])).toBe(null);
  });
});

describe('read and readAll', () => {
  const mc = parseAbi([
    'struct Call3 { address target; bool allowFailure; bytes callData; }',
    'struct Result { bool success; bytes returnData; }',
    'function aggregate3(Call3[] calls) payable returns (Result[] returnData)',
  ]);
  const P = '0x933fc3aa0c387cb8b6b1d22a2ec3e2b5eecfdb5a';
  const word = (v: number): string => v.toString(16).padStart(64, '0');
  const noCircuit = encodeErrorResult({ abi: parseAbi(['error Error(string)']), errorName: 'Error', args: ['no circuit'] });

  // A pretend chain: circuitInfo(id) answers for id < 1000, ownerOf reverts, anything else returns junk.
  const subcall = (data: Hex): { success: boolean; returnData: Hex } => {
    const id = parseInt(data.slice(10), 16);
    if (data.startsWith('0x084d60f1')) {
      if (id >= 1000) return { success: false, returnData: noCircuit };
      return { success: true, returnData: ('0x' + word(id) + word(1) + word(2) + word(id * 10)) as Hex };
    }
    if (data.startsWith('0x6352211e')) return { success: false, returnData: '0x' };
    return { success: true, returnData: '0x1234' };
  };
  const chain = scripted((_u, body) =>
    answer(body, (m) => {
      const { to, data } = m.params[0] as { to: string; data: Hex };
      expect(m.method).toBe('eth_call');
      expect(to).toBe(MULTICALL3);
      const { args } = decodeFunctionData({ abi: mc, data });
      expect(args[0].every((c) => c.allowFailure)).toBe(true);
      return encodeFunctionResult({ abi: mc, functionName: 'aggregate3', result: args[0].map((c) => subcall(c.callData)) });
    }),
  );

  test('250 calls: three aggregate3 eth_calls in one HTTP request', async () => {
    const before = chain.log.length;
    const rpc = createRpc([A], { fetch: chain.fn });
    const p = processor(P);
    const out = await readAll(rpc, Array.from({ length: 250 }, (_, i) => p.circuitInfo(i)));
    expect(out.length).toBe(250);
    out.forEach((info, i) => expect(info).toEqual({ nIn: i, nOut: 1, nState: 2, gateCount: i * 10 }));
    expect(chain.log.length - before).toBe(1);
    expect((chain.log[before].body as Msg[]).length).toBe(3);
  });

  test('1,100 sub-calls with a chunk of 100: 11 eth_calls, so two HTTP requests', async () => {
    const before = chain.log.length;
    const rpc = createRpc([A], { fetch: chain.fn });
    const p = processor(P);
    const out = await readAll(rpc, Array.from({ length: 1100 }, (_, i) => p.circuitInfo(i % 900)));
    expect(out.length).toBe(1100);
    expect(out[1099]).toEqual({ nIn: 199, nOut: 1, nState: 2, gateCount: 1990 });
    expect(chain.log.length - before).toBe(2);
  });

  test('a failing sub-call is an Error in its own slot and does not disturb the others', async () => {
    const rpc = createRpc([A], { fetch: chain.fn });
    const p = processor(P);
    const [info, owner, missing, junk] = await readAll(rpc, [p.circuitInfo(5), p.ownerOf(5), p.circuitInfo(5000), p.name()] as const);
    expect(info).toEqual({ nIn: 5, nOut: 1, nState: 2, gateCount: 50 });
    expect(owner).toBeInstanceOf(CallError);
    expect((owner as Error).message).toBe('reverted');
    expect(missing).toBeInstanceOf(CallError);
    expect((missing as Error).message).toBe('no circuit');
    expect((missing as CallError).data).toBe(noCircuit);
    expect(junk).toBeInstanceOf(CallError); // success, but the return data is not a string
    expect((junk as Error).message).toContain('too short');
  });

  test('if the aggregate3 call itself fails, every call in that chunk carries the error', async () => {
    const { fn } = scripted((_u, body) =>
      json({ jsonrpc: '2.0', id: (body as Msg).id, error: { code: -32000, message: 'out of gas' } }),
    );
    const rpc = createRpc([A], { fetch: fn });
    const p = processor(P);
    const out = await readAll(rpc, [p.name(), p.symbol()] as const);
    expect(out[0]).toBeInstanceOf(RpcError);
    expect(out[1]).toBeInstanceOf(RpcError);
  });

  test('no calls, no request', async () => {
    const { fn, log } = scripted((_u, body) => echo(body));
    expect(await readAll(createRpc([A], { fetch: fn }), [])).toEqual([]);
    expect(log.length).toBe(0);
  });

  test('read: one direct eth_call to the target; a revert becomes a CallError with the reason', async () => {
    const { fn, log } = scripted((_u, body) => {
      const m = body as Msg;
      const { data } = m.params[0] as { to: string; data: string };
      if (data.startsWith('0x934d06ea')) {
        return json({ jsonrpc: '2.0', id: m.id, error: { code: 3, message: 'execution reverted: has latch: use step', data: REVERT } });
      }
      return json(ok(m, '0x' + word(133) + word(199) + word(243) + word(4863)));
    });
    const rpc = createRpc([A], { fetch: fn });
    const p = processor(P);
    expect(await read(rpc, p.circuitInfo(3))).toEqual({ nIn: 133, nOut: 199, nState: 243, gateCount: 4863 });
    expect((log[0].body as Msg).params[0]).toEqual({ to: P, data: p.circuitInfo(3).data });
    const err = await read(rpc, p.eval(3, '0x')).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(CallError);
    expect((err as CallError).message).toBe('has latch: use step');
    expect((err as CallError).data).toBe(REVERT);
  });
});
