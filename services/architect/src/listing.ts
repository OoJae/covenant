// The OKX.AI listing proposed for this service: every field value, and the A2MCP service JSON built from
// the deployed endpoint. Used by scripts/okx-listing.ts; kept in src/ so the tests can check it against
// the rules in the local okx-ai skill documents (service-contract.md).

import { PAID_PATH } from './paywall.ts';

export const AGENT_NAME = 'Covenant Architect';

export const AGENT_DESCRIPTION =
  'Covenant Architect compiles vault chips for IGNIX tokens on X Layer: tax-routing circuits anyone can read and ' +
  'nobody can change, delivered as TapeOut netlists with a pin manifest, proofs and a cost quote.';

export const SERVICE_NAME = 'Vault Chip Compiler';

export interface A2mcpService {
  serviceName: string;
  serviceDescription: string;
  serviceType: 'A2MCP';
  fee: string;
  endpoint: string;
}

/** "0.50" -> "0.5": a plain number as a string, no trailing zeros, at most 6 decimals. */
export function feeString(priceUsd: string): string {
  if (!/^\d{1,6}(\.\d{1,6})?$/.test(priceUsd)) throw new Error(`"${priceUsd}" is not a price with at most 6 decimals`);
  const [whole = '0', frac = ''] = priceUsd.split('.');
  const trimmed = frac.replace(/0+$/, '');
  return `${String(Number(whole))}${trimmed ? `.${trimmed}` : ''}`;
}

export function endpointOf(publicBaseUrl: string): string {
  const u = new URL(publicBaseUrl);
  if (u.protocol !== 'https:') throw new Error('OKX.AI requires a public https endpoint');
  if (/^(localhost|127\.|10\.|192\.168\.|169\.254\.)/.test(u.hostname) || u.hostname.endsWith('.local') || u.hostname.endsWith('.internal')) {
    throw new Error('OKX.AI requires a public endpoint, not a local or private address');
  }
  return `${u.origin}${u.pathname.replace(/\/+$/, '')}${PAID_PATH}`;
}

/** The request example registered with the listing. It must use the real endpoint and run as written. */
export function requestExample(endpoint: string, defaultPreset: string): string {
  return `curl -X POST ${endpoint} -H "Content-Type: application/json" -d '{"preset":"${defaultPreset}","params":{}}'`;
}

/**
 * The four numbered lines the okx-ai skill stores for an A2MCP service:
 * service description, parameter spec, request method, request example.
 */
export function serviceDescription(endpoint: string, defaultPreset: string): string {
  return [
    '1. [Service Description] Compiles a Covenant vault chip preset for an IGNIX token into a TapeOut TAP-20 netlist and returns JSON with netlistHex, the pin manifest, proof results and the tape-out cost.',
    `2. [Parameter Spec] preset(string, optional): vault chip preset name, default ${defaultPreset}; params(object, optional): preset parameters as a JSON object, default {}`,
    '3. [Request Method] POST',
    `4. [Request Example] ${requestExample(endpoint, defaultPreset)}`,
  ].join('\n');
}

export function a2mcpService(publicBaseUrl: string, priceUsd: string, defaultPreset: string): A2mcpService {
  const endpoint = endpointOf(publicBaseUrl);
  return {
    serviceName: SERVICE_NAME,
    serviceDescription: serviceDescription(endpoint, defaultPreset),
    serviceType: 'A2MCP',
    fee: feeString(priceUsd),
    endpoint,
  };
}

/** Quote a string for a POSIX shell. */
export const shq = (s: string): string => `'${s.replace(/'/g, `'\\''`)}'`;
