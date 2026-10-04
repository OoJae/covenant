// Asynchronous loading of a netlist together with its REF closure.
//
// `parse` is synchronous and takes a resolver for REF targets. When the targets live on chain
// they have to be fetched first: `load` walks the REF records, fetches each distinct target
// once through `fetcher`, parses the targets depth-first and then parses the top netlist.

import { listRefs, parse, refKey, Tap20Error, type Netlist, type Resolver } from './parse.ts';
import { DEFAULT_MAX_DEPTH, DEFAULT_MAX_GATES } from './sim.ts';

export interface CircuitSource {
  netlist: Uint8Array;
  nIn: number;
  nOut: number;
}

/**
 * Returns the stored netlist and pin counts of circuit (cpu, id), or nothing if `cpu` is not a
 * registered processor or the circuit does not exist (TAP-20 section 3, condition 6).
 */
export type Fetcher = (cpu: string, id: bigint) => Promise<CircuitSource | null | undefined>;

export interface LoadOptions {
  /** Deepest REF nesting to follow. Default 16. */
  maxDepth?: number;
  /** Largest total gate count accepted for any circuit in the closure. Default 4,194,304. */
  maxGates?: number;
  /** Most distinct REF targets to fetch. Default 256. */
  maxCircuits?: number;
}

export async function load(
  bytes: Uint8Array,
  nIn: number,
  nOut: number,
  fetcher?: Fetcher,
  opts: LoadOptions = {},
): Promise<Netlist> {
  const maxDepth = opts.maxDepth ?? DEFAULT_MAX_DEPTH;
  const maxGates = opts.maxGates ?? DEFAULT_MAX_GATES;
  const maxCircuits = opts.maxCircuits ?? 256;
  const cache = new Map<string, Netlist | null>();
  const lookup: Resolver = (cpu, id) => cache.get(refKey(cpu, id));
  let fetched = 0;

  const check = (nl: Netlist): Netlist => {
    if (nl.gateCount > maxGates) {
      throw new Tap20Error('limit', `circuit has ${nl.gateCount} gates, above the bound of ${maxGates}`);
    }
    return nl;
  };

  const closure = async (b: Uint8Array, depth: number): Promise<void> => {
    const refs = listRefs(b);
    if (refs.length === 0) return;
    if (!fetcher) throw new Tap20Error('ref-unresolved', 'netlist contains a REF and no fetcher was given');
    if (depth >= maxDepth) throw new Tap20Error('limit', `REF nesting is deeper than ${maxDepth}`);
    for (const r of refs) {
      const key = refKey(r.cpu, r.id);
      if (cache.has(key)) continue;
      // Marked missing while it is being loaded, so a (non-conforming) cyclic source fails
      // with `ref-unresolved` instead of recursing forever.
      cache.set(key, null);
      if (++fetched > maxCircuits) throw new Tap20Error('limit', `more than ${maxCircuits} REF targets`);
      const src = await fetcher(r.cpu, r.id);
      if (!src) continue;
      await closure(src.netlist, depth + 1);
      cache.set(key, check(parse(src.netlist, src.nIn, src.nOut, lookup)));
    }
  };

  await closure(bytes, 0);
  return check(parse(bytes, nIn, nOut, lookup));
}
