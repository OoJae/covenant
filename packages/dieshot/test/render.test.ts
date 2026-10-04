// The renderer against a recording fake of Canvas 2D: what is lit in a still frame, how a beat
// plays out frame by frame, picking, and the per-frame cost at 5,000 gates.

import { describe, expect, test } from 'vitest';
import { packBits, step, unpackBits, type Netlist } from '@covenant/tap20';
import { createDieShot, KIND_LATCH, THEME_DARK, THEME_LIGHT, type DieShot } from '../src/index.ts';
import { FakeCanvas, manualFrames, prng, synthetic } from './helpers.ts';

function setup(nl: Netlist, extra: Record<string, unknown> = {}) {
  const canvas = new FakeCanvas();
  const layers: FakeCanvas[] = [];
  const frames = manualFrames();
  const die = createDieShot(canvas as unknown as HTMLCanvasElement, nl, {
    dpr: 2,
    createCanvas: (w: number, h: number) => {
      const c = new FakeCanvas();
      c.width = w;
      c.height = h;
      layers.push(c);
      return c as unknown as HTMLCanvasElement;
    },
    requestFrame: frames.request,
    cancelFrame: frames.cancel,
    ...extra,
  });
  return { canvas, ctx: canvas.context, layers, frames, die };
}

function randomPacked(rnd: () => number, n: number): Uint8Array {
  const bits = new Uint8Array(n);
  for (let i = 0; i < n; i++) bits[i] = rnd() & 1;
  return packBits(bits);
}

const ones = (a: ArrayLike<number>): number => {
  let k = 0;
  for (let i = 0; i < a.length; i++) if (a[i]) k++;
  return k;
};

// How many cells of each kind a still frame should light.
function expectedLit(nl: Netlist, die: DieShot, signals: ArrayLike<number>, state: Uint8Array, inputs: Uint8Array) {
  let logic = 0;
  for (let s = 2 + nl.nIn; s < nl.nSignals; s++) if (die.layout.kind[s] !== KIND_LATCH && signals[s]) logic++;
  let outs = 0;
  for (let j = 0; j < nl.nOut; j++) if (signals[nl.nSignals - nl.nOut + j]) outs++;
  return { logic, latches: ones(unpackBits(state, nl.nState)), pads: 1 + ones(unpackBits(inputs, nl.nIn)) + outs };
}

describe('still frames', () => {
  const nl = synthetic(24, 16, 40, 900, 17);
  const rnd = prng(5);
  const state = randomPacked(rnd, nl.nState);
  const inputs = randomPacked(rnd, nl.nIn);
  const beat = step(nl, state, inputs);

  test('the canvas is sized from the layout, the requested width and the pixel ratio', () => {
    const { canvas, die, layers } = setup(nl);
    expect(die.width).toBe(2 * 7 + die.layout.cols * 7 - 2);
    expect(die.height).toBe(2 * 7 + die.layout.rows * 7 - 2);
    die.resize(die.width / 2);
    expect(canvas.width).toBe(die.width);
    expect(canvas.height).toBe(die.height);
    expect(canvas.style.width).toBe(`${die.width / 2}px`);
    expect(layers.length).toBe(1);
    expect(layers[0].width).toBe(canvas.width);
    // a small circuit is magnified, but never beyond maxScale
    die.resize(100000);
    expect(canvas.style.width).toBe(`${die.width * 4}px`);
    // one offscreen layer for the lifetime of the renderer, resized with the canvas
    expect(layers.length).toBe(1);
    expect(layers[0].width).toBe(canvas.width);
    // resizing to the same width does not redraw the static layer
    const calls = layers[0].context.calls;
    die.resize(100000);
    expect(layers[0].context.calls).toBe(calls);
  });

  test('nothing run yet: only the constant-1 pad is lit', () => {
    const { ctx, die } = setup(nl);
    die.resize(400);
    ctx.reset();
    die.draw();
    expect(ctx.images).toBe(1);
    expect(ctx.filledRects.get(THEME_DARK.on)).toBe(0);
    expect(ctx.filledRects.get(THEME_DARK.latchOn)).toBe(0);
    expect(ctx.filledRects.get(THEME_DARK.padOn)).toBe(1);
  });

  test('a still frame lights exactly the cells whose value is 1', () => {
    const { ctx, die } = setup(nl);
    die.resize(400);
    ctx.reset();
    die.draw(beat.signals, state, inputs);
    const want = expectedLit(nl, die, beat.signals, state, inputs);
    expect(want.logic).toBeGreaterThan(100);
    expect(ctx.filledRects.get(THEME_DARK.on)).toBe(want.logic);
    expect(ctx.filledRects.get(THEME_DARK.latchOn)).toBe(want.latches);
    expect(ctx.filledRects.get(THEME_DARK.padOn)).toBe(want.pads);
    expect(ctx.fillRects.get(THEME_DARK.pulse)).toBeUndefined(); // no pulses in a still frame
  });

  test('the register strip and the input pads can show values newer than the signals', () => {
    const { ctx, die } = setup(nl);
    die.resize(400);
    ctx.reset();
    const zeros = new Uint8Array(nl.nIn >> 3);
    die.draw(beat.signals, beat.newState, zeros);
    const want = expectedLit(nl, die, beat.signals, beat.newState, zeros);
    expect(ctx.filledRects.get(THEME_DARK.latchOn)).toBe(want.latches);
    expect(ctx.filledRects.get(THEME_DARK.padOn)).toBe(want.pads);
    // without a state, the strip shows the LATCH outputs of the signals, i.e. the old state
    ctx.reset();
    die.draw(beat.signals);
    expect(ctx.filledRects.get(THEME_DARK.latchOn)).toBe(ones(unpackBits(state, nl.nState)));
  });

  test('the static layer holds the wires, the dark cells and nothing per-frame', () => {
    const { die, layers } = setup(nl);
    die.resize(400);
    const base = layers[0].context;
    // per record: one stroke for its logic wires and one for its state-loop wires (if it has
    // any of that sort), plus one per output pad
    expect(base.strokes).toBeGreaterThan(nl.nNand / 2);
    expect(base.strokes).toBeLessThanOrEqual(2 * nl.n + nl.nOut);
    expect(base.fillRects.get(THEME_DARK.off)).toBe(nl.nNand);
    expect(base.fillRects.get(THEME_DARK.latchOff)).toBe(nl.nLatch);
    expect(base.fillRects.get(THEME_DARK.padOff)).toBe(2 + nl.nIn + nl.nOut);
  });

  test('changing the theme redraws the static layer in the new colours', () => {
    const { ctx, die, layers } = setup(nl);
    die.resize(400);
    die.draw(beat.signals, state, inputs);
    layers[0].context.reset();
    die.setTheme(THEME_LIGHT);
    expect(layers.length).toBe(1);
    expect(layers[0].context.fillRects.get(THEME_LIGHT.off)).toBe(nl.nNand);
    expect(layers[0].context.fillRects.get(THEME_DARK.off)).toBeUndefined();
    ctx.reset();
    die.draw(beat.signals, state, inputs);
    expect(ctx.filledRects.get(THEME_LIGHT.on)).toBe(expectedLit(nl, die, beat.signals, state, inputs).logic);
  });

  test('a block map adds outlines and labels to the static layer', () => {
    const blocks = { names: ['alpha', 'beta'], runs: [{ first: 0, count: 500, block: 0 }, { first: 500, count: 440, block: 1 }] };
    const { die, layers } = setup(nl, { blocks });
    die.resize(400);
    expect(die.layout.blocks.map((b) => b.name)).toEqual(['alpha', 'beta']);
    expect(layers[0].context.calls).toBeGreaterThan(0);
    expect(die.layout.layoutHash).not.toBe(setup(nl).die.layout.layoutHash);
  });
});

describe('animate', () => {
  const nl = synthetic(24, 16, 40, 900, 17);
  const rnd = prng(8);
  const s0 = randomPacked(rnd, nl.nState);
  const x0 = randomPacked(rnd, nl.nIn);
  const b0 = step(nl, s0, x0);
  const x1 = randomPacked(rnd, nl.nIn);
  const b1 = step(nl, b0.newState, x1);

  test('a beat plays from the old values to the new ones and ends on the final frame', async () => {
    const { ctx, die, frames } = setup(nl);
    die.resize(400);
    die.draw(b0.signals, b0.newState, x0);
    let resolved = false;
    const done = die.animate(b0.signals, b1.signals, b0.newState, b1.newState, 1000).then(() => {
      resolved = true;
    });
    const before = expectedLit(nl, die, b0.signals, b0.newState, x0);
    const after = expectedLit(nl, die, b1.signals, b1.newState, x1);
    const changed = ones(b1.signals.map((v, s) => (s >= 2 + nl.nIn && die.layout.kind[s] !== KIND_LATCH && v !== b0.signals[s] ? 1 : 0)));
    expect(changed).toBeGreaterThan(50);

    // first frame (t = 0): logic and outputs still show the old beat; the strip shows the
    // state this beat starts from
    ctx.reset();
    expect(frames.advance(0)).toBe(1);
    expect(ctx.filledRects.get(THEME_DARK.on)).toBe(before.logic);
    expect(ctx.filledRects.get(THEME_DARK.latchOn)).toBe(before.latches);

    // mid-sweep: a mix of old and new, with pulses on changed cells
    ctx.reset();
    frames.advance(400);
    const mid = ctx.filledRects.get(THEME_DARK.on)!;
    expect(ctx.fillRects.get(THEME_DARK.pulse)).toBeGreaterThan(0);
    expect(mid).toBeGreaterThan(0);
    expect(ctx.filledRects.get(THEME_DARK.latchOn)).toBe(before.latches); // clock edge not reached

    // after the sweep, before the clock edge: all logic is new, the strip is still old
    ctx.reset();
    frames.advance(380); // t = 0.78
    expect(ctx.filledRects.get(THEME_DARK.on)).toBe(after.logic);
    expect(ctx.filledRects.get(THEME_DARK.latchOn)).toBe(before.latches);
    expect(ctx.filledRects.get(THEME_DARK.padOn)).toBe(after.pads);

    // after the clock edge the strip has flipped
    ctx.reset();
    frames.advance(70); // t = 0.85
    expect(ctx.filledRects.get(THEME_DARK.latchOn)).toBe(after.latches);
    expect(resolved).toBe(false);

    // last frame
    ctx.reset();
    frames.advance(200);
    await done;
    expect(resolved).toBe(true);
    expect(frames.pending()).toBe(0);
    expect(ctx.filledRects.get(THEME_DARK.on)).toBe(after.logic);
    expect(ctx.filledRects.get(THEME_DARK.latchOn)).toBe(after.latches);
    expect(ctx.fillRects.get(THEME_DARK.pulse)).toBeUndefined();
  });

  test('cells light in level order: a cell is never shown new before the cells that feed it', async () => {
    const { ctx, die, frames } = setup(nl);
    die.resize(die.width); // magnification 1: a cell at (x, y) is drawn at (7 + 7x, 7 + 7y)
    const lay = die.layout;
    // From all-dark, a logic cell is drawn lit exactly when the wavefront has reached it and
    // its value is 1. So in every frame, each lit cell's 1-valued logic inputs must be lit too.
    const done = die.animate(null, b1.signals, b0.newState, b1.newState, 1000);
    frames.advance(0);
    let partial = 0;
    let previous = 0;
    const total = expectedLit(nl, die, b1.signals, b1.newState, x1).logic;
    for (let t = 10; t <= 1000; t += 10) {
      ctx.reset();
      frames.advance(10);
      const lit = new Set<number>();
      for (const [px, py] of ctx.filledAt.get(THEME_DARK.on) ?? []) lit.add(lay.grid[((py - 7) / 7) * lay.cols + (px - 7) / 7]);
      expect(lit.size).toBeGreaterThanOrEqual(previous); // the front only moves forward
      previous = lit.size;
      if (lit.size > 0 && lit.size < total) partial++;
      for (const s of lit) {
        const e = lay.element[s];
        for (const src of [nl.a[e], nl.b[e]]) {
          if (src >= 2 + nl.nIn && lay.kind[src] !== KIND_LATCH && b1.signals[src]) expect(lit.has(src)).toBe(true);
        }
      }
    }
    await done;
    expect(previous).toBe(total);
    expect(partial).toBeGreaterThan(20); // the sweep really is spread over many frames
  });

  test('duration 0 jumps to the final frame and resolves at once', async () => {
    const { ctx, die, frames } = setup(nl);
    die.resize(400);
    ctx.reset();
    await die.animate(b0.signals, b1.signals, b0.newState, b1.newState, 0);
    expect(frames.pending()).toBe(0);
    const after = expectedLit(nl, die, b1.signals, b1.newState, x1);
    expect(ctx.filledRects.get(THEME_DARK.on)).toBe(after.logic);
    expect(ctx.filledRects.get(THEME_DARK.latchOn)).toBe(after.latches);
  });

  test('a new beat, a still frame or cancel() ends a running animation and resolves its promise', async () => {
    const { ctx, die, frames } = setup(nl);
    die.resize(400);
    const first = die.animate(null, b0.signals, s0, b0.newState, 1000);
    frames.advance(0);
    frames.advance(300);
    const second = die.animate(b0.signals, b1.signals, b0.newState, b1.newState, 1000);
    await first;
    frames.advance(0);
    frames.advance(100);
    ctx.reset();
    die.cancel();
    await second;
    const after = expectedLit(nl, die, b1.signals, b1.newState, x1);
    expect(ctx.filledRects.get(THEME_DARK.on)).toBe(after.logic);
    expect(frames.pending()).toBe(0);
    const third = die.animate(b1.signals, b0.signals, b1.newState, b0.newState, 1000);
    frames.advance(0);
    die.draw(b0.signals, b0.newState);
    await third;
    const fourth = die.animate(null, b0.signals, s0, b0.newState, 1000);
    die.destroy();
    await fourth;
  });

  test('the first beat (no previous signals) pulses every cell that comes up 1', async () => {
    const { ctx, die, frames } = setup(nl);
    die.resize(400);
    const done = die.animate(null, b0.signals, s0, b0.newState, 1000);
    frames.advance(0);
    ctx.reset();
    frames.advance(300);
    expect(ctx.fillRects.get(THEME_DARK.pulse)).toBeGreaterThan(0);
    frames.advance(800);
    await done;
  });
});

describe('picking and selection', () => {
  const nl = synthetic(24, 16, 40, 900, 17);

  test('the centre of every cell picks its signal; output pads pick their driver and index', () => {
    const { die } = setup(nl);
    die.resize(die.width); // magnification 1
    const lay = die.layout;
    for (let s = 0; s < nl.nSignals; s++) {
      expect(die.pick(7 + lay.x[s] * 7 + 2.5, 7 + lay.y[s] * 7 + 2.5)).toEqual({ signal: s, output: -1 });
    }
    for (let j = 0; j < nl.nOut; j++) {
      expect(die.pick(7 + lay.outX[j] * 7 + 2.5, 7 + lay.outY[j] * 7 + 2.5)).toEqual({ signal: nl.nSignals - nl.nOut + j, output: j });
    }
    expect(die.pick(-5, -5)).toBeNull();
    expect(die.pick(die.width + 50, 10)).toBeNull();
    // the gap column between the pads and the logic is empty
    expect(die.pick(7 + (lay.core.x - 1) * 7 + 2.5, 7 + 2.5)).toBeNull();
  });

  test('picking follows the magnification', () => {
    const { die } = setup(nl);
    die.resize(die.width * 2);
    const lay = die.layout;
    const s = nl.nSignals - 1;
    expect(die.pick(2 * (7 + lay.x[s] * 7 + 2.5), 2 * (7 + lay.y[s] * 7 + 2.5))).toEqual({ signal: s, output: -1 });
  });

  test('select draws the cell outline and its input wires on top of the frame', () => {
    const { ctx, die } = setup(nl);
    die.resize(400);
    die.draw();
    ctx.reset();
    die.select(nl.nSignals - 1);
    expect(ctx.strokes).toBe(1);
    expect(ctx.images).toBe(1);
    ctx.reset();
    die.select(nl.nSignals - 1); // no change, no repaint
    expect(ctx.calls).toBe(0);
    die.select(nl.nSignals - 1, 0);
    expect(ctx.strokes).toBe(1);
    ctx.reset();
    die.select(-1);
    expect(ctx.strokes).toBe(0);
  });
});

describe('cost per frame', () => {
  test('5,000 gates: the per-frame work stays far below a 16 ms frame', async () => {
    const nl = synthetic(133, 199, 243, 4757, 41);
    expect(nl.gateCount).toBe(5000);
    const { ctx, die, frames } = setup(nl);
    die.resize(700);
    const rnd = prng(3);
    const s0 = randomPacked(rnd, nl.nState);
    const b0 = step(nl, s0, randomPacked(rnd, nl.nIn));
    const b1 = step(nl, b0.newState, randomPacked(rnd, nl.nIn));
    const done = die.animate(b0.signals, b1.signals, b0.newState, b1.newState, 2400);
    frames.advance(0);
    const t0 = performance.now();
    let n = 0;
    while (frames.pending()) {
      frames.advance(16);
      n++;
    }
    const perFrame = (performance.now() - t0) / n;
    await done;
    expect(n).toBeGreaterThanOrEqual(150);
    // Drawing calls go to a fake here, so this bounds the JavaScript side only; the real
    // rasterisation is measured in a browser (see web/NOTES.md).
    expect(perFrame).toBeLessThan(4);
    // one image copy and a bounded number of path/fill calls per frame, whatever the gate count
    ctx.reset();
    die.draw(b1.signals, b1.newState);
    expect(ctx.images).toBe(1);
    expect(ctx.calls).toBeLessThan(nl.nSignals + 200);
  });
});
