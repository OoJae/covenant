// X402_MODE=mock: a facilitator that lives in this process and never contacts OKX.
//
// The real OKX seller SDK still does everything else (route matching, building the 402 challenge, the
// PAYMENT-REQUIRED header, matching the payment against the requirements, settle-after-success), so the
// mock exercises the same code path as production up to the two network calls it replaces.
//
// It accepts exactly one kind of payment: a payload carrying MOCK_PAYMENT_MARKER. A real signed payment
// is refused, so a mock-mode server can never look as if it had been paid. Nothing moves on chain.

import type { FacilitatorClient } from '@okxweb3/x402-core/server';
import type {
  Network,
  PaymentPayload,
  PaymentRequired,
  PaymentRequirements,
  SettleResponse,
  SupportedResponse,
  VerifyResponse,
} from '@okxweb3/x402-core/types';

export const MOCK_PAYMENT_MARKER = 'covenant-mock-payment';
/** The "payer" reported for mock payments. Not a wallet anyone controls. */
export const MOCK_PAYER = '0x00000000000000000000000000000000000000Aa';

export interface MockSettlement {
  payTo: string;
  amount: string;
  asset: string;
  network: string;
  transaction: string;
}

export class MockFacilitatorClient implements FacilitatorClient {
  readonly network: Network;
  readonly calls = { supported: 0, verify: 0, settle: 0 };
  readonly settlements: MockSettlement[] = [];
  /** Test hook: make the next settle calls fail the way a facilitator would report a failed transfer. */
  failNextSettles = 0;

  constructor(network: Network) {
    this.network = network;
  }

  async getSupported(): Promise<SupportedResponse> {
    this.calls.supported += 1;
    return { kinds: [{ x402Version: 2, scheme: 'exact', network: this.network }], extensions: [], signers: {} };
  }

  async verify(payload: PaymentPayload, _requirements: PaymentRequirements): Promise<VerifyResponse> {
    this.calls.verify += 1;
    if (payload?.payload?.['mock'] === MOCK_PAYMENT_MARKER) return { isValid: true, payer: MOCK_PAYER };
    return {
      isValid: false,
      invalidReason: 'mock_mode',
      invalidMessage: 'This server runs with X402_MODE=mock and accepts only mock payments. No real payment was taken.',
    };
  }

  async settle(_payload: PaymentPayload, requirements: PaymentRequirements): Promise<SettleResponse> {
    this.calls.settle += 1;
    if (this.failNextSettles > 0) {
      this.failNextSettles -= 1;
      return { success: false, errorReason: 'mock_settle_failed', transaction: '', network: requirements.network, payer: MOCK_PAYER };
    }
    // Deliberately not shaped like a transaction hash.
    const transaction = `MOCK-NOT-A-TRANSACTION-${this.calls.settle}`;
    this.settlements.push({
      payTo: requirements.payTo,
      amount: requirements.amount,
      asset: requirements.asset,
      network: requirements.network,
      transaction,
    });
    return {
      success: true,
      status: 'success',
      transaction,
      network: requirements.network,
      payer: MOCK_PAYER,
      amount: requirements.amount,
      extensions: { covenantMock: true },
    };
  }
}

/** Decode the base64 PAYMENT-REQUIRED header of a 402 response. */
export function decodePaymentRequired(header: string): PaymentRequired {
  return JSON.parse(Buffer.from(header, 'base64').toString('utf8')) as PaymentRequired;
}

/**
 * Build the PAYMENT-SIGNATURE header value a mock-mode server accepts, from the PAYMENT-REQUIRED header
 * it sent. Used by the tests and by scripts/selfcheck.ts.
 */
export function mockPaymentHeader(paymentRequiredHeader: string, index = 0): string {
  const required = decodePaymentRequired(paymentRequiredHeader);
  const accepted = required.accepts[index];
  if (!accepted) throw new Error(`the challenge has no accepts[${index}]`);
  const payload: PaymentPayload = {
    x402Version: required.x402Version,
    resource: required.resource,
    accepted,
    payload: { mock: MOCK_PAYMENT_MARKER },
  };
  return Buffer.from(JSON.stringify(payload), 'utf8').toString('base64');
}
