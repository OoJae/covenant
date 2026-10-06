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
//   - when OKX reports a settlement timeout, the transfer is looked up on chain before the buyer is refused: it
//     counts only if USD₮0 executed an EIP-3009 authorization for it (AuthorizationUsed by the Transfer's sender,
//     and the payer and nonce of this payment when they are known), not any USD₮0 that reached PAY_TO;
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
/** keccak256("AuthorizationUsed(address,bytes32)"): emitted by USD₮0 for every EIP-3009 authorization it executes. */
const AUTHORIZATION_USED_TOPIC = '0x98de503528ee59b575ef0c0a2576a82497bfc029a5685b209e9ec333479b10a5';

/** The EIP-3009 authorization a settlement executes, when the payment payload carried a well-formed one. */
export interface ExpectedAuthorization {
  /** lower-case 0x address of the payer, or null when unknown */
  from: string | null;
  /** lower-case 0x bytes32 nonce, or null when unknown */
  nonce: string | null;
}

const UNKNOWN_AUTHORIZATION: ExpectedAuthorization = { from: null, nonce: null };

/** The payer and nonce of an exact-scheme payment payload (payload.authorization of EIP-3009). */
export function authorizationOf(paymentPayload: unknown): ExpectedAuthorization {
  const a = (paymentPayload as { payload?: { authorization?: { from?: unknown; nonce?: unknown } } } | null)?.payload
    ?.authorization;
  const from = typeof a?.from === 'string' && /^0x[0-9a-fA-F]{40}$/.test(a.from) ? a.from.toLowerCase() : null;
  const nonce = typeof a?.nonce === 'string' && /^0x[0-9a-fA-F]{64}$/.test(a.nonce) ? a.nonce.toLowerCase() : null;
  return { from, nonce };
}

/**
 * The facilitator, unchanged, except that it remembers which authorization each settlement transaction it reports
 * was executing, so that a settlement timeout can be checked against that payment's payer and nonce. Bounded.
 */
export function rememberingSettlements(
  inner: FacilitatorClient,
  seen: Map<string, ExpectedAuthorization>,
  max = 1000,
): FacilitatorClient {
  const wrapped: FacilitatorClient = {
    verify: (payload, requirements) => inner.verify(payload, requirements),
    getSupported: () => inner.getSupported(),
    settle: async (payload, requirements) => {
      const result = await inner.settle(payload, requirements);
      const tx = typeof result.transaction === 'string' ? result.transaction.toLowerCase() : '';
      if (/^0x[0-9a-f]{64}$/.test(tx)) {
        seen.set(tx, authorizationOf(payload));
        while (seen.size > max) {
          const oldest = seen.keys().next().value;
          if (oldest === undefined) break;
          seen.delete(oldest);
        }
      }
      return result;
    },
  };
  if (inner.getSettleStatus) wrapped.getSettleStatus = (txHash) => inner.getSettleStatus!(txHash);
  return wrapped;
}

/** The address in an indexed address topic, lower case, or null if the topic is not one. */
const topicAddress = (topic: string | undefined): string | null =>
  typeof topic === 'string' && /^0x0{24}[0-9a-fA-F]{40}$/.test(topic) ? `0x${topic.slice(26).toLowerCase()}` : null;

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
 * Was this settlement mined? Looks in the transaction's receipt for the token's Transfer to the payee of at least
 * the price whose sender is the authorizer of an AuthorizationUsed log of the same token in the same transaction:
 * the transfer an EIP-3009 authorization executed. A Transfer to the payee that no authorization executed (when the
 * payee is a contract that also receives other USD₮0, such as a Covenant kernel's vault claim) does not count. When
 * the payment's authorization is known, its payer and nonce must be the ones on chain. Used only when the
 * facilitator says "timeout".
 */
export async function confirmTransferOnChain(
  txHash: string,
  config: Pick<PaidConfig, 'rpcUrls' | 'asset' | 'payTo' | 'amount'>,
  options: { fetch?: typeof fetch; sleep?: (ms: number) => Promise<void>; attempts?: number; delayMs?: number } = {},
  expected: ExpectedAuthorization = UNKNOWN_AUTHORIZATION,
): Promise<boolean> {
  if (!/^0x[0-9a-fA-F]{64}$/.test(txHash) || config.payTo === null) return false;
  const doFetch = options.fetch ?? fetch;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const attempts = options.attempts ?? 10;
  const payTo = config.payTo.toLowerCase().slice(2);
  const expectedFrom = expected.from?.toLowerCase() ?? null;
  const expectedNonce = expected.nonce?.toLowerCase() ?? null;
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
        const tokenLogs = (receipt.logs ?? []).filter((l) => l.address?.toLowerCase() === asset);
        const authorizers = new Set(
          tokenLogs
            .filter(
              (l) =>
                l.topics?.[0] === AUTHORIZATION_USED_TOPIC &&
                (expectedNonce === null || l.topics?.[2]?.toLowerCase() === expectedNonce),
            )
            .map((l) => topicAddress(l.topics?.[1]))
            .filter((a): a is string => a !== null),
        );
        return tokenLogs.some((l) => {
          const sender = topicAddress(l.topics?.[1]);
          return (
            l.topics?.[0] === TRANSFER_TOPIC &&
            sender !== null &&
            authorizers.has(sender) &&
            (expectedFrom === null || sender === expectedFrom) &&
            topicAddress(l.topics?.[2]) === `0x${payTo}` &&
            typeof l.data === 'string' &&
            /^0x[0-9a-fA-F]{1,64}$/.test(l.data) &&
            BigInt(l.data) >= price
          );
        });
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

  // Which authorization each reported settlement transaction executed (for the timeout check below).
  const authorizations = new Map<string, ExpectedAuthorization>();
  facilitator = rememberingSettlements(facilitator, authorizations);

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
      const key = txHash.toLowerCase();
      const expected = authorizations.get(key) ?? UNKNOWN_AUTHORIZATION;
      authorizations.delete(key);
      const confirmed = await confirmTransferOnChain(txHash, config, { fetch: deps.fetch, sleep: deps.sleep }, expected);
      log.warn('payment_settlement_timeout', {
        transaction: txHash,
        confirmedOnChain: confirmed,
        payerKnown: expected.from !== null,
      });
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
