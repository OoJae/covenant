// The self-check of OKX's A2MCP guide, as text to paste and as a function that performs it.
//
// The guide's check for a paid endpoint is one line:
//     curl -i -X POST https://your-domain/your-path      # expected: HTTP 402 + PAYMENT-REQUIRED
// The rest verifies that the challenge in that header says what this service means to charge.

import { FREE_PATH } from './app.ts';
import { NETWORK, USDT0 } from './config.ts';
import { decodePaymentRequired, mockPaymentHeader } from './mock-facilitator.ts';
import { PAID_PATH } from './paywall.ts';

export function curlSelfCheck(base: string, defaultPreset = 'flow-governor'): string {
  const b = base.replace(/\/+$/, '');
  const body = `'{"preset":"${defaultPreset}","params":{}}'`;
  return `# Covenant Architect self-check for ${b}

# 1. Liveness. Expect {"ok":true,...}; "paid.ready" must be true and "paid.mode" must be "live" before listing.
curl -s ${b}/healthz

# 2. THE OKX A2MCP SELF-CHECK (paid type). Expect: HTTP 402 and a PAYMENT-REQUIRED response header.
curl -i -X POST ${b}${PAID_PATH}

# 3. Decode the challenge. Expect x402Version 2 and one accepts entry:
#      scheme exact, network ${NETWORK}, asset ${USDT0.address} (USDT0),
#      amount = price * 1e6 (500000 for 0.50), payTo = your PAY_TO, maxTimeoutSeconds 300,
#      extra {"name":"USD₮0","version":"1"}, and resource.url = ${b}${PAID_PATH}
curl -s -o /dev/null -D - -X POST ${b}${PAID_PATH} \\
  | awk 'tolower($1)=="payment-required:"{print $2}' | tr -d '\\r' | base64 --decode; echo

# 4. The request example registered with OKX.AI. Unpaid, so again HTTP 402.
curl -i -X POST ${b}${PAID_PATH} -H "Content-Type: application/json" -d ${body}

# 5. A GET must be refused with 405 and "Allow: POST" (OKX clients probe with GET, then switch to POST).
curl -i ${b}${PAID_PATH}

# 6. The free endpoint. Expect HTTP 200 with netlistHex, manifest, proofs, cost.
curl -s -X POST ${b}${FREE_PATH} -H "Content-Type: application/json" -d ${body}

# 7. As a buyer would see it (read-only; signs nothing):
#      onchainos payment quote ${b}${PAID_PATH} --method POST
`;
}

export interface Check {
  name: string;
  ok: boolean;
  detail: string;
}

export interface CheckOptions {
  fetch?: typeof fetch;
  /** Expected values; a check is skipped when its expectation is not given. */
  payTo?: string;
  priceUsd?: string;
  /** Complete a paid call with a mock payment. Only works against X402_MODE=mock. */
  mockPay?: boolean;
}

const atomic = (priceUsd: string): string => {
  const [whole = '0', frac = ''] = priceUsd.split('.');
  return String(BigInt(whole) * 1_000_000n + BigInt(frac.padEnd(6, '0').slice(0, 6)));
};

/** Perform the self-check against a running server. Never signs or pays anything real. */
export async function runSelfCheck(base: string, options: CheckOptions = {}): Promise<Check[]> {
  const b = base.replace(/\/+$/, '');
  const doFetch = options.fetch ?? fetch;
  const checks: Check[] = [];
  const add = (name: string, ok: boolean, detail: string): void => void checks.push({ name, ok, detail });
  const local = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:|\/|$)/.test(b);

  let mode = 'unknown';
  try {
    const res = await doFetch(`${b}/healthz`);
    const doc = (await res.json()) as { ok?: boolean; paid?: { mode?: string; ready?: boolean; reasons?: string[] }; toolchain?: { mode?: string } };
    mode = doc.paid?.mode ?? 'unknown';
    add('healthz answers 200 {ok:true}', res.status === 200 && doc.ok === true, `HTTP ${res.status}`);
    add('paid route is configured', (doc.paid?.reasons ?? ['?']).length === 0, (doc.paid?.reasons ?? []).join('; ') || 'no configuration problems');
    // A public deployment must run the real toolchain and take real payments. A local one may be a stub in mock mode.
    if (!local) {
      add('toolchain is the real one', doc.toolchain?.mode === 'cli', `toolchain mode: ${doc.toolchain?.mode}`);
      add('payments are live, not mock', mode === 'live', `paid.mode: ${mode}`);
    }
  } catch (err) {
    add('healthz answers 200 {ok:true}', false, err instanceof Error ? err.message : String(err));
    return checks;
  }

  const unpaid = await doFetch(`${b}${PAID_PATH}`, { method: 'POST' });
  add('unpaid POST answers HTTP 402', unpaid.status === 402, `HTTP ${unpaid.status}`);
  const header = unpaid.headers.get('payment-required');
  add('PAYMENT-REQUIRED header is present', header !== null, header ? `${header.length} base64 characters` : 'header missing');
  if (!header) return checks;

  let challenge;
  try {
    challenge = decodePaymentRequired(header);
  } catch {
    add('challenge decodes as base64 JSON', false, 'not base64 JSON');
    return checks;
  }
  const a = challenge.accepts?.[0];
  add('x402Version is 2', challenge.x402Version === 2, `x402Version: ${challenge.x402Version}`);
  add('one payment option', challenge.accepts?.length === 1, `${challenge.accepts?.length ?? 0} option(s)`);
  if (!a) return checks;
  add('scheme exact on eip155:196', a.scheme === 'exact' && a.network === NETWORK, `${a.scheme} on ${a.network}`);
  add('asset is USDT0', a.asset.toLowerCase() === USDT0.address, a.asset);
  add('token domain is USD₮0 / 1', a.extra?.['name'] === USDT0.name && a.extra?.['version'] === USDT0.version, JSON.stringify(a.extra));
  add('maxTimeoutSeconds is 300', a.maxTimeoutSeconds === 300, String(a.maxTimeoutSeconds));
  if (options.priceUsd) add(`amount is ${options.priceUsd} USDT0`, a.amount === atomic(options.priceUsd), `amount: ${a.amount}`);
  else add('amount is positive', /^[1-9]\d*$/.test(a.amount), `amount: ${a.amount} (${Number(a.amount) / 1e6} USDT0)`);
  if (options.payTo) add('payTo is the expected address', a.payTo.toLowerCase() === options.payTo.toLowerCase(), `payTo: ${a.payTo}`);
  else add('payTo is an address', /^0x[0-9a-fA-F]{40}$/.test(a.payTo), `payTo: ${a.payTo}`);
  add('resource.url is this endpoint', challenge.resource?.url === `${b}${PAID_PATH}`, `resource.url: ${challenge.resource?.url}`);
  if (!local) add('resource.url is https', String(challenge.resource?.url).startsWith('https://'), String(challenge.resource?.url));

  const get = await doFetch(`${b}${PAID_PATH}`);
  add('GET answers 405 with Allow: POST', get.status === 405 && get.headers.get('allow') === 'POST', `HTTP ${get.status}`);

  if (options.mockPay) {
    if (mode !== 'mock') {
      add('mock-paid call', false, 'the server is not in X402_MODE=mock; a real payment is needed and this script never makes one');
    } else {
      const paid = await doFetch(`${b}${PAID_PATH}`, { method: 'POST', headers: { 'PAYMENT-SIGNATURE': mockPaymentHeader(header) } });
      const doc = (await paid.json().catch(() => ({}))) as { netlistHex?: string };
      add('mock-paid call answers 200 with a netlist', paid.status === 200 && typeof doc.netlistHex === 'string', `HTTP ${paid.status}`);
      add('mock-paid call carries PAYMENT-RESPONSE', paid.headers.get('payment-response') !== null, 'settlement receipt header');
    }
  }
  return checks;
}
