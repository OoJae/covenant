// A minimal JSON-RPC client over fetch: failover between endpoints, batches of at most 10.
//
// Measured on X Layer (rpc.xlayer.tech and xlayerrpc.okx.com, 2026-10-04): a batch above 10
// calls is refused with error -32014; an HTTP request counts once against the 7-per-second
// limit however many calls it carries; eth_call is capped at 50M gas; a revert comes back as
// error code 3 with the revert data in `error.data`.
//
// Requests are sent without a content-type header, so the body goes out as text/plain. That
// is a CORS "simple" request: a browser sends it straight away instead of asking permission
// first with an OPTIONS round trip (neither node sets a max-age, so that round trip would
// precede almost every call and count against the rate limit). Both nodes answer text/plain
// exactly as they answer application/json. An endpoint that refuses it with a non-2xx status
// is asked again with application/json, and from then on only that way.

export interface RpcErrorBody {
  code?: number;
  message?: string;
  data?: unknown;
}

export class RpcError extends Error {
  readonly code: number;
  /** Revert data, when the node supplied it. */
  readonly data: string | undefined;

  constructor(e: RpcErrorBody | null | undefined) {
    super(e?.message ?? 'RPC error');
    this.name = 'RpcError';
    this.code = e?.code ?? 0;
    this.data = typeof e?.data === 'string' ? e.data : undefined;
  }
}

/** True when the node executed the call and it reverted (as opposed to the node failing). */
export const isRevert = (e: unknown): e is RpcError =>
  e instanceof RpcError && (e.code === 3 || e.data !== undefined || /revert/i.test(e.message));

export type RpcRequest = readonly [method: string, params: readonly unknown[]];

export interface RpcOptions {
  /** Defaults to the global fetch. */
  fetch?: typeof fetch;
  /** Milliseconds before a request is abandoned and the next endpoint is tried. Default 20,000. */
  timeout?: number;
  /** Calls per HTTP request, at most 10 (the X Layer limit). Default 10. */
  maxBatch?: number;
  /** How many more times to go round all endpoints after each has failed once. Default 1. */
  retries?: number;
}

export interface Rpc {
  readonly urls: readonly string[];
  /** The endpoint that answered most recently. */
  current(): string;
  /** Send many calls in as few HTTP requests as allowed. Each entry is a result or an `RpcError`. */
  batch(reqs: readonly RpcRequest[]): Promise<unknown[]>;
  /** Send one call. Throws `RpcError` on a JSON-RPC error. */
  send(method: string, params?: readonly unknown[]): Promise<unknown>;
  /** `eth_call`; returns the raw return data. Throws `RpcError` (see `isRevert`). */
  call(to: string, data: string, block?: string): Promise<string>;
}

interface Reply {
  id?: unknown;
  result?: unknown;
  error?: RpcErrorBody;
}

export function createRpc(urls: readonly string[], opts: RpcOptions = {}): Rpc {
  if (!urls.length) throw new Error('createRpc: no endpoint');
  const doFetch = opts.fetch ?? fetch;
  const timeout = opts.timeout ?? 20000;
  const maxBatch = Math.max(1, Math.min(opts.maxBatch ?? 10, 10));
  const tries = urls.length * (1 + (opts.retries ?? 1));
  // Per endpoint: still worth trying the preflight-free form?
  const simple = urls.map(() => true);
  let cur = 0;
  let nextId = 0;

  // One HTTP request. Tries each endpoint in turn, starting with the last good one, and goes
  // round again after a short pause. Fails over on a network error, a timeout, a non-2xx
  // status, a body that is not JSON, or a single error object in reply to a batch.
  const post = async (body: unknown): Promise<unknown> => {
    const start = cur;
    let last: unknown;
    for (let t = 0; t < tries; t++) {
      const i = (start + t) % urls.length;
      if (t && i === start) await new Promise((r) => setTimeout(r, (300 * t) / urls.length));
      const ask = (): Promise<Response> =>
        doFetch(urls[i], {
          method: 'POST',
          headers: simple[i] ? {} : { 'content-type': 'application/json' },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(timeout),
        });
      try {
        let res = await ask();
        if (!res.ok && simple[i]) {
          simple[i] = false;
          res = await ask();
        }
        if (!res.ok) throw new Error(`HTTP ${res.status} from ${urls[i]}`);
        const json: unknown = await res.json();
        if (Array.isArray(body) && !Array.isArray(json)) throw new RpcError((json as Reply | null)?.error);
        cur = i;
        return json;
      } catch (e) {
        last = e;
      }
    }
    throw last;
  };

  const batch = async (reqs: readonly RpcRequest[]): Promise<unknown[]> => {
    const out: unknown[] = new Array(reqs.length);
    for (let o = 0; o < reqs.length; o += maxBatch) {
      // Indices still to be answered in this chunk. A call that fails for a reason other than
      // a revert is sent once more, to the next endpoint.
      let todo = reqs.slice(o, o + maxBatch).map((_, j) => o + j);
      for (let round = 0; todo.length && round < 2; round++) {
        const msgs = todo.map((k) => ({ jsonrpc: '2.0', id: ++nextId, method: reqs[k][0], params: reqs[k][1] }));
        const replies = [await post(msgs.length > 1 ? msgs : msgs[0])].flat() as (Reply | null)[];
        todo = todo.filter((k, j) => {
          const r = replies.find((x) => x && x.id === msgs[j].id);
          if (r && !r.error && 'result' in r) {
            out[k] = r.result;
            return false;
          }
          out[k] = new RpcError(r ? r.error : { message: 'no reply for this call' });
          return !isRevert(out[k]);
        });
        if (todo.length) cur = (cur + 1) % urls.length;
      }
    }
    return out;
  };

  const send = async (method: string, params: readonly unknown[] = []): Promise<unknown> => {
    const [r] = await batch([[method, params]]);
    if (r instanceof RpcError) throw r;
    return r;
  };

  return {
    urls,
    current: () => urls[cur],
    batch,
    send,
    call: (to, data, block = 'latest') => send('eth_call', [{ to, data }, block]) as Promise<string>,
  };
}
