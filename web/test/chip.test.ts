// The chip descriptors, the local simulation behind the landing page and the hostile page, and the code checks of
// the vault page. No network: everything here reads files of the repository.

import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'vitest';
import { keccak256Hex } from '@covenant/chain/keccak';
import { toBytes } from '@covenant/chain';
import { approx, approxCode, FG_FLAGS, FG_KECCAK, FG_MODES, FG_NSTATE, FG_STATE, fgState, pct256, REF_ENVELOPE, routeDiff, routeView, witness } from '../src/kernel/chip.ts';
import { cloneOf, scanCode } from '../src/kernel/code.ts';
import { bitsOf, CLAMPS, fallbackWord, K2, K3, K1T, route, wordOf, bytesOf } from '../src/kernel/model.ts';
import { beat, flowGovernor, glutton, glutton512, reach, replayLocal, shadowRun } from '../src/kernel/sim.ts';

const json = (p: string) => JSON.parse(readFileSync(new URL(p, import.meta.url), 'utf8'));
const FIELDS = json('../../chips/out/fg.fields.json');
const PROOFS = json('../../chips/out/fg.proofs.json');

describe('Flow Governor descriptor = chips/out/fg.fields.json', () => {
  test('state fields, modes, flags, envelope', () => {
    expect(FG_NSTATE).toBe(FIELDS.nState);
    expect(FG_STATE).toEqual(FIELDS.state.map((f: { name: string; offset: number; width: number }) => [f.name, f.offset, f.width]));
    expect([...FG_MODES]).toEqual(Object.keys(FIELDS.modes).sort().map((k) => FIELDS.modes[k]));
    expect([...FG_FLAGS]).toEqual(FIELDS.flags.sort((a: { bit: number }, b: { bit: number }) => a.bit - b.bit).map((f: { name: string }) => f.name));
    expect(REF_ENVELOPE).toEqual(FIELDS.envelope);
    expect(FG_KECCAK).toBe(PROOFS.keccak256);
  });

  test('the witness file decodes to the fields it states', () => {
    for (const s of [witness.reachA, witness.reachB]) {
      const f = Object.fromEntries(fgState(s.state).map((x) => [x.name, x.value]));
      expect(f).toEqual(s.stateFields);
    }
    for (const o of [witness.outA, witness.outB]) {
      const v = routeView(o.y);
      expect([v.buy, v.hold, v.allow, v.res, v.rel, v.ceil, v.mode, v.tier]).toEqual([o.route.T_BUY, o.route.T_HOLD, o.route.T_ALLOW, o.route.T_RES, o.route.REL, o.route.CEIL, o.route.MODE, o.route.TIER]);
      expect(FG_MODES[v.mode]).toBe(o.route.modeName);
    }
    expect(routeDiff(witness.outA.y, witness.outB.y).sort()).toEqual([...witness.differs].sort());
  });
});

describe('local simulation of the netlist bytes', () => {
  test('chips/out/fg.hex is the netlist the proofs were run on', () => {
    const fg = flowGovernor();
    expect(fg.keccak).toBe(FG_KECCAK);
    expect(fg.bytes.length).toBe(PROOFS.bytes);
    expect(fg.netlist.nState).toBe(64);
    expect(fg.netlist.gateCount).toBe(PROOFS.nNand + PROOFS.nLatch);
  });

  test('same inputs, the two witness states, the two witness routes; both states are reached from zero', () => {
    const nl = flowGovernor().netlist;
    const a = beat(nl, witness.reachA.state, witness.x);
    const b = beat(nl, witness.reachB.state, witness.x);
    expect(a.outputs).toBe(witness.outA.y);
    expect(a.newState).toBe(witness.outA.newState);
    expect(b.outputs).toBe(witness.outB.y);
    expect(b.newState).toBe(witness.outB.newState);
    expect(reach(nl, witness.reachA.inputs)).toBe(witness.reachA.state);
    expect(reach(nl, witness.reachB.inputs)).toBe(witness.reachB.state);
    // the mode tour of the witness file, every step
    let s = '0x' + '00'.repeat(8);
    witness.tour.inputs.forEach((x: string, i: number) => {
      const r = beat(nl, s, x);
      expect(FG_MODES[routeView(r.outputs).mode], `tour step ${i + 1}`).toBe(witness.tour.modes[i]);
      s = r.newState;
    });
    expect(s).toBe(witness.tour.finalState);
  });

  test('the kernel stores state as bytes32 with the string first: replayLocal takes that form', () => {
    const nl = flowGovernor().netlist;
    const r = replayLocal(nl, witness.reachA.state + '00'.repeat(24), witness.x);
    expect(r.outputs).toBe(witness.outA.y);
    expect(r.stateAfter32).toBe(witness.outA.newState + '00'.repeat(24));
  });

  test('the netlist equals the chip model on chips/out/fg.vectors.json (every 7th beat)', () => {
    const V = json('../../chips/out/fg.vectors.json');
    expect(V.format).toBe('covenant-chip-vectors/1');
    const nl = flowGovernor().netlist;
    let n = 0;
    V.beats.forEach((v: { state: string; inputs: string; newState: string; outputs: string }, i: number) => {
      if (i % 7) return;
      const r = beat(nl, '0x' + v.state, '0x' + v.inputs);
      expect(r.newState, `beat ${i}`).toBe('0x' + v.newState);
      expect(r.outputs, `beat ${i}`).toBe('0x' + v.outputs);
      n++;
    });
    expect(n).toBeGreaterThan(100);
  });
});

describe('the Glutton under the reference envelope (chips/cells/glutton/README.md)', () => {
  const env = REF_ENVELOPE;
  const zero = '0x' + '00'.repeat(12);

  test('its bytes are the ones the README names', () => {
    expect(glutton().keccak).toBe('0x3278542c10a5aa6e8fe993fc12cfb3a0c9d240450eae569bd431367094519582');
    expect(glutton512().keccak).toBe('0xcfb1f51e727184bdb9850cfa6ed4e8ff53806a50d248fa5417439e6ac0b9d4e4');
    expect(glutton().netlist.gateCount).toBe(114);
  });

  test('it asks for everything whatever the inputs; the heartbeat latch only toggles AUX bit 0', () => {
    const nl = glutton().netlist;
    const a = beat(nl, '0x00', zero);
    const v = routeView(a.outputs);
    expect([v.buy, v.hold, v.allow, v.res, v.rel, v.ceil]).toEqual([0, 0, 256, 0, 256, 1023]);
    const b = beat(nl, a.newState, '0x' + 'ff'.repeat(12));
    expect(wordOf(b.outputs) ^ wordOf(a.outputs)).toBe(1n << 104n);
  });

  test('K2 + K3 on an ordinary settle, K2 + K2C + K3 on a large one; Glutton512 is K1T + K3', () => {
    const out = beat(glutton().netlist, '0x00', zero).outputs;
    const small = route(env, wordOf(out), 10n ** 16n, 10n ** 16n, 10n ** 16n, 0n);
    expect(small.clamp).toBe(K2 | K3);
    expect(small.allow).toBe((10n ** 16n * 48n) / 256n);
    const big = route(env, wordOf(out), 3n * 10n ** 18n, 0n, 3n * 10n ** 18n, 0n);
    expect(bitsOf(CLAMPS, big.clamp).map((c) => c.name)).toEqual(['K2', 'K2C', 'K3']);
    const o512 = beat(glutton512().netlist, '0x00', zero).outputs;
    const r512 = route(env, wordOf(o512), 10n ** 16n, 10n ** 16n, 10n ** 16n, 0n);
    expect(r512.clamp).toBe(K1T | K3);
    expect(r512.allow).toBe(0n);
  });

  test('shadow run: allowance never above capT of each settle, nor above allowCumBps of all tax', () => {
    const nl = glutton().netlist;
    let cum = 0n;
    const rows = [5n, 3n, 0n, 120n, 1n, 40n].map((m, i) => {
      const inflow = m * 10n ** 15n;
      cum += inflow;
      return { n: i + 1, cumInflow: cum, rec: { inflow, flags: 0, inputs: bytesOf(BigInt(i), 12) } as never };
    });
    const out = shadowRun(nl, env, rows);
    let paid = 0n;
    out.forEach((s, i) => {
      const inflow = rows[i].cumInflow - (i ? rows[i - 1].cumInflow : 0n);
      expect(s.allow * 256n <= inflow * 48n).toBe(true);
      paid += s.allow;
      expect(paid * 10000n <= rows[i].cumInflow * 1875n).toBe(true);
      expect(s.clampBits & K3).toBe(K3);
    });
    // RES in each shadow input word is the Glutton's own reserve before that settle
    expect(wordOf(out[0].inputs) >> 40n & 0x3ffn).toBe(0n);
  });

  test('the fallback word under the reference envelope is 248 / 8, release 128', () => {
    const v = routeView(bytesOf(fallbackWord(env.fbAllow, env.relMax), 14));
    expect([v.buy, v.allow, v.rel, v.ceil]).toEqual([248, 8, 128, 1023]);
  });
});

describe('formatting of amounts and shares', () => {
  test('pct256, approx, approxCode', () => {
    expect([pct256(256), pct256(160), pct256(48), pct256(2), pct256(0)]).toEqual(['100%', '62.5%', '18.75%', '0.78%', '0%']);
    expect(approx(9000000000000000n)).toBe('0.009');
    expect(approx(1687500000000000n)).toBe('0.0016');
    expect(approx(10n ** 18n)).toBe('1');
    expect(approx(1234n * 10n ** 18n)).toBe('1,234');
    expect(approx(12n)).toBe('12 wei');
    expect(approxCode(478)).toBe('0.93'); // the lower edge of the code that 1 OKB falls in
    expect(approxCode(1023)).toBe('no limit');
  });
});

describe('code checks', () => {
  const impl = '72e6ebdb444831c9511c6d1dbf07a7f68993edf1';
  test('an ERC-1167 clone with immutable arguments is recognised, anything else is not', () => {
    const code = '0x363d3d373d3d3d363d73' + impl + '5af43d82803e903d91602b57fd5bf3' + 'ab'.repeat(64);
    expect(cloneOf(code)).toEqual({ isClone: true, implementation: '0x' + impl, args: '0x' + 'ab'.repeat(64) });
    expect(cloneOf('0x6080604052').isClone).toBe(false);
    expect(cloneOf('0x363d3d373d3d3d363d73' + impl + '5af43d82803e903d91602b57fd5bf4').isClone).toBe(false);
  });

  test('the scan finds DELEGATECALL and forbidden selectors, skips push data and the metadata tail', () => {
    // PUSH4 owner(); DELEGATECALL; PUSH2 0xf4ff (data, not opcodes); then CBOR metadata of 3 bytes containing 0xff
    const code = '0x638da5cb5bf461f4ff00' + 'a1ff00' + '0003';
    const s = scanCode(code);
    expect(s.selectors).toEqual(['owner()']);
    expect(s.delegatecall).toBe(1);
    expect(s.selfdestruct).toBe(0);
    // a selector split across a nibble boundary is not a match
    expect(scanCode('0x08da5cb5b0').selectors).toEqual([]);
    expect(keccak256Hex(toBytes('0x')).length).toBe(66);
  });
});
