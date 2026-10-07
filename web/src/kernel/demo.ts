// The landing page's demonstration, computed once and shared by TwoStates and the 3D scene: the Flow Governor's
// netlist and floorplan, the witness input word, the two reachable latch states, and what one beat from each
// gives (every signal, the outputs, the new state, the route).
//
// Nothing here bundles netlist bytes: kernel/sim.ts stays the only module that does (web/NOTES.md section 9), and
// both it and @covenant/dieshot are loaded on demand, so importing this module costs the entry a few hundred bytes.

import type { Layout } from '@covenant/dieshot';
import type { Netlist } from '@covenant/tap20';
import { routeView, witness, type RouteView } from './chip.ts';

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
  const [sim, { layout }] = await Promise.all([import('./sim.ts'), import('@covenant/dieshot')]);
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
