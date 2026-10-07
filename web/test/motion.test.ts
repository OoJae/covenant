// The landing page's shared demonstration data, the Seal's bit mapping and the press geometry. No browser, no
// network.

import { describe, expect, test } from 'vitest';
import { hexToBytes, packBits, unpackBits } from '@covenant/tap20';
import { sealCells, sealSide } from '../src/components/Seal.tsx';
import { fgFlagNames, fgModeName, routeView, witness } from '../src/kernel/chip.ts';
import { landingDemo } from '../src/kernel/demo.ts';
import { impressionBox } from '../src/motion/press.ts';
import { motionAllowed } from '../src/motion/prefs.ts';

describe('Seal', () => {
  test('bit i sits at row floor(i/8), column i mod 8, as tap20 unpackBits reads it', () => {
    for (const hex of [witness.reachA.state, witness.reachB.state, witness.outA.newState, witness.outB.newState, witness.tour.finalState]) {
      const bits = unpackBits(hexToBytes(hex), 64);
      const cells = sealCells(hex);
      expect(cells).toHaveLength(64);
      cells.forEach((c, i) => {
        expect(c.i).toBe(i);
        expect(c.row).toBe(Math.floor(i / 8));
        expect(c.col).toBe(i % 8);
        expect(c.on).toBe(bits[i] === 1);
      });
      // and packing the cells back gives the state bytes
      expect(packBits(cells.map((c) => (c.on ? 1 : 0)))).toEqual(hexToBytes(hex));
    }
  });

  test('state A: A = 280 in bits 0..11 (0x118), MODE = 1 in bits 24..26', () => {
    const on = sealCells(witness.reachA.state)
      .filter((c) => c.on)
      .map((c) => c.i);
    expect(on.filter((i) => i < 12)).toEqual([3, 4, 8]); // 280 = 2^3 + 2^4 + 2^8
    expect(on.filter((i) => i >= 24 && i < 27)).toEqual([24]);
  });

  test("a kernel's bytes32 state reads the same as its 8 state bytes", () => {
    const s = witness.reachB.state;
    expect(sealCells('0x' + s.slice(2).padEnd(64, '0'))).toEqual(sealCells(s));
  });

  test('other sizes use a ceil(sqrt(n)) square; bad hex gives a cold seal', () => {
    expect(sealSide(64)).toBe(8);
    expect(sealSide(10)).toBe(4);
    expect(sealSide(1)).toBe(1);
    const c = sealCells('0xff03', 10);
    expect(c.map((x) => [x.row, x.col])).toEqual([[0, 0], [0, 1], [0, 2], [0, 3], [1, 0], [1, 1], [1, 2], [1, 3], [2, 0], [2, 1]]);
    expect(c.every((x) => x.on)).toBe(true);
    expect(sealCells('0xzz').every((x) => !x.on)).toBe(true);
  });
});

describe('landingDemo', () => {
  test('one promise, computed once', () => {
    expect(landingDemo()).toBe(landingDemo());
  });

  test('the two beats give the witness outputs, new states and routes', async () => {
    const d = await landingDemo();
    expect(d.x).toBe(witness.x);
    expect(d.stateA).toBe(witness.reachA.state);
    expect(d.stateB).toBe(witness.reachB.state);
    expect(d.reachedA).toBe(witness.reachA.state);
    expect(d.reachedB).toBe(witness.reachB.state);
    expect(d.outA).toBe(witness.outA.y);
    expect(d.outB).toBe(witness.outB.y);
    expect(d.nextA).toBe(witness.outA.newState);
    expect(d.nextB).toBe(witness.outB.newState);
    for (const [view, w] of [
      [d.routeA, witness.outA.route],
      [d.routeB, witness.outB.route],
    ] as const) {
      expect({ buy: view.buy, hold: view.hold, allow: view.allow, res: view.res, rel: view.rel, ceil: view.ceil, mode: view.mode, tier: view.tier }).toEqual({
        buy: w.T_BUY,
        hold: w.T_HOLD,
        allow: w.T_ALLOW,
        res: w.T_RES,
        rel: w.REL,
        ceil: w.CEIL,
        mode: w.MODE,
        tier: w.TIER,
      });
      expect(fgModeName(view.mode)).toBe(w.modeName);
      expect(fgFlagNames(view.flags).join(',')).toBe(w.flags);
      expect(view.wellFormed).toBe(true);
    }
    expect(d.routeA).toEqual(routeView(witness.outA.y));
  });

  test('netlist, floorplan and signals', async () => {
    const d = await landingDemo();
    expect(d.netlist.nState).toBe(64);
    expect([d.layout.cols, d.layout.rows, d.layout.maxLevel]).toEqual([60, 38, 163]);
    expect(d.layout.grid.filter((v) => v !== -1).length).toBe(2162);
    expect(d.signalsA).toHaveLength(d.netlist.nSignals);
    expect(d.signalsB).toHaveLength(d.netlist.nSignals);
    // the beats differ somewhere inside the die, not only at the outputs
    expect(d.signalsA.some((v, i) => v !== d.signalsB[i])).toBe(true);
  });
});

describe('motion helpers', () => {
  test('the impression is a square centred on the press that covers the element when grown', () => {
    expect(impressionBox(200, 48, 100, 24)).toEqual({ left: 0, top: -76, side: 200 });
    expect(impressionBox(200, 48, 10, 40)).toEqual({ left: -180, top: -150, side: 380 });
    for (const [w, h, x, y] of [
      [120, 48, 0, 0],
      [120, 48, 120, 48],
      [48, 120, 30, 100],
    ]) {
      const b = impressionBox(w, h, x, y);
      expect(b.left + b.side / 2).toBe(x);
      expect(b.top + b.side / 2).toBe(y);
      expect(b.left).toBeLessThanOrEqual(0);
      expect(b.top).toBeLessThanOrEqual(0);
      expect(b.left + b.side).toBeGreaterThanOrEqual(w);
      expect(b.top + b.side).toBeGreaterThanOrEqual(h);
    }
  });

  test('without a window there is no motion', () => {
    expect(motionAllowed()).toBe(false);
  });
});
