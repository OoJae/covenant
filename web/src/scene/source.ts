// The scene's input built straight from the files, for the tests (which run in Node) and nothing in the site:
// chips/out/fg.hex parsed as kernel/sim.ts parses it, its dieshot layout, and the witness word and states of
// chips/out/fg.witness.json stepped by @covenant/tap20. The site passes landingDemo() (kernel/demo.ts) instead,
// which holds the same values; test/scene.test.ts checks that the two agree.

import { layout } from '@covenant/dieshot';
import { bytesToHex, hexToBytes, parse, step } from '@covenant/tap20';
import type { SceneSource } from './data.ts';

export async function flowGovernorSource(): Promise<SceneSource> {
  const [hex, w] = await Promise.all([import('../../../chips/out/fg.hex?raw'), import('../../../chips/out/fg.witness.json')]);
  const wit = w.default;
  const netlist = parse(hexToBytes(hex.default.trim()), 96, 112);
  const x = hexToBytes(wit.x);
  const a = step(netlist, hexToBytes(wit.reachA.state), x);
  const b = step(netlist, hexToBytes(wit.reachB.state), x);
  return {
    netlist,
    layout: layout(netlist),
    x: wit.x,
    stateA: wit.reachA.state,
    stateB: wit.reachB.state,
    signalsA: a.signals,
    signalsB: b.signals,
    outA: bytesToHex(a.outputs),
    outB: bytesToHex(b.outputs),
  };
}
