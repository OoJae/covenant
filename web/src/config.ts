// Everything address-shaped the site needs, from one source: deployments/xlayer.json, which the deploy scripts
// write after reading every address back from the chain. A contract appears on the site the moment that file names
// it; nothing here has to be edited by hand. `addresses.json` holds only what is not a deployment: the TapeOut
// factory, the RPC endpoints, and the id of a Glutton chip if one is ever taped out on mainnet.
//
// With COVENANT_FORK set at build or dev time (see vite.config.ts) the fork fixture's file replaces the deployment
// file and its RPC replaces the public endpoints; `SIMULATION` is then non-null and every page says so.

import { createRpc } from '@covenant/chain';
import live from '../../deployments/xlayer.json' with { type: 'json' };
import site from './addresses.json' with { type: 'json' };

/** The parts of deployments/xlayer.json the site reads. Sections appear as signing sessions complete. */
export interface Deployment {
  chainId: number;
  deployer?: string;
  keeper?: string;
  issuance?: { splitter: string; transistors: string; circuits: string; keeperTank: string; teamRegistry: string; storyKeccak256?: string; block?: number };
  probe?: { circuitId: number; gates?: number; netlistKeccak256?: string };
  evaluator?: { sealedVM: string; fab: string };
  core?: { kernelFactory: string; kernelImpl: string; lens: string };
  flagship?: { chipId: number; kernel: string; netlistKeccak256?: string };
  /** The two hostile Glutton chips, taped out through the Fab by the prelaunch step; held by the deployer. */
  prelaunch?: { gluttonChipId: number; glutton512ChipId: number; keeperInvited?: string };
  glutton?: { chipId: number };
  /** Only in the fork fixture's file. */
  fork?: { rpc: string; block: number; token: string; records: number };
}

declare const __COVENANT_FORK__: Deployment | null | undefined;
const fork: Deployment | null = typeof __COVENANT_FORK__ === 'undefined' ? null : __COVENANT_FORK__;
const dep: Deployment = fork ?? (live as Deployment);

/** Non-null when the site runs against the local fork fixture. */
export const SIMULATION = fork?.fork ?? null;

/** Every Covenant address the site knows, null until deployed. */
export const COVENANT = {
  deployer: dep.deployer ?? null,
  keeper: dep.keeper ?? null,
  processor: dep.issuance?.circuits ?? null,
  transistors: dep.issuance?.transistors ?? null,
  splitter: dep.issuance?.splitter ?? null,
  keeperTank: dep.issuance?.keeperTank ?? null,
  teamRegistry: dep.issuance?.teamRegistry ?? null,
  storyKeccak256: dep.issuance?.storyKeccak256 ?? null,
  probeCircuitId: dep.probe?.circuitId ?? null,
  sealedVM: dep.evaluator?.sealedVM ?? null,
  fab: dep.evaluator?.fab ?? null,
  kernelFactory: dep.core?.kernelFactory ?? null,
  kernelImpl: dep.core?.kernelImpl ?? null,
  lens: dep.core?.lens ?? null,
  /** The flagship chip (Flow Governor) and the kernel that holds it. */
  chipId: dep.flagship?.chipId ?? null,
  kernel: dep.flagship?.kernel ?? null,
  /** A Glutton taped out on the same processor, for Lens.shadowChip. */
  gluttonChipId: dep.prelaunch?.gluttonChipId ?? dep.glutton?.chipId ?? (site.gluttonChipId as number | null),
  /** The variant whose share groups sum to 512 (the kernel refuses the whole group). */
  glutton512ChipId: dep.prelaunch?.glutton512ChipId ?? null,
};

export interface Addresses {
  /** The TapeOut processor factory on X Layer. */
  factory: string;
  /** Covenant's processor (its Circuits contract). */
  processor: string | null;
  /** The first circuit taped out on it. */
  probeCircuitId: number | string | null;
  /** JSON-RPC endpoints, tried in order with failover. */
  rpc: string[];
}

export const ADDR: Addresses = {
  factory: site.factory,
  processor: COVENANT.processor,
  probeCircuitId: COVENANT.probeCircuitId,
  rpc: SIMULATION ? [SIMULATION.rpc] : site.rpc,
};

export const CHAIN = { id: 196, name: 'X Layer' };

/** What the pages call the chain they read: X Layer, or the fork in a simulation build. */
export const CHAIN_LABEL = SIMULATION ? 'the local fork' : 'X Layer';

/** Block explorer page for an address. */
export const explorer = (address: string): string => `https://www.oklink.com/xlayer/address/${address}`;

/** Where the printed `cast` lines point: the public endpoint, or the fork. */
export const CAST_RPC = ADDR.rpc[0];

export const rpc = createRpc(ADDR.rpc);

/** Source files are linked on the public repository. */
export const REPO = 'https://github.com/OoJae/covenant';

export interface Example {
  processor: string;
  id: number;
  label: string;
  note: string;
}

/**
 * Circuits other people taped out on TapeOut (X Layer), to show the reader on real chain data.
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
