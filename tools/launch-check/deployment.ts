// A Covenant deployment file, in either of the two formats the repository writes:
//
//   NESTED  deployments/xlayer.json, the record of the real mainnet signing sessions:
//           { "chainId": 196, "deployer": "0x..", "keeper": "0x..", "architect": { "agentWallet": "0x..", ... },
//             "issuance":  { "splitter", "circuits", "transistors", "keeperTank", "teamRegistry", ... },   session 1
//             "probe":     { "circuitId", ... },                                                           session 1
//             "evaluator": { "sealedVM", "fab", "txs" },                                                   session 2
//             "core":      { "kernelFactory", "kernelImpl", "lens", "txs" },                               session 2
//             "flagship":  { "chipId", "kernel", "netlistKeccak256", "manifestHash", "allowancePayee", ... } }
//           deploy/launch-kernel.sh adds evaluator, core and flagship when signing session 2 is done.
//   FLAT    deploy/rehearsal.json, what deploy/rehearse.sh writes after rehearsing on a local fork:
//           { "deployer", "splitter", "circuits", "transistors", "keeperTank", "teamRegistry", "sealedVM", "fab",
//             "kernelFactory", "kernelImpl", "lens", "chipId", "kernel", ... }
//
// Both files are written by scripts that may gain keys, so keys this module does not use are ignored. Every key it
// does use must hold the right type: an address string (or null / absent), a whole number for chipId, 196 for
// chainId. Whatever needs an absent address then reports that it cannot be checked; `missingParts` names the
// parts of signing session 2 that are absent, which launch-check and simulate refuse to work without.

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { parseAddress } from './hex.ts';

export interface Deployment {
  /** Where the file was read from (for messages). */
  source: string;
  format: 'nested' | 'flat';
  deployer: string | null;
  /** The keeper wallet (nested format only). */
  keeper: string | null;
  /** The Covenant Architect's OKX.AI agent wallet (`architect.agentWallet`, nested format only). */
  agentWallet: string | null;
  splitter: string | null;
  circuits: string | null;
  transistors: string | null;
  keeperTank: string | null;
  teamRegistry: string | null;
  sealedVM: string | null;
  fab: string | null;
  kernelFactory: string | null;
  kernelImpl: string | null;
  lens: string | null;
  kernel: string | null;
  /** The kernel's chip in `circuits`, or null. */
  chipId: bigint | null;
}

export class DeploymentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'DeploymentError';
  }
}

export const DEPLOYMENT_ADDRESS_KEYS = ['deployer', 'keeper', 'agentWallet', 'splitter', 'circuits', 'transistors', 'keeperTank', 'teamRegistry', 'sealedVM', 'fab', 'kernelFactory', 'kernelImpl', 'lens', 'kernel'] as const;
type AddressKey = (typeof DEPLOYMENT_ADDRESS_KEYS)[number];

/** Where each address sits in the nested format. */
const NESTED: Record<AddressKey, readonly [section: string | null, key: string]> = {
  deployer: [null, 'deployer'],
  keeper: [null, 'keeper'],
  agentWallet: ['architect', 'agentWallet'],
  splitter: ['issuance', 'splitter'],
  circuits: ['issuance', 'circuits'],
  transistors: ['issuance', 'transistors'],
  keeperTank: ['issuance', 'keeperTank'],
  teamRegistry: ['issuance', 'teamRegistry'],
  sealedVM: ['evaluator', 'sealedVM'],
  fab: ['evaluator', 'fab'],
  kernelFactory: ['core', 'kernelFactory'],
  kernelImpl: ['core', 'kernelImpl'],
  lens: ['core', 'lens'],
  kernel: ['flagship', 'kernel'],
};

/** The parts of signing session 2, and the addresses each one must provide. */
export const SESSION_TWO = [
  { part: 'evaluator', what: 'the SealedVM and the Fab', keys: ['sealedVM', 'fab'] },
  { part: 'core', what: 'the KernelFactory and the Lens', keys: ['kernelFactory', 'lens'] },
  { part: 'flagship', what: 'the flagship chip and its kernel', keys: ['kernel', 'chipId'] },
] as const;

const isObject = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === 'object' && !Array.isArray(v);

export function parseDeployment(text: string, where: string = 'deployment file'): Deployment {
  let o: unknown;
  try {
    o = JSON.parse(text);
  } catch (e) {
    throw new DeploymentError(`${where}: not valid JSON (${(e as Error).message})`);
  }
  if (!isObject(o)) throw new DeploymentError(`${where}: must be a JSON object`);
  if (o.chainId !== undefined && o.chainId !== 196) throw new DeploymentError(`${where}: chainId is ${JSON.stringify(o.chainId)}, not 196 (X Layer)`);
  const nested = ['issuance', 'probe', 'evaluator', 'core', 'flagship', 'architect'].some((k) => isObject(o[k]));
  const out: Deployment = {
    source: where,
    format: nested ? 'nested' : 'flat',
    deployer: null,
    keeper: null,
    agentWallet: null,
    splitter: null,
    circuits: null,
    transistors: null,
    keeperTank: null,
    teamRegistry: null,
    sealedVM: null,
    fab: null,
    kernelFactory: null,
    kernelImpl: null,
    lens: null,
    kernel: null,
    chipId: null,
  };
  const sectionOf = (name: string | null): Record<string, unknown> => {
    if (name === null) return o;
    const s = o[name];
    if (s === undefined || s === null) return {};
    if (!isObject(s)) throw new DeploymentError(`${where}: ${name} must be an object`);
    return s;
  };
  for (const k of DEPLOYMENT_ADDRESS_KEYS) {
    const [section, key] = nested ? NESTED[k] : [null, k];
    const v = sectionOf(section)[key];
    const what = section ? `${section}.${key}` : key;
    if (v === undefined || v === null) continue;
    if (typeof v !== 'string') throw new DeploymentError(`${where}: ${what} must be an address string or null`);
    try {
      out[k] = parseAddress(v, what);
    } catch (e) {
      throw new DeploymentError(`${where}: ${(e as Error).message}`);
    }
  }
  const id = sectionOf(nested ? 'flagship' : null).chipId;
  if (id !== undefined && id !== null) {
    if (!(typeof id === 'number' && Number.isSafeInteger(id) && id >= 0) && !(typeof id === 'string' && /^[0-9]+$/.test(id))) {
      throw new DeploymentError(`${where}: ${nested ? 'flagship.' : ''}chipId must be a whole number or null`);
    }
    out.chipId = BigInt(id);
  }
  if (out.kernel !== null && out.chipId === null) throw new DeploymentError(`${where}: names a kernel but not its chipId`);
  return out;
}

/** The parts of signing session 2 the file does not record (empty when it is complete). */
export function missingParts(d: Deployment): (typeof SESSION_TWO)[number][] {
  return SESSION_TWO.filter((s) => s.keys.some((k) => d[k] === null));
}

/** The refusal printed when session 2 is not (completely) recorded, or null when it is. */
export function sessionTwoRefusal(d: Deployment): string | null {
  const missing = missingParts(d);
  if (!missing.length) return null;
  return (
    `signing session 2 is not deployed yet: ${d.source} records no ${missing.map((m) => `${m.part} (${m.what})`).join(', ')}. ` +
    'There is no kernel to launch against until deploy/launch-kernel.sh has run and recorded them.'
  );
}

export function loadDeployment(path: string, cwd: string = process.cwd()): Deployment {
  const abs = resolve(cwd, path);
  let text: string;
  try {
    text = readFileSync(abs, 'utf8');
  } catch (e) {
    throw new DeploymentError(`cannot read the deployment file ${abs}: ${(e as Error).message}`);
  }
  return parseDeployment(text, abs);
}
