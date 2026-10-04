// The HTTP surface. Everything it needs is passed in, so the tests drive it with app.request().
//
//   GET  /healthz                 liveness and a summary of what is configured (no secrets)
//   POST /v1/architect/compile    free; rate-limited per client address; small body
//   POST /v1/architect/chip       the same compile behind the x402 paywall
//
// Order on the paid route, and why:
//   1. guard        503 when the route cannot sell (no credentials, no payee, stub toolchain, facilitator down)
//   2. rate limit   bounds how often one client can make us call the facilitator
//   3. body limit, parse   a non-empty malformed body is a 400 BEFORE any payment is asked for
//   4. payment      402 challenge, or verification of the payment (OKX SDK)
//   5. handler      compile. Any answer >= 400 is not settled, so a failed compile is not charged.

import { Hono } from 'hono';
import type { Context, MiddlewareHandler } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { cors } from 'hono/cors';
import { CompileCache, requestKey } from './cache.ts';
import { describe } from './config.ts';
import type { Config } from './config.ts';
import type { Logger } from './log.ts';
import { PAID_PATH } from './paywall.ts';
import type { Paywall } from './paywall.ts';
import { RateLimiter, clientAddress } from './ratelimit.ts';
import { parameterSpec, parseCompileRequest } from './request.ts';
import type { CompileRequest } from './request.ts';
import { CompileRejected, ToolchainError } from './toolchain.ts';
import type { CompileResult, ToolchainMode } from './toolchain.ts';

export const VERSION = '0.1.0';
export const FREE_PATH = '/v1/architect/compile';

export interface AppDeps {
  config: Config;
  log: Logger;
  /** The toolchain adapter: compilePreset(preset, params). */
  compile: (preset: string, params: Record<string, unknown>) => Promise<CompileResult>;
  toolchainMode: ToolchainMode;
  paywall: Paywall;
  /** The socket's remote address, when the runtime can tell. */
  socketAddress?: (c: Context) => string | undefined;
  now?: () => number;
}

type Env = { Variables: { compileRequest: CompileRequest } };

const errorBody = (code: string, message: string, extra: Record<string, unknown> = {}): Record<string, unknown> => ({
  error: { code, message, ...extra },
});

export function createApp(deps: AppDeps): Hono<Env> {
  const { config, log, paywall } = deps;
  const now = deps.now ?? Date.now;
  const started = now();
  const socketAddress = deps.socketAddress ?? (() => undefined);
  const app = new Hono<Env>();

  const freeLimiter = new RateLimiter(config.freeRatePerMinute, 60_000, now);
  const paidLimiter = new RateLimiter(config.paidRatePerMinute, 60_000, now);
  const cache = new CompileCache(config.compileCacheEntries);
  /** Toolchain runs in progress. Cache hits and requests that join a run do not count. */
  let running = 0;

  app.use(
    '*',
    cors({
      origin: config.corsOrigins,
      allowMethods: ['GET', 'POST', 'OPTIONS'],
      allowHeaders: ['Content-Type', 'PAYMENT-SIGNATURE', 'X-PAYMENT'],
      exposeHeaders: [
        'PAYMENT-REQUIRED',
        'PAYMENT-RESPONSE',
        'Retry-After',
        'RateLimit-Limit',
        'RateLimit-Remaining',
        'RateLimit-Reset',
        'X-Covenant-Toolchain',
        'X-Covenant-Cache',
        'X-Covenant-X402-Mode',
      ],
      maxAge: 600,
    }),
  );

  const rateLimit =
    (limiter: RateLimiter): MiddlewareHandler<Env> =>
    async (c, next) => {
      const d = limiter.take(clientAddress(c, config.trustProxy, socketAddress));
      c.header('RateLimit-Limit', String(d.limit));
      c.header('RateLimit-Remaining', String(d.remaining));
      c.header('RateLimit-Reset', String(d.resetSeconds));
      if (!d.allowed) {
        c.header('Retry-After', String(d.resetSeconds));
        return c.json(
          errorBody('rate_limited', `Too many requests. Try again in ${d.resetSeconds} s.`, { retryAfterSeconds: d.resetSeconds }),
          429,
        );
      }
      await next();
    };

  const limitBody = bodyLimit({
    maxSize: config.bodyLimitBytes,
    onError: (c) => c.json(errorBody('body_too_large', `The request body may not exceed ${config.bodyLimitBytes} bytes.`), 413),
  });

  const parseBody: MiddlewareHandler<Env> = async (c, next) => {
    const parsed = parseCompileRequest(await c.req.text(), config.defaultPreset);
    if (!parsed.ok) {
      return c.json({ ...errorBody(parsed.code, parsed.message), ...parameterSpec(config.defaultPreset) }, 400);
    }
    c.set('compileRequest', parsed.request);
    await next();
  };

  const compile =
    (route: 'free' | 'paid') =>
    async (c: Context<Env>): Promise<Response> => {
      const request = c.get('compileRequest');
      const key = requestKey(request.preset, request.params);
      const t0 = now();

      const respond = (result: CompileResult, cached: 'hit' | 'miss'): Response => {
        log.info('compile', {
          route,
          preset: request.preset,
          ok: true,
          cache: cached,
          stub: result.stub === true,
          netlistBytes: (result.netlistHex.length - 2) / 2,
          ms: now() - t0,
        });
        c.header('X-Covenant-Toolchain', deps.toolchainMode);
        c.header('X-Covenant-Cache', cached);
        return c.json(result, 200);
      };

      const hit = cache.get(key);
      if (hit) return respond(hit, 'hit');

      // An identical request is already compiling: wait for it instead of starting a second run.
      let run = cache.inflight.get(key);
      if (!run) {
        if (running >= config.maxConcurrentCompiles) {
          c.header('Retry-After', '5');
          return c.json(errorBody('busy', 'The compiler is busy. Try again in a few seconds. Nothing was charged.'), 503);
        }
        running += 1;
        // Started inside a promise chain, so that even a synchronous throw releases the slot.
        run = Promise.resolve()
          .then(() => deps.compile(request.preset, request.params))
          .finally(() => {
            running -= 1;
            cache.inflight.delete(key);
          });
        cache.inflight.set(key, run);
      }

      try {
        const result = await run;
        // The stub is free to produce and echoes the request; only real compiles are worth keeping.
        if (result.stub !== true) cache.set(key, result);
        return respond(result, 'miss');
      } catch (err) {
        const ms = now() - t0;
        if (err instanceof CompileRejected) {
          log.info('compile', { route, preset: request.preset, ok: false, code: err.code, stage: err.stage, ms });
          return c.json(
            errorBody(err.code, err.message, {
              stage: err.stage,
              diagnostics: err.diagnostics,
              ...(err.proofs ? { proofs: err.proofs } : {}),
              charged: false,
            }),
            422,
          );
        }
        if (err instanceof ToolchainError) {
          log.error('compile_toolchain_fault', { route, preset: request.preset, kind: err.kind, error: err.message, stderr: err.stderrTail, ms });
          const status = err.kind === 'timeout' ? 504 : 502;
          return c.json(errorBody(`toolchain_${err.kind}`, 'The chip toolchain failed. Nothing was charged.', { charged: false }), status);
        }
        throw err;
      }
    };

  const methodNotAllowed = (c: Context<Env>): Response => {
    c.header('Allow', 'POST');
    return c.json(errorBody('method_not_allowed', 'Use POST.'), 405);
  };

  app.get('/', (c) =>
    c.json({
      service: 'covenant-architect',
      version: VERSION,
      endpoints: {
        'GET /healthz': 'liveness and configuration summary',
        [`POST ${FREE_PATH}`]: 'compile a vault chip preset (free, rate-limited). Body: {"preset": string, "params": object}',
        [`POST ${PAID_PATH}`]: 'the same compile, paid per call with x402 (USDT0 on X Layer)',
      },
    }),
  );

  app.get('/healthz', (c) => {
    const p = paywall.status();
    const summary = describe(config) as { paid: Record<string, unknown> };
    return c.json({
      ok: true,
      service: 'covenant-architect',
      version: VERSION,
      time: new Date(now()).toISOString(),
      uptimeSeconds: Math.floor((now() - started) / 1000),
      toolchain: { mode: deps.toolchainMode },
      paid: { ...summary.paid, ready: p.ready, reasons: p.reasons, facilitator: p.facilitator },
    });
  });

  app.post(FREE_PATH, rateLimit(freeLimiter), limitBody, parseBody, compile('free'));
  app.on(['GET', 'PUT', 'PATCH', 'DELETE'], FREE_PATH, methodNotAllowed);

  app.post(PAID_PATH, paywall.guard, rateLimit(paidLimiter), limitBody, parseBody, paywall.payment, compile('paid'));
  // OKX's client probes with GET first and switches to POST on a 405.
  app.on(['GET', 'PUT', 'PATCH', 'DELETE'], PAID_PATH, methodNotAllowed);

  app.notFound((c) => c.json(errorBody('not_found', 'No such endpoint.'), 404));

  app.onError((err, c) => {
    log.error('unhandled_error', { path: c.req.path, error: err instanceof Error ? `${err.name}: ${err.message}` : String(err) });
    return c.json(errorBody('internal_error', 'Internal error. Nothing was charged.'), 500);
  });

  return app;
}
