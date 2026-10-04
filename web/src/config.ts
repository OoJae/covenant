// Everything address-shaped the site needs. `addresses.json` is the one file to edit when
// Covenant's own processor exists: set `processor` and `probeCircuitId` and the landing page
// switches from the public examples to it.

import { createRpc } from '@covenant/chain';
import addresses from './addresses.json' with { type: 'json' };

export interface Addresses {
  /** The TapeOut processor factory on X Layer. */
  factory: string;
  /** Covenant's processor, once it has been created through the factory. */
  processor: string | null;
  /** The first circuit taped out on it. */
  probeCircuitId: number | string | null;
  /** JSON-RPC endpoints, tried in order with failover. */
  rpc: string[];
}

export const ADDR: Addresses = addresses;

export const CHAIN = { id: 196, name: 'X Layer' };

/** Block explorer page for an address. */
export const explorer = (address: string): string => `https://www.oklink.com/xlayer/address/${address}`;

export const rpc = createRpc(ADDR.rpc);

export interface Example {
  processor: string;
  id: number;
  label: string;
  note: string;
}

/**
 * Circuits other people taped out on TapeOut (X Layer), offered while `processor` is null.
 * Read from the chain on 2026-10-04; the numbers are re-read live when a page opens.
 */
export const EXAMPLES: Example[] = [
  {
    processor: '0x933FC3AA0c387CB8B6B1D22a2Ec3E2B5eeCfDb5a',
    id: 1,
    label: 'Trivium #1',
    note: '3,035 gates, 288 state bits, 161 inputs',
  },
  {
    processor: '0xAa13ae45b0B2D52f210Ad7Ef12997113a0ebAF21',
    id: 3,
    label: 'LoteGate #3',
    note: '4,863 gates, 243 state bits, 133 inputs, 199 outputs',
  },
  {
    processor: '0x839bdD6fa7A66416A609A735e11DE5411B98574e',
    id: 1,
    label: 'OnlyTestXLayer #1',
    note: '4 gates, 2 inputs, no state: small enough to check by hand',
  },
  {
    processor: '0x839bdD6fa7A66416A609A735e11DE5411B98574e',
    id: 4,
    label: 'OnlyTestXLayer #4',
    note: 'a single REF record pointing at a 10-gate circuit on another processor',
  },
];
