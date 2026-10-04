// The x402 paywall of POST /v1/architect/chip, built on OKX's seller SDK:
//
//   @okxweb3/x402-hono   paymentMiddlewareFromHTTPServer, x402ResourceServer, x402HTTPResourceServer
//   @okxweb3/x402-evm    ExactEvmScheme (exact scheme, EIP-3009 transferWithAuthorization)
//   @okxweb3/x402-core   OKXFacilitatorClient (HMAC-signed calls to OKX: supported, verify, settle)
//
// What the SDK does, read from its source (x402-hono 0.1.1, dist/esm/index.mjs):
//   - no PAYMENT-SIGNATURE header  -> 402, challenge base64-encoded in the PAYMENT-REQUIRED header, body {}
//   - header present               -> verify with the facilitator, then run the route handler
//   - handler answered >= 400      -> nothing is settled: a failed compile is not charged
//   - handler answered < 400       -> settle; on success add PAYMENT-RESPONSE; on failure the handler's
//                                     response is REPLACED by a 402, so nothing is delivered unpaid
//
// What this file adds:
//   - fail closed: without credentials, payee or a real toolchain the route answers 503 with the reasons;
//   - the facilitator handshake (GET supported kinds) is done here, with retries, instead of by the SDK:
//     the SDK starts it eagerly and an early failure would be an unhandled rejection;
//   - when OKX reports a settlement timeout, the transfer is looked up on chain before the buyer is refused;
//   - X402_MODE=mock swaps the facilitator for an in-process one (mock-facilitator.ts).

import { OKXFacilitatorClient } from '@okxweb3/x402-core';
import type { FacilitatorClient, RoutesConfig } from '@okxweb3/x402-core/server';
import { ExactEvmScheme } from '@okxweb3/x402-evm/exact/server';
import { paymentMiddlewareFromHTTPServer, x402HTTPResourceServer, x402ResourceServer } from '@okxweb3/x402-hono';
import type { MiddlewareHandler } from 'hono';
import type { PaidConfig } from './config.ts';
import type { Logger } from './log.ts';
import { MockFacilitatorClient } from './mock-facilitator.ts';

export const PAID_ROUTE = 'POST /v1/architect/chip';
export const PAID_PATH = '/v1/architect/chip';

const DESCRIPTION =
  'Covenant Architect: compile a vault chip preset into a TAP-20 netlist with its pin manifest, proofs and cost.';

/** keccak256("Transfer(address,address,uint256)") */
const TRANSFER_TOPIC = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';

export interface PaywallStatus {
  mode: 'live' | 'mock';
  /** Configuration is complete and the facilitator has answered. */
  ready: boolean;
  /** Configuration problems. Variable names only, never values. */
  reasons: string[];
  facilitator: 'not_contacted' | 'ok' | 'unavailable';
  facilitatorError: string | null;
}

export interface Paywall {
  status(): PaywallStatus;
  /** 503 unless the route can sell. Must run before `payment`. */
  guard: MiddlewareHandler;
  /** The SDK's middleware: 402 challenge, verification, settlement after a successful handler. */
  payment: MiddlewareHandler;
  /** Start the facilitator handshake in the background (called once at boot). */
  warmUp(): void;
  /** Present in mock mode. */
  mock: MockFacilitatorClient | null;
}

export interface PaywallDeps {
  log: Logger;
  /** https://host of the public deployment; the challenge's resource.url is built from it. */
  publicBaseUrl: string | null;
  /** Replace the facilitator (tests). */
  facilitator?: FacilitatorClient;
  fetch?: typeof fetch;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  /** Minimum time between two handshake attempts after a failure. */
  retryAfterMs?: number;
}

export function buildRoutes(config: PaidConfig, publicBaseUrl: string | null): RoutesConfig {
  if (config.payTo === null) throw new Error('buildRoutes needs a payee');
  return {
    [PAID_ROUTE]: {
      accepts: {
        scheme: 'exact',
        network: config.network,
        payTo: config.payTo,
        // An explicit amount and asset rather than "$0.50": no float parsing, and the token is stated here
        // rather than taken from the SDK's default table. A test pins that both forms agree.
        price: {
          amount: config.amount,
          asset: config.asset.address,
          extra: { name: config.asset.name, version: config.asset.version },
        },
        maxTimeoutSeconds: config.maxTimeoutSeconds,
      },
      description: DESCRIPTION,
      mimeType: 'application/json',
      // Behind a proxy the request URL is http://; the marketplace expects the real public https URL.
      ...(publicBaseUrl ? { resource: `${publicBaseUrl}${PAID_PATH}` } : {}),
    },
  };
}

interface RpcReceipt {
  status?: string;
  logs?: Array<{ address?: string; topics?: string[]; data?: string }>;
}

/**
 * Was this settlement mined? Looks for the token's Transfer to the payee of at least the price in the
 * transaction's receipt. Used only when the facilitator says "timeout".
 */
export async function confirmTransferOnChain(
  txHash: string,
  config: Pick<PaidConfig, 'rpcUrls' | 'asset' | 'payTo' | 'amount'>,
  options: { fetch?: typeof fetch; sleep?: (ms: number) => Promise<void>; attempts?: number; delayMs?: number } = {},
): Promise<boolean> {
  if (!/^0x[0-9a-fA-F]{64}$/.test(txHash) || config.payTo === null) return false;
  const doFetch = options.fetch ?? fetch;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const attempts = options.attempts ?? 10;
  const payTo = config.payTo.toLowerCase().slice(2);
  const asset = config.asset.address.toLowerCase();
  const price = BigInt(config.amount);

  for (let i = 0; i < attempts; i++) {
    for (const url of config.rpcUrls) {
      try {
        const res = await doFetch(url, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_getTransactionReceipt', params: [txHash] }),
          signal: AbortSignal.timeout(8000),
        });
        if (!res.ok) continue;
        const receipt = ((await res.json()) as { result?: RpcReceipt | null }).result;
        if (!receipt) continue;
        if (receipt.status !== '0x1') return false;
        return (receipt.logs ?? []).some(
          (l) =>
            l.address?.toLowerCase() === asset &&
            l.topics?.[0] === TRANSFER_TOPIC &&
            l.topics?.[2]?.toLowerCase().endsWith(payTo) === true &&
            typeof l.data === 'string' &&
            /^0x[0-9a-fA-F]{1,64}$/.test(l.data) &&
            BigInt(l.data) >= price,
        );
      } catch {
        // try the next endpoint
      }
    }
    if (i < attempts - 1) await sleep(options.delayMs ?? 2000);
  }
  return false;
}

const errorText = (err: unknown): string => {
  const e = err instanceof Error ? err : new Error(String(err));
  const cause = e.cause instanceof Error ? `: ${e.cause.message}` : '';
  return `${e.message}${cause}`.slice(0, 300);
};

export function createPaywall(config: PaidConfig, deps: PaywallDeps): Paywall {
  const { log } = deps;
  const now = deps.now ?? Date.now;
  const retryAfterMs = deps.retryAfterMs ?? 5000;
  const reasons = [...config.reasons];

  // Not able to sell: no SDK objects are created at all, and both middlewares refuse.
  if (reasons.length > 0 || config.payTo === null) {
    if (reasons.length === 0) reasons.push('PAY_TO is not set');
    const refuse: MiddlewareHandler = async (c) => {
      c.header('X-Covenant-X402-Mode', config.mode);
      return c.json(
        {
          error: {
            code: 'paid_endpoint_unavailable',
            message: 'The paid endpoint is not configured on this server. Nothing was charged.',
            reasons,
          },
        },
        503,
      );
    };
    return {
      status: () => ({ mode: config.mode, ready: false, reasons, facilitator: 'not_contacted', facilitatorError: null }),
      guard: refuse,
      payment: refuse,
      warmUp: () => {},
      mock: null,
    };
  }

  const mock = config.mode === 'mock' && !deps.facilitator ? new MockFacilitatorClient(config.network) : null;
  let facilitator: FacilitatorClient;
  if (deps.facilitator) facilitator = deps.facilitator;
  else if (mock) facilitator = mock;
  else if (config.okx) {
    facilitator = new OKXFacilitatorClient({
      apiKey: config.okx.apiKey,
      secretKey: config.okx.secretKey,
      passphrase: config.okx.passphrase,
      ...(config.okx.baseUrl ? { baseUrl: config.okx.baseUrl } : {}),
      // In the SDK this is a property of the facilitator client, not of the route.
      syncSettle: config.syncSettle,
    });
  } else {
    throw new Error('createPaywall: live mode without credentials should have been caught by config.reasons');
  }

  const resourceServer = new x402ResourceServer(facilitator).register(config.network, new ExactEvmScheme());
  resourceServer.onAfterSettle(async (ctx) => {
    log.info('payment_settled', {
      mode: config.mode,
      success: ctx.result.success,
      status: ctx.result.status ?? null,
      transaction: ctx.result.transaction,
      payer: ctx.result.payer ?? null,
      amount: ctx.requirements.amount,
      payTo: ctx.requirements.payTo,
      errorReason: ctx.result.errorReason ?? null,
    });
  });
  resourceServer.onSettleFailure(async (ctx) => {
    log.error('payment_settle_failed', { mode: config.mode, error: errorText(ctx.error) });
  });
  resourceServer.onVerifyFailure(async (ctx) => {
    log.warn('payment_verify_failed', { mode: config.mode, error: errorText(ctx.error) });
  });

  const httpServer = new x402HTTPResourceServer(resourceServer, buildRoutes(config, deps.publicBaseUrl));
  httpServer.setPollDeadline(config.settlePollMs);
  if (config.mode === 'live') {
    httpServer.onSettlementTimeout(async (txHash) => {
      const confirmed = await confirmTransferOnChain(txHash, config, { fetch: deps.fetch, sleep: deps.sleep });
      log.warn('payment_settlement_timeout', { transaction: txHash, confirmedOnChain: confirmed });
      return { confirmed };
    });
  }

  // syncFacilitatorOnStart = false: the handshake is done by ensureReady() below.
  const payment = paymentMiddlewareFromHTTPServer(httpServer, undefined, undefined, false);

  let state: 'not_contacted' | 'ok' | 'unavailable' = 'not_contacted';
  let lastError: string | null = null;
  let lastAttempt = 0;
  let pending: Promise<boolean> | null = null;

  const ensureReady = (): Promise<boolean> => {
    if (state === 'ok') return Promise.resolve(true);
    if (pending) return pending;
    if (state === 'unavailable' && now() - lastAttempt < retryAfterMs) return Promise.resolve(false);
    lastAttempt = now();
    pending = httpServer
      .initialize()
      .then(
        () => {
          state = 'ok';
          lastError = null;
          log.info('paywall_ready', { mode: config.mode });
          return true;
        },
        (err: unknown) => {
          state = 'unavailable';
          lastError = errorText(err);
          log.error('paywall_facilitator_unavailable', { mode: config.mode, error: lastError });
          return false;
        },
      )
      .finally(() => {
        pending = null;
      });
    return pending;
  };

  const guard: MiddlewareHandler = async (c, next) => {
    if (!(await ensureReady())) {
      c.header('Retry-After', '10');
      c.header('X-Covenant-X402-Mode', config.mode);
      return c.json(
        {
          error: {
            code: 'facilitator_unavailable',
            message: 'The payment facilitator could not be reached or refused the credentials. Nothing was charged.',
          },
        },
        503,
      );
    }
    await next();
    // Stamp every answer of the paid route, so that a mock deployment can never pass for a live one.
    c.header('X-Covenant-X402-Mode', config.mode);
  };

  return {
    status: () => ({ mode: config.mode, ready: state === 'ok', reasons: [], facilitator: state, facilitatorError: lastError }),
    guard,
    payment,
    warmUp: () => void ensureReady(),
    mock,
  };
}
