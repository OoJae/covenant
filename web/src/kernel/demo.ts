// The landing page's demonstration, computed once and shared by TwoStates, the chapters and the 3D scene: the Flow
// Governor's netlist and floorplan, the witness input word, the two reachable latch states, and what one beat from
// each gives (every signal, the outputs, the new state, the route).
//
// This module is in the page's entry script, so it imports nothing heavy statically: the simulator and the netlist
// (kernel/sim.ts, the only module that bundles netlist bytes; web/NOTES.md section 9), @covenant/dieshot, and even
// kernel/chip.ts with the witness (landingFacts) are loaded on demand. Importing it costs the entry a few hundred
// bytes.

import type { Layout } from '@covenant/dieshot';
import type { Netlist } from '@covenant/tap20';
import type { RouteView } from './chip.ts';

/**
 * The Flow Governor's size as the hero's die marking prints it at first paint, before any chunk has loaded:
 * NAND and LATCH records of chips/out/fg.hex. test/landing.test.ts counts them in the netlist and checks them
 * against kernel/chip.ts FG_GATES, so this copy cannot drift from the data.
 */
export const FG_SIZE = { nand: 1888, latch: 64 } as const;

export interface LandingDemo {
  netlist: Netlist;
  /** layout(netlist) from @covenant/dieshot, without a block map (the hash the dieshot tests pin). */
  layout: Layout;
  /** keccak256 of the netlist bytes. */
  keccak: string;
  /** The input word both beats read (chips/out/fg.witness.json `x`). */
  x: string;
  /** The latch states the two beats start from (witness reachA.state and reachB.state), 8 bytes each. */
  stateA: string;
  stateB: string;
  /** Every signal of each beat, one byte (0 or 1) per signal, in netlist order. */
  signalsA: Uint8Array;
  signalsB: Uint8Array;
  /** The output words, 14 bytes each. */
  outA: string;
  outB: string;
  /** The states each beat leaves behind. */
  nextA: string;
  nextB: string;
  /** The output words read as routes. */
  routeA: RouteView;
  routeB: RouteView;
  /** The states this browser reached by replaying the witness inputs from the all-zero state. */
  reachedA: string;
  reachedB: string;
}

let memo: Promise<LandingDemo> | undefined;

/** The demonstration, computed on the first call; later calls get the same promise. A failure can be retried. */
export function landingDemo(): Promise<LandingDemo> {
  memo ??= build().catch((e: unknown) => {
    memo = undefined;
    throw e;
  });
  return memo;
}

async function build(): Promise<LandingDemo> {
  const [sim, { layout }, { routeView, witness }] = await Promise.all([import('./sim.ts'), import('@covenant/dieshot'), import('./chip.ts')]);
  const fg = sim.flowGovernor();
  const nl = fg.netlist;
  const x = witness.x;
  const a = sim.beat(nl, witness.reachA.state, x);
  const b = sim.beat(nl, witness.reachB.state, x);
  return {
    netlist: nl,
    layout: layout(nl),
    keccak: fg.keccak,
    x,
    stateA: witness.reachA.state,
    stateB: witness.reachB.state,
    signalsA: a.signals,
    signalsB: b.signals,
    outA: a.outputs,
    outB: b.outputs,
    nextA: a.newState,
    nextB: b.newState,
    routeA: routeView(a.outputs),
    routeB: routeView(b.outputs),
    reachedA: sim.reach(nl, witness.reachA.inputs),
    reachedB: sim.reach(nl, witness.reachB.inputs),
  };
}

/** A route as the chapters print it. */
export interface RouteText {
  mode: string;
  buy: string;
  allow: string;
  /** Reserve and hold together, as the route bar shows them. */
  res: string;
  /** Share of the existing reserve released into buy-and-lock. */
  rel: string;
}

/** What the chapters print from the witness alone (no simulator): the input word read as fields, both states'
 * fields, and both routes from the witness outputs (the same words landingDemo computes; test/landing.test.ts). */
export interface LandingFacts {
  x: string;
  stateA: string;
  stateB: string;
  /** Width of the input word in bits. */
  inputBits: number;
  /** Approximate amounts the input word's codes stand for, in OKB. */
  tax: string;
  taxCum: string;
  reserve: string;
  /** Epochs since the last step. */
  dt: number;
  /** Fields of states A and B by name (MODE spelled out). */
  fieldsA: Record<string, string>;
  fieldsB: Record<string, string>;
  routeA: RouteText;
  routeB: RouteText;
}

let facts: Promise<LandingFacts> | undefined;

/** The chapters' numbers; loads kernel/chip.ts (shared with §01) on the first call. A failure can be retried. */
export function landingFacts(): Promise<LandingFacts> {
  facts ??= Promise.all([import('./chip.ts'), import('./model.ts')])
    .then(([c, m]): LandingFacts => {
      const w = c.witness;
      const x = m.inputFields(w.x);
      const fields = (s: string): Record<string, string> => Object.fromEntries(c.fgState(s).map((f) => [f.name, f.text]));
      const text = (out: string): RouteText => {
        const v = c.routeView(out);
        return { mode: c.fgModeName(v.mode), buy: c.pct256(v.buy), allow: c.pct256(v.allow), res: c.pct256(v.res + v.hold), rel: c.pct256(v.rel) };
      };
      return {
        x: w.x,
        stateA: w.reachA.state,
        stateB: w.reachB.state,
        inputBits: (w.x.length - 2) * 4,
        tax: c.approxCode(x.TAX),
        taxCum: c.approxCode(x.TAXCUM),
        reserve: c.approxCode(x.RES),
        dt: x.DT,
        fieldsA: fields(w.reachA.state),
        fieldsB: fields(w.reachB.state),
        routeA: text(w.outA.y),
        routeB: text(w.outB.y),
      };
    })
    .catch((e: unknown) => {
      facts = undefined;
      throw e;
    });
  return facts;
}
