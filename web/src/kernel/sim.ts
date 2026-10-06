// Local simulation: the chips' netlist bytes, stepped by this site's own TAP-20 simulator (@covenant/tap20), and
// the kernel's shadow arithmetic (Lens._shadowOne) on top of the TypeScript clip port. Loaded on demand: it carries
// the Flow Governor's 13 KB netlist.

import { toBytes, toHex } from '@covenant/chain';
import { keccak256Hex } from '@covenant/chain/keccak';
import { parse, step, type Netlist } from '@covenant/tap20';
import fgHex from '../../../chips/out/fg.hex?raw';
import gluttonHex from '../../../chips/cells/glutton/glutton.hex?raw';
import glutton512Hex from '../../../chips/cells/glutton/glutton512.hex?raw';
import { INPUT_FIELDS, bytesOf, lg8s, pack, route, stateBytes, stateWord32, unpack, wordOf, type RouteEnv } from './model.ts';

export interface Chip {
  name: string;
  bytes: Uint8Array;
  keccak: string;
  netlist: Netlist;
}

const cache = new Map<string, Chip>();

function load(name: string, hex: string): Chip {
  let c = cache.get(name);
  if (!c) {
    const bytes = toBytes(hex.trim());
    c = { name, bytes, keccak: keccak256Hex(bytes), netlist: parse(bytes, 96, 112) };
    cache.set(name, c);
  }
  return c;
}

/** chips/out/fg.hex, the Flow Governor as built and proven. */
export const flowGovernor = (): Chip => load('Flow Governor', fgHex);
/** chips/cells/glutton: asks for everything. */
export const glutton = (): Chip => load('Glutton', gluttonHex);
/** chips/cells/glutton: asks for 512/256. */
export const glutton512 = (): Chip => load('Glutton512', glutton512Hex);

/** A netlist read from the chain, parsed the same way. */
export const chipFromBytes = (name: string, bytes: Uint8Array): Chip => ({ name, bytes, keccak: keccak256Hex(bytes), netlist: parse(bytes, 96, 112) });

export interface Beat {
  /** ceil(nState / 8) bytes, as 0x hex. */
  newState: string;
  outputs: string;
  signals: Uint8Array;
}

/** One beat. `state` may be the kernel's bytes32 form or exactly the state bytes: TAP-20 reads it leniently. */
export function beat(nl: Netlist, state: string, inputs: string): Beat {
  const r = step(nl, toBytes(state), toBytes(inputs));
  return { newState: toHex(r.newState), outputs: toHex(r.outputs), signals: r.signals };
}

/** Steps from the all-zero state through `inputs`; returns the state reached. */
export function reach(nl: Netlist, inputs: readonly string[]): string {
  let s = '0x' + '00'.repeat(Math.ceil(nl.nState / 8));
  for (const x of inputs) s = beat(nl, s, x).newState;
  return s;
}

export interface ShadowRow {
  n: number;
  inputs: string;
  outputs: string;
  clampBits: number;
  allow: bigint;
  buyDecided: bigint;
  reserveAfter: bigint;
}

export interface RecordForShadow {
  n: number;
  /** The fields of a kernel v1 or v2 record the shadow run reads. */
  rec: { inputs: string; inflow: bigint; flags: number };
  cumInflow: bigint;
}

/**
 * What another chip would have routed on a kernel's recorded inflows, exactly as Lens.shadowChip computes it: the
 * shadow chip sees its own reserve (RES is recomputed), every other input is the recorded one, decided buys are
 * assumed to execute in full, and the regime totals restart at graduation.
 *
 * `shift` is a v2 kernel's code shift (LensV2._shadowOne): on the curve RES is lg8(reserve << shift) and the routing
 * reads codes through the shift; after graduation the shift is 0. Kernel v1: 0.
 */
export function shadowRun(nl: Netlist, env: RouteEnv, rows: readonly RecordForShadow[], shift: number = 0): ShadowRow[] {
  let state = '0x' + '00'.repeat(32);
  let reserve = 0n;
  let allowPaid = 0n;
  let grad = false;
  const out: ShadowRow[] = [];
  for (const { n, rec, cumInflow } of rows) {
    const g = (rec.flags & 64) !== 0;
    if (g && !grad) {
      grad = true;
      reserve = 0n;
      allowPaid = 0n;
    }
    const s = g ? 0 : shift;
    const fields = unpack(INPUT_FIELDS, wordOf(rec.inputs));
    fields.RES = lg8s(reserve, s);
    const inputs = bytesOf(pack(INPUT_FIELDS, fields), 12);
    const b = beat(nl, state, inputs);
    state = stateWord32(b.newState);
    const r = route(env, wordOf(b.outputs), rec.inflow, reserve, cumInflow, allowPaid, g, s);
    reserve = r.reserveAfter;
    allowPaid += r.allow;
    out.push({ n, inputs, outputs: b.outputs, clampBits: r.clamp, allow: r.allow, buyDecided: r.buyDecided, reserveAfter: r.reserveAfter });
  }
  return out;
}

/** The step a record describes, recomputed here: stateBefore and the stored inputs through the netlist. */
export function replayLocal(nl: Netlist, stateBefore: string, inputs: string): Beat & { stateAfter32: string } {
  const b = beat(nl, stateBytes(stateBefore, nl.nState), inputs);
  return { ...b, stateAfter32: stateWord32(b.newState) };
}

