// The 3D die scene's data and choreography (src/scene), without a DOM: what it draws is the Flow Governor's real
// floorplan, wires and two beats, the chapters run in order, the stage maps the scroll onto them, and the lazy
// stage chunk imports nothing that would carry the netlist or the simulator.

import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'vitest';
import { layout } from '@covenant/dieshot';
import { bytesToHex, hexToBytes, step } from '@covenant/tap20';
import { witness } from '../src/kernel/chip.ts';
import {
  CAM_SIZE,
  CHAPTERS,
  P_FLIP,
  P_FLY,
  P_INPUT,
  P_POWER,
  P_PRESS,
  P_RELIGHT,
  P_ROUTE,
  P_WAVE,
  STILL_T,
  SWAY_DEG,
  SWAY_UNTIL,
  cameraAt,
  cameraStill,
  lensShift,
  levelAt,
  phaseAt,
  swayAt,
} from '../src/scene/choreo.ts';
import {
  K_BASE,
  K_CONST,
  K_INPUT,
  K_LATCH,
  K_NAND,
  K_PAD,
  K_PIN,
  K_PLATE,
  K_SLOT,
  ROUTE_ALLOW,
  ROUTE_BUY,
  ROUTE_NONE,
  ROUTE_RES,
  STRIDE,
  WIRE_A,
  WIRE_B,
  WIRE_LOOP,
  WSTRIDE,
  buildScene,
} from '../src/scene/data.ts';
import { THEME_SILICON } from '../src/scene/fallback.ts';
import { lookAt, m4, mul, perspective, project } from '../src/scene/math.ts';
import { LEAD, LEAD_END, chapterAt, stageAnchors, stageProgress, type StageBlock } from '../src/scene/scroll.ts';
import { flowGovernorSource } from '../src/scene/source.ts';
import { landingDemo } from '../src/kernel/demo.ts';

const src = await flowGovernorSource();
const d = buildScene(src);
const nl = src.netlist;
const lay = layout(nl);
const at = (k: number, f: number): number => d.inst[k * STRIDE + f];

describe('scene data', () => {
  test('reads the pinned Flow Governor layout: 60 x 38, maxLevel 163', () => {
    expect(lay.layoutHash).toBe('c6f77e5f1fb04c361e5bca1220d0e527b71d9a9db987f1c125d2818639e4cff3');
    expect([d.cols, d.rows, d.maxLevel]).toEqual([60, 38, 163]);
    for (let s = 0; s < nl.nSignals; s++) {
      expect([at(s, 0), at(s, 1), at(s, 2), at(s, 3)]).toEqual([lay.x[s], lay.y[s], lay.level[s], lay.kind[s]]);
    }
    for (let j = 0; j < nl.nOut; j++) expect([at(nl.nSignals + j, 0), at(nl.nSignals + j, 1)]).toEqual([lay.outX[j], lay.outY[j]]);
  });

  test('2,162 cells including pads, 64 seal targets, and the plate, pin-1 and substrate', () => {
    expect(d.cells).toBe(2162);
    expect(d.seals).toBe(64);
    expect(d.count).toBe(2162 + 64 + 3);
    expect(d.inst.length).toBe(d.count * STRIDE);
    const n = new Map<number, number>();
    for (let k = 0; k < d.count; k++) n.set(at(k, 3), (n.get(at(k, 3)) ?? 0) + 1);
    expect(Object.fromEntries(n)).toEqual({
      [K_CONST]: 2,
      [K_INPUT]: 96,
      [K_NAND]: 1888,
      [K_LATCH]: 64,
      [K_PAD]: 112,
      [K_SLOT]: 64,
      [K_PLATE]: 1,
      [K_PIN]: 1,
      [K_BASE]: 1,
    });
  });

  test('seal targets: bit i at row floor(i / 8), column i mod 8, showing the latch of that bit', () => {
    const a = hexToBytes(src.stateA);
    const b = hexToBytes(src.stateB);
    for (let i = 0; i < 64; i++) {
      const slot = d.cells + i;
      expect([d.sealRC[2 * i], d.sealRC[2 * i + 1]]).toEqual([Math.floor(i / 8), i % 8]);
      expect([at(slot, 0), at(slot, 1), at(slot, 6)]).toEqual([i % 8, Math.floor(i / 8), i]);
      const l = d.latchOf[i];
      expect(at(l, 3)).toBe(K_LATCH);
      expect(at(l, 6)).toBe(i);
      expect(nl.stateBase[lay.element[l]]).toBe(i);
      // A LATCH outputs the state bit stored at the previous beat.
      expect([at(slot, 4), at(slot, 5)]).toEqual([(a[i >> 3] >> (i & 7)) & 1, (b[i >> 3] >> (i & 7)) & 1]);
      expect([at(l, 4), at(l, 5)]).toEqual([at(slot, 4), at(slot, 5)]);
    }
  });

  test('wires: one per non-constant input of every record, plus one per output pad; four segments each', () => {
    let n = 0;
    let loop = 0;
    for (let e = 0; e < nl.n; e++) {
      const ins = nl.op[e] === 0 ? (nl.a[e] === nl.b[e] ? [nl.a[e]] : [nl.a[e], nl.b[e]]) : [nl.a[e]];
      for (const s of ins) {
        if (s < 2) continue;
        n++;
        if (nl.op[e] === 1 || lay.kind[s] === K_LATCH) loop++;
      }
    }
    expect(d.wireCount).toBe(n + nl.nOut);
    expect(d.wireCount).toBe(3306);
    expect(d.loopWires).toBe(loop);
    expect(d.loopWires).toBe(165);
    expect(d.wires.length).toBe(d.wireCount * 8 * WSTRIDE);
    let flagged = 0;
    for (let v = 0; v < d.wires.length; v += WSTRIDE) {
      expect(Number.isFinite(d.wires[v]) && Number.isFinite(d.wires[v + 1])).toBe(true);
      expect(d.wires[v]).toBeGreaterThanOrEqual(-0.5);
      expect(d.wires[v]).toBeLessThanOrEqual(d.cols + 0.5);
      if (d.wires[v + 3] & WIRE_LOOP) flagged++;
    }
    expect(flagged).toBe(165 * 8);
    // Consecutive segments of one wire join: four segments, five corners.
    for (let w = 0; w < d.wireCount; w++) {
      const o = w * 8 * WSTRIDE;
      for (let k = 1; k < 4; k++) {
        expect(d.wires[o + (2 * k - 1) * WSTRIDE]).toBe(d.wires[o + 2 * k * WSTRIDE]);
        expect(d.wires[o + (2 * k - 1) * WSTRIDE + 1]).toBe(d.wires[o + 2 * k * WSTRIDE + 1]);
      }
    }
  });

  test('signals for states A and B equal @covenant/tap20 step() on the witness word', () => {
    const x = hexToBytes(witness.x);
    const A = step(nl, hexToBytes(witness.reachA.state), x);
    const B = step(nl, hexToBytes(witness.reachB.state), x);
    expect(d.signalsA).toEqual(A.signals);
    expect(d.signalsB).toEqual(B.signals);
    expect(bytesToHex(d.outA)).toBe(witness.outA.y);
    expect(bytesToHex(d.outB)).toBe(witness.outB.y);
    for (let s = 0; s < nl.nSignals; s++) expect([at(s, 4), at(s, 5)]).toEqual([A.signals[s], B.signals[s]]);
    for (let j = 0; j < nl.nOut; j++) {
      expect([at(nl.nSignals + j, 4), at(nl.nSignals + j, 5)]).toEqual([(A.outputs[j >> 3] >> (j & 7)) & 1, (B.outputs[j >> 3] >> (j & 7)) & 1]);
    }
    // Wire flags carry the value of the wire's source.
    let differ = 0;
    for (let v = 0; v < d.wires.length; v += 8 * WSTRIDE) {
      const f = d.wires[v + 3];
      if (!!(f & WIRE_A) !== !!(f & WIRE_B)) differ++;
    }
    expect(differ).toBeGreaterThan(0);
  });

  test('output pads carry their route group: T_BUY, T_ALLOW and T_RES, nine bits each', () => {
    const count = (g: number): number => d.padGroup.filter((x) => x === g).length;
    expect([count(ROUTE_BUY), count(ROUTE_ALLOW), count(ROUTE_RES), count(ROUTE_NONE)]).toEqual([9, 9, 9, 112 - 27]);
    expect(Array.from(d.padGroup.slice(0, 36))).toEqual([...Array(9).fill(ROUTE_BUY), ...Array(9).fill(ROUTE_NONE), ...Array(9).fill(ROUTE_ALLOW), ...Array(9).fill(ROUTE_RES)]);
    for (let j = 0; j < 112; j++) expect(at(d.cells - 112 + j, 7)).toBe(d.padGroup[j]);
  });
});

describe('choreography', () => {
  test('five chapters, contiguous and monotonic, from 0 to 1', () => {
    expect(CHAPTERS.map((c) => c.id)).toEqual(['0', 'I', 'II', 'III', 'IV']);
    expect(CHAPTERS[0].from).toBe(0);
    expect(CHAPTERS[CHAPTERS.length - 1].to).toBe(1);
    for (let i = 0; i < CHAPTERS.length; i++) {
      expect(CHAPTERS[i].to).toBeGreaterThan(CHAPTERS[i].from);
      if (i > 0) expect(CHAPTERS[i].from).toBe(CHAPTERS[i - 1].to);
    }
  });

  test('every phase only moves forward as progress grows, and each one happens inside its own chapter', () => {
    const prev = new Float32Array(8).fill(-Infinity);
    const o = new Float32Array(8);
    const ch = (id: string) => CHAPTERS.find((c) => c.id === id)!;
    const moving = [
      [P_INPUT, 'I'],
      [P_WAVE, 'II'],
      [P_FLY, 'III'],
      [P_FLIP, 'III'],
      [P_RELIGHT, 'III'],
      [P_ROUTE, 'IV'],
      [P_PRESS, 'IV'],
    ] as const;
    let last = new Float32Array(8);
    for (let i = 0; i <= 1000; i++) {
      const t = i / 1000;
      phaseAt(t, 0, d.reach, o);
      for (let k = 0; k < 8; k++) expect(o[k]).toBeGreaterThanOrEqual(prev[k] - 1e-6);
      for (const [k, id] of moving) {
        if (o[k] !== last[k] && i > 0) {
          expect(t).toBeGreaterThanOrEqual(ch(id).from);
          expect(t - 1 / 1000).toBeLessThanOrEqual(ch(id).to);
        }
      }
      prev.set(o);
      last = o.slice();
    }
    // At the end every front has passed every level and the power-on is complete.
    phaseAt(1, 0, d.reach, o);
    expect(o[P_POWER]).toBeGreaterThan(d.maxLevel + 1);
    expect(o[P_WAVE]).toBeGreaterThan(d.maxLevel + 1);
    expect(o[P_RELIGHT]).toBeGreaterThan(d.maxLevel + 1);
    expect([o[P_INPUT], o[P_FLY], o[P_FLIP], o[P_ROUTE], o[P_PRESS]]).toEqual([1, 1, 1, 1, 1]);
    // The time-driven power-on alone completes it at the top of the page.
    phaseAt(0, 1, d.reach, o);
    expect(o[P_POWER]).toBeGreaterThan(d.maxLevel + 1);
    expect(o[P_WAVE]).toBeLessThan(0);
  });

  test('the wavefront covers the levels in order, from before level 0 to past the last one', () => {
    expect(d.reach[0]).toBe(0);
    expect(d.reach[d.reach.length - 1]).toBe(1);
    let p = -Infinity;
    for (let i = 0; i <= 200; i++) {
      const l = levelAt(d.reach, i / 200);
      expect(l).toBeGreaterThanOrEqual(p);
      p = l;
    }
    expect(levelAt(d.reach, 0)).toBeLessThan(-3);
    expect(levelAt(d.reach, 1)).toBeGreaterThan(d.maxLevel + 3);
  });

  test('the camera looks at its target from every keyframe, landscape and portrait', () => {
    const c = new Float32Array(CAM_SIZE);
    const proj = m4();
    const view = m4();
    const vp = m4();
    const ndc = new Float32Array(2);
    for (const portrait of [false, true]) {
      for (let i = 0; i <= 100; i++) {
        cameraAt(i / 100, portrait, portrait ? 390 / 844 : 1.6, c);
        for (let k = 0; k < CAM_SIZE; k++) expect(Number.isFinite(c[k])).toBe(true);
        expect(c[2]).toBeGreaterThan(c[5]); // above what it looks at
        perspective(proj, (28 * Math.PI) / 180, 1.6, 1, 1000);
        lookAt(view, c);
        mul(vp, proj, view);
        expect(project(vp, c[3], c[4], c[5], ndc)).toBe(true);
        expect(Math.abs(ndc[0]) + Math.abs(ndc[1])).toBeLessThan(1e-4);
      }
    }
  });
});

describe('the landing demo as the scene source', () => {
  test('buildScene(landingDemo()) draws exactly what buildScene draws from the files', async () => {
    const demo = await landingDemo();
    const fromDemo = buildScene(demo);
    expect(fromDemo.inst).toEqual(d.inst);
    expect(fromDemo.wires).toEqual(d.wires);
    expect(fromDemo.reach).toEqual(d.reach);
    expect(bytesToHex(fromDemo.outA)).toBe(witness.outA.y);
    expect(bytesToHex(fromDemo.outB)).toBe(witness.outB.y);
    expect(demo.layout.layoutHash).toBe(lay.layoutHash);
  });
});

describe('composed still, sway and framing', () => {
  test('the still shows the beat from state A lit and the seal formed, not yet flipped or pressed', () => {
    const o = new Float32Array(8);
    phaseAt(STILL_T, 1, d.reach, o);
    expect(o[P_POWER]).toBeGreaterThan(d.maxLevel + 1);
    expect(o[P_INPUT]).toBe(1);
    expect(o[P_WAVE]).toBeGreaterThan(d.maxLevel + 1);
    expect(o[P_FLY]).toBe(1);
    expect(o[P_FLIP]).toBe(0);
    expect(o[P_RELIGHT]).toBeLessThan(0);
    expect([o[P_ROUTE], o[P_PRESS]]).toEqual([0, 0]);
    // The still lies in chapter III, after the latches have flown.
    expect(chapterAt(STILL_T)).toBe(CHAPTERS.findIndex((c) => c.id === 'III'));
  });

  test('the still camera looks at the die from above, landscape and portrait', () => {
    const c = new Float32Array(CAM_SIZE);
    const proj = m4();
    const view = m4();
    const vp = m4();
    const ndc = new Float32Array(2);
    for (const [portrait, aspect] of [
      [false, 1.6],
      [true, 390 / 844],
    ] as const) {
      cameraStill(portrait, aspect, c);
      expect(c[2]).toBeGreaterThan(c[5]);
      perspective(proj, (28 * Math.PI) / 180, aspect, 1, 1000);
      lookAt(view, c);
      mul(vp, proj, view);
      // The die's centre is on screen.
      expect(project(vp, 0, 0, 0, ndc)).toBe(true);
      expect(Math.max(Math.abs(ndc[0]), Math.abs(ndc[1]))).toBeLessThan(0.9);
    }
  });

  test('the idle sway stays within ±1.5° and only in chapter 0', () => {
    const max = (SWAY_DEG * Math.PI) / 180;
    let peak = 0;
    for (let s = 0; s < 20; s += 0.05) {
      const a = swayAt(s, 0, 1);
      expect(Math.abs(a)).toBeLessThanOrEqual(max + 1e-12);
      peak = Math.max(peak, Math.abs(a));
      expect(swayAt(s, SWAY_UNTIL, 1)).toBe(0);
      expect(swayAt(s, 0.5, 1)).toBe(0);
      expect(swayAt(s, 0, 0)).toBe(0);
    }
    expect(peak).toBeGreaterThan(max * 0.99);
    expect(SWAY_UNTIL).toBe(CHAPTERS[0].to);
    // The sway turns the camera about its target and nothing else.
    const a = cameraAt(0.02, false, 1.6, new Float32Array(CAM_SIZE), 0);
    const b = cameraAt(0.02, false, 1.6, new Float32Array(CAM_SIZE), max);
    expect([b[3], b[4], b[5], b[9]]).toEqual([a[3], a[4], a[5], a[9]]);
    expect(Math.hypot(b[0] - a[0], b[1] - a[1])).toBeGreaterThan(0);
  });

  test('the die clears the text: right of it on wide screens, above it on tall ones', () => {
    const o = new Float32Array(2);
    lensShift(1.6, o);
    expect([o[0], o[1]]).toEqual([expect.closeTo(0.36, 6), 0]);
    lensShift(1.3, o);
    expect([o[0], o[1]]).toEqual([expect.closeTo(0.18, 6), 0]);
    lensShift(1, o);
    expect([o[0], o[1]]).toEqual([0, 0]);
    lensShift(390 / 844, o);
    expect([o[0], o[1]]).toEqual([0, expect.closeTo(0.3, 6)]);
    expect(lensShift(3, o)[0]).toBeCloseTo(0.36, 6);
  });
});

describe('stage scroll mapping', () => {
  // A desktop track: viewport 900, hero 900, chapters I..IV, tail 1080 (scene.css proportions).
  const vh = 900;
  const heights = [900, 420, 700, 520, 470];
  const blocks: StageBlock[] = [];
  let top = 0;
  for (const h of heights) {
    blocks.push({ top, height: h });
    top += h;
  }
  const trackHeight = top + 1080;
  const a = stageAnchors(trackHeight, vh, blocks);

  test('anchors: chapter 0 at the top, later chapters when their block crosses the middle, then the handoff', () => {
    expect(a.length).toBe(CHAPTERS.length + 2);
    expect(a[0]).toBe(0);
    for (let i = 1; i < CHAPTERS.length; i++) expect(a[i]).toBe(blocks[i].top - LEAD * vh);
    expect(a[CHAPTERS.length]).toBe(blocks[4].top + blocks[4].height - LEAD_END * vh);
    expect(a[CHAPTERS.length + 1]).toBe(trackHeight - vh);
    for (let i = 1; i < a.length; i++) expect(a[i]).toBeGreaterThanOrEqual(a[i - 1]);
  });

  test('progress is continuous and non-decreasing, hits each chapter boundary at its anchor, then hands off', () => {
    const p = { t: 0, chapter: 0, handoff: 0 };
    let last = { t: -1, handoff: -1, chapter: 0 };
    for (let s = -200; s <= trackHeight; s += 3) {
      stageProgress(s, a, p);
      expect(p.t).toBeGreaterThanOrEqual(last.t);
      expect(p.handoff).toBeGreaterThanOrEqual(last.handoff);
      expect(p.chapter).toBeGreaterThanOrEqual(last.chapter);
      if (last.t >= 0) expect(p.t - last.t).toBeLessThan(0.02);
      expect(p.chapter).toBe(chapterAt(Math.min(p.t, 0.999)));
      if (p.handoff > 0) expect(p.t).toBe(1);
      last = { ...p };
    }
    for (let i = 0; i < CHAPTERS.length; i++) {
      stageProgress(a[i], a, p);
      expect(p.t).toBeCloseTo(CHAPTERS[i].from, 9);
      expect(p.chapter).toBe(i);
    }
    expect(stageProgress(a[5], a, p)).toEqual({ t: 1, chapter: 4, handoff: 0 });
    expect(stageProgress((a[5] + a[6]) / 2, a, p).handoff).toBeCloseTo(0.5, 9);
    expect(stageProgress(a[6] + 500, a, p)).toEqual({ t: 1, chapter: 4, handoff: 1 });
    expect(stageProgress(-50, a, p)).toEqual({ t: 0, chapter: 0, handoff: 0 });
  });

  test('without one block per chapter, the chapters share the track by length and there is no handoff', () => {
    const b = stageAnchors(4 * vh, vh, []);
    for (let i = 0; i < CHAPTERS.length; i++) expect(b[i]).toBeCloseTo(CHAPTERS[i].from * 3 * vh, 9);
    expect([b[5], b[6]]).toEqual([3 * vh, 3 * vh]);
    expect(stageProgress(1.5 * vh, b).t).toBeCloseTo(0.5, 9);
    expect(stageProgress(5 * vh, b).handoff).toBe(0);
  });

  test('a chapter block taller than its share only stretches its own chapter', () => {
    const tall = blocks.map((x) => ({ ...x }));
    tall[2].height += 600;
    for (let i = 3; i < tall.length; i++) tall[i].top += 600;
    const b = stageAnchors(trackHeight + 600, vh, tall);
    expect(b[2] - b[1]).toBe(a[2] - a[1]);
    expect(b[3] - b[2]).toBe(a[3] - a[2] + 600);
    expect(b[4] - b[3]).toBe(a[4] - a[3]);
  });

  test('scene.css gives the blocks of chapters I to IV room in proportion to their length in the scene', () => {
    const css = readFileSync(new URL('../src/styles/scene.css', import.meta.url), 'utf8');
    for (let i = 1; i < CHAPTERS.length; i++) {
      const m = css.match(new RegExp(`\\.die-stage__block\\[data-block='${i}'\\] \\{\\s*flex-grow: (\\d+);`));
      expect(m, `flex-grow of block ${i}`).not.toBeNull();
      expect(Number(m![1])).toBe(Math.round((CHAPTERS[i].to - CHAPTERS[i].from) * 100));
    }
  });
});

describe('the lazy stage chunk', () => {
  // DieStage.tsx and everything it imports statically land in one chunk the landing loads with import(). It must
  // not pull in the netlist bytes, the simulator or the die-shot renderer: kernel/demo.ts and kernel/sim.ts are the
  // only modules that load the netlist (web/NOTES.md section 9), and the Canvas 2D fallback is a further import().
  const chunk = ['DieStage.tsx', 'index.ts', 'gl.ts', 'choreo.ts', 'data.ts', 'math.ts', 'scroll.ts'];
  const allowed = new Set([
    'preact',
    'preact/hooks',
    '../components/Seal.tsx',
    '../kernel/demo.ts',
    '../kernel/model.ts',
    '../motion/prefs.ts',
    '../styles/scene.css',
    '@covenant/tap20',
    '@covenant/dieshot',
    './fallback.ts',
    ...chunk.map((f) => `./${f}`),
  ]);
  const typeOnly = new Set(['@covenant/dieshot', '../kernel/demo.ts', './fallback.ts']);
  const read = (f: string): string => readFileSync(new URL(`../src/scene/${f}`, import.meta.url), 'utf8');

  test.each(chunk)('%s imports only what the chunk may carry', (f) => {
    const text = read(f);
    for (const m of text.matchAll(/^import\s+(type\s+)?(?:[^'";]*?\s+from\s+)?'([^']+)';/gm)) {
      const spec = m[2];
      expect(allowed.has(spec), `${f} imports ${spec}`).toBe(true);
      if (typeOnly.has(spec)) expect(m[1], `${f} imports ${spec} as a type only`).toBeTruthy();
      if (spec === '@covenant/tap20') expect(m[0]).toMatch(/\{ hexToBytes, type Netlist \}/);
    }
    expect(text).not.toMatch(/\?raw|fg\.hex|kernel\/sim/);
  });

  test('the fallback is loaded on demand only', () => {
    expect(read('DieStage.tsx')).toMatch(/import\('\.\/fallback\.ts'\)/);
  });
});

describe('the Canvas 2D fallback', () => {
  test('draws in the brand silicon colours', () => {
    const tokens = readFileSync(new URL('../src/styles/tokens.css', import.meta.url), 'utf8');
    const token = (name: string): string => tokens.match(new RegExp(`--${name}: (#[0-9a-f]{6});`))![1];
    expect(THEME_SILICON.bg).toBe(token('wafer'));
    expect(THEME_SILICON.strip).toBe(token('wafer-2'));
    expect(THEME_SILICON.on).toBe(token('bond'));
    expect(THEME_SILICON.padOn).toBe(token('bond'));
    expect(THEME_SILICON.latchOn).toBe(token('quartz'));
    expect(THEME_SILICON.label).toBe(token('quartz-2'));
  });
});
