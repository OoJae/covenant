// What the 3D die scene draws, built once from real data and only read afterwards: the floorplan of
// @covenant/dieshot's layout() (not changed here; its layoutHash stays pinned by the dieshot tests), the
// wires rebuilt from the netlist's a/b inputs along the same Manhattan paths the Canvas 2D die shot draws,
// and the value of every signal in two beats computed by @covenant/tap20's step(): states A and B of
// chips/out/fg.witness.json, both answering the same input word x.
//
// buildScene() takes all of that ready-made, in the shape of landingDemo() (kernel/demo.ts), and computes nothing
// it is given: this module imports neither the netlist bytes, nor the layout code, nor the simulator, so the lazy
// scene chunk stays small. source.ts builds the same input from the files, for the tests.
//
// Everything the renderer needs per frame is in three typed arrays made here, so drawing allocates nothing.

import type { Layout } from '@covenant/dieshot';
import { hexToBytes, type Netlist } from '@covenant/tap20';
import { OUTPUT_FIELDS } from '../kernel/model.ts';
import { reachTable } from './choreo.ts';

/** Instance kinds. 0 to 4 are dieshot's KIND_* (constant, input, NAND, LATCH, REF); the rest are the scene's. */
export const K_CONST = 0;
export const K_INPUT = 1;
export const K_NAND = 2;
export const K_LATCH = 3;
export const K_REF = 4;
/** An output pad on the die's right edge. */
export const K_PAD = 5;
/** One of the 64 seal targets: the slot latch bit i lands in. */
export const K_SLOT = 6;
/** The seal's plate, its pin-1 square, and the die's substrate: one instance each. */
export const K_PLATE = 7;
export const K_PIN = 8;
export const K_BASE = 9;

/** Floats per instance: x, y (cell column and row), level, kind, value in A, value in B, index, route group. */
export const STRIDE = 8;
/** Floats per wire vertex: x, y (in cells), level of the wire's source, flags (WIRE_*). */
export const WSTRIDE = 4;
export const WIRE_LOOP = 1;
export const WIRE_A = 2;
export const WIRE_B = 4;
export const WIRE_OUT = 8;

/** Cell size and pitch of dieshot's renderer, in its pixels: a cell is CELL / PITCH of a grid step wide. */
export const PITCH = 7;
export const CELL = 5;

/** Route groups of the output pads: the tax shares of the output word (OUTPUT_FIELDS of kernel/model.ts). */
export const ROUTE_NONE = 0;
export const ROUTE_BUY = 1;
export const ROUTE_ALLOW = 2;
export const ROUTE_RES = 3;
const ROUTE_OF: Record<string, number> = { T_BUY: ROUTE_BUY, T_ALLOW: ROUTE_ALLOW, T_RES: ROUTE_RES };

/** The seal is 8 x 8: state bit i sits at row floor(i / 8), column i mod 8. */
export const SEAL_SIDE = 8;

/** The fields of `landingDemo()` (kernel/demo.ts) the scene reads. A LandingDemo is a SceneSource. */
export interface SceneSource {
  netlist: Netlist;
  /** layout(netlist) from @covenant/dieshot. */
  layout: Layout;
  /** Input word and the two states, as 0x hex. */
  x: string;
  stateA: string;
  stateB: string;
  /** Every signal of the beat from state A and from state B (one byte, 0 or 1, per signal). */
  signalsA: Uint8Array;
  signalsB: Uint8Array;
  /** The two output words, as 0x hex. */
  outA: string;
  outB: string;
}

export interface SceneData {
  cols: number;
  rows: number;
  maxLevel: number;
  nIn: number;
  nOut: number;
  /** Every cell of the die: constants, inputs, gates, latches (one per signal) and the output pads. */
  cells: number;
  /** Seal targets (one per state bit). */
  seals: number;
  /** Instances drawn: cells, seal targets, then the plate, the pin-1 square and the substrate. */
  count: number;
  /** count * STRIDE floats. */
  inst: Float32Array;
  /** Instance of the LATCH cell that holds state bit i. */
  latchOf: Uint32Array;
  /** Row and column of seal target i: [row0, col0, row1, col1, ...]. */
  sealRC: Uint8Array;
  /** LINES vertices, WSTRIDE floats each; four segments per wire. */
  wires: Float32Array;
  /** Wires drawn: one per (source, sink) pair of the netlist, constants excepted, plus one per output pad. */
  wireCount: number;
  /** Wires on the state loop (into or out of a LATCH). */
  loopWires: number;
  /** Route group (ROUTE_*) of output pad j. */
  padGroup: Uint8Array;
  /** Every signal's value in the beat from state A and from state B, as step() returned it. */
  signalsA: Uint8Array;
  signalsB: Uint8Array;
  /** Packed outputs of both beats. */
  outA: Uint8Array;
  outB: Uint8Array;
  /** Per level, the share of a wavefront's sweep at which it arrives there (choreo.ts levelAt). */
  reach: Float32Array;
}

/** Route group of every output bit, from the T_BUY, T_ALLOW and T_RES fields of the output word. */
export function routeGroups(nOut: number): Uint8Array {
  const g = new Uint8Array(nOut);
  for (const [name, off, width] of OUTPUT_FIELDS) {
    const r = ROUTE_OF[name];
    if (r) g.fill(r, off, Math.min(nOut, off + width));
  }
  return g;
}

export function buildScene(src: SceneSource): SceneData {
  const nl = src.netlist;
  const lay = src.layout;
  const sA = src.signalsA;
  const sB = src.signalsB;
  const S = nl.nSignals;
  const nOut = nl.nOut;
  const first = 2 + nl.nIn;
  const cells = S + nOut;
  const seals = nl.nState;
  const count = cells + seals + 3;
  const inst = new Float32Array(count * STRIDE);
  const latchOf = new Uint32Array(seals);
  const sealRC = new Uint8Array(2 * seals);
  const padGroup = routeGroups(nOut);

  const put = (k: number, cx: number, cy: number, level: number, kind: number, a: number, b: number, idx: number, group: number): void => {
    const o = k * STRIDE;
    inst[o] = cx;
    inst[o + 1] = cy;
    inst[o + 2] = level;
    inst[o + 3] = kind;
    inst[o + 4] = a;
    inst[o + 5] = b;
    inst[o + 6] = idx;
    inst[o + 7] = group;
  };

  // One instance per signal: its cell, level and kind; inputs carry their pin, latches their state bit.
  for (let s = 0; s < S; s++) {
    const kind = lay.kind[s];
    let idx = 0;
    if (kind === 1) idx = s - 2;
    else if (kind === 3) {
      idx = nl.stateBase[lay.element[s]];
      latchOf[idx] = s;
    }
    put(s, lay.x[s], lay.y[s], lay.level[s], kind, sA[s], sB[s], idx, 0);
  }
  // Output pads, after the last level; each shows the signal that drives it.
  for (let j = 0; j < nOut; j++) {
    const d = S - nOut + j;
    put(S + j, lay.outX[j], lay.outY[j], lay.maxLevel + 1, K_PAD, sA[d], sB[d], j, padGroup[j]);
  }
  // Seal targets: bit i at row floor(i / 8), column i mod 8; they show the state bit itself.
  for (let i = 0; i < seals; i++) {
    const r = Math.floor(i / SEAL_SIDE);
    const c = i % SEAL_SIDE;
    sealRC[2 * i] = r;
    sealRC[2 * i + 1] = c;
    const l = latchOf[i];
    put(cells + i, c, r, 0, K_SLOT, sA[l], sB[l], i, 0);
  }
  put(cells + seals, 0, 0, 0, K_PLATE, 0, 0, 0, 0);
  put(cells + seals + 1, 0, 0, 0, K_PIN, 0, 0, 0, 0);
  put(cells + seals + 2, (lay.cols - 1) / 2, (lay.rows - 1) / 2, 0, K_BASE, 0, 0, 0, 0);

  // Wires, as dieshot's renderer routes them: down into the gap under the source row, along it, then up or
  // down the gap beside the sink's column. `track` (0 or 1) is the input number, so a and b do not overlap.
  const sources = (s: number): number[] => {
    const e = lay.element[s];
    const op = nl.op[e];
    if (op === 0) return nl.a[e] === nl.b[e] ? [nl.a[e]] : [nl.a[e], nl.b[e]];
    if (op === 1) return [nl.a[e]];
    return Array.from(nl.refs[nl.b[e]].ins);
  };
  const paths: number[] = [];
  let loopWires = 0;
  for (let s = first; s < S; s++) {
    if (s > first && lay.element[s] === lay.element[s - 1]) continue; // further outputs of one REF
    const src = sources(s);
    for (let i = 0; i < src.length; i++) {
      const from = src[i];
      if (from < 2) continue; // wires from the two constants are not drawn
      const loop = lay.kind[s] === 3 || lay.kind[from] === 3;
      if (loop) loopWires++;
      paths.push(from, lay.x[s], lay.y[s], i & 1, loop ? WIRE_LOOP : 0);
    }
  }
  for (let j = 0; j < nOut; j++) paths.push(S - nOut + j, lay.outX[j], lay.outY[j], 0, WIRE_OUT);

  const wireCount = paths.length / 5;
  const wires = new Float32Array(wireCount * 8 * WSTRIDE);
  const C = CELL / PITCH;
  let p = 0;
  const v = (px: number, py: number, level: number, flags: number): void => {
    wires[p++] = px;
    wires[p++] = py;
    wires[p++] = level;
    wires[p++] = flags;
  };
  for (let w = 0; w < paths.length; w += 5) {
    const from = paths[w];
    const dx = paths[w + 1];
    const dy = paths[w + 2];
    const track = paths[w + 3];
    const flags = paths[w + 4] | (sA[from] ? WIRE_A : 0) | (sB[from] ? WIRE_B : 0);
    const sx = lay.x[from];
    const sy = lay.y[from];
    const level = lay.level[from];
    const fromLeft = sx <= dx;
    const xh = sx + C / 2;
    const yh = sy + C + (0.5 + track) / PITCH;
    const xv = fromLeft ? dx - (0.5 + track) / PITCH : dx + C + (0.5 + track) / PITCH;
    const yd = dy + C / 2;
    const pts = [xh, sy + C, xh, yh, xv, yh, xv, yd, fromLeft ? dx : dx + C, yd];
    for (let k = 0; k < 4; k++) {
      v(pts[2 * k], pts[2 * k + 1], level, flags);
      v(pts[2 * k + 2], pts[2 * k + 3], level, flags);
    }
  }

  return {
    cols: lay.cols,
    rows: lay.rows,
    maxLevel: lay.maxLevel,
    nIn: nl.nIn,
    nOut,
    cells,
    seals,
    count,
    inst,
    latchOf,
    sealRC,
    wires,
    wireCount,
    loopWires,
    padGroup,
    signalsA: sA,
    signalsB: sB,
    outA: hexToBytes(src.outA),
    outB: hexToBytes(src.outB),
    reach: reachTable(lay.level, lay.kind, lay.maxLevel),
  };
}
