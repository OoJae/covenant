// Canvas 2D renderer for a die-shot layout.
//
// Static parts (background, wires at low alpha, dark cells, block outlines) are drawn once to
// an offscreen layer. Each frame copies that layer and draws only the activity on top: cells
// whose value is 1, pulses on cells whose value changed, the register strip and the pads.

import {
  KIND_LATCH,
  layout as computeLayout,
  type BlockMap,
  type DieNetlist,
  type Layout,
} from './layout.ts';

export interface Theme {
  /** Die background and the logic area on it. */
  bg: string;
  core: string;
  /** Band behind a register strip. */
  strip: string;
  /** Wires between logic cells, and wires on the state loop (into and out of LATCH cells). */
  wire: string;
  feedback: string;
  /** Logic cell holding 0 / 1. */
  off: string;
  on: string;
  /** LATCH cell holding 0 / 1. */
  latchOff: string;
  latchOn: string;
  /** Pad holding 0 / 1. */
  padOff: string;
  padOn: string;
  /** Flash on a cell whose value changed, and the wavefront line. */
  pulse: string;
  /** Block outline, block label, and the highlight of a selected cell. */
  outline: string;
  label: string;
  select: string;
}

export const THEME_DARK: Theme = {
  bg: '#0a0e13',
  core: '#0e141b',
  strip: '#0d222a',
  wire: '#6ea8ff',
  feedback: '#ffa94d',
  off: '#1b2632',
  on: '#ffd166',
  latchOff: '#173640',
  latchOn: '#3ee0cf',
  padOff: '#27313d',
  padOn: '#7ee787',
  pulse: '#ffffff',
  outline: '#2c3b4c',
  label: '#93a7bb',
  select: '#ff6bf3',
};

export const THEME_LIGHT: Theme = {
  bg: '#f4f1e8',
  core: '#ece8dc',
  strip: '#dde7e2',
  wire: '#2f5d9e',
  feedback: '#b45309',
  off: '#d6d1c2',
  on: '#d9480f',
  latchOff: '#bcd0ca',
  latchOn: '#0f766e',
  padOff: '#c9c5b8',
  padOn: '#2b8a3e',
  pulse: '#111111',
  outline: '#b3ac99',
  label: '#5f5a4d',
  select: '#7c3aed',
};

type AnyCanvas = HTMLCanvasElement | OffscreenCanvas;

export interface DieShotOptions {
  /** Named runs of records; blocks are then packed by a squarified treemap. */
  blocks?: BlockMap;
  theme?: Theme;
  /** Cell size and cell pitch in layout pixels. Defaults 5 and 7. */
  cell?: number;
  pitch?: number;
  /** Largest magnification used to make a small circuit fill the width. Default 4. */
  maxScale?: number;
  /** Device pixel ratio. Default `devicePixelRatio`, or 1. */
  dpr?: number;
  /** Length of `animate` in milliseconds. Default 2400. */
  duration?: number;
  /** Alpha of the wires on the static layer. Default 0.08. */
  wireAlpha?: number;
  /** Replaceable for tests and non-DOM hosts. */
  createCanvas?: (width: number, height: number) => AnyCanvas;
  requestFrame?: (cb: (time: number) => void) => number;
  cancelFrame?: (id: number) => void;
}

export interface Picked {
  /** The signal in the cell; for an output pad, the signal that drives it. */
  signal: number;
  /** Output pad index, or -1 if the cell is not an output pad. */
  output: number;
}

/** A vector of bits packed LSB-first into bytes (TAP-20 section 5), or nothing. */
type Packed = ArrayLike<number> | null | undefined;
/** One entry (0 or 1) per signal, or nothing. */
type Signals = ArrayLike<number> | null | undefined;

export interface DieShot {
  readonly layout: Layout;
  /** Size in CSS pixels at magnification 1. */
  readonly width: number;
  readonly height: number;
  /** Fit the canvas to this many CSS pixels of width (never above `maxScale`). */
  resize(cssWidth: number): void;
  /**
   * Draw a still frame. `signals`: value of every signal (nothing = all dark). `state`: packed
   * state shown on the register strip (nothing = the LATCH outputs in `signals`). `inputs`:
   * packed inputs shown on the input pads (nothing = the input signals in `signals`).
   */
  draw(signals?: Signals, state?: Packed, inputs?: Packed): void;
  /**
   * Play one beat: a wavefront sweeps the levels, lighting cells whose value in `signals` is 1
   * and pulsing cells that differ from `previousSignals`; output pads resolve; then the clock
   * edge flips the register strip from `stateBefore` to `stateAfter` (both packed).
   * Resolves when the last frame is drawn, or at once if another draw or animate replaces it.
   */
  animate(previousSignals: Signals, signals: ArrayLike<number>, stateBefore: Packed, stateAfter: Packed, duration?: number): Promise<void>;
  /** Stop a running animation and show its final frame. */
  cancel(): void;
  /** The cell under a point given in CSS pixels relative to the canvas, if any. */
  pick(x: number, y: number): Picked | null;
  /** Highlight a signal's cell and the wires feeding it (-1 clears). */
  select(signal: number, output?: number): void;
  setTheme(theme: Theme): void;
  destroy(): void;
}

// Fractions of the animation: sweep from SWEEP0 to SWEEP1, outputs resolve at OUT, clock at CLOCK.
const SWEEP0 = 0.05;
const SWEEP1 = 0.7;
const OUT = 0.74;
const CLOCK = 0.82;
const PULSE = 0.11;
const CLOCK_PULSE = 0.16;

const bitOf = (bytes: Packed, i: number): number =>
  bytes && i >> 3 < bytes.length ? (bytes[i >> 3] >> (i & 7)) & 1 : 0;

export function createDieShot(canvas: HTMLCanvasElement, nl: DieNetlist, opts: DieShotOptions = {}): DieShot {
  const lay = computeLayout(nl, opts.blocks);
  const P = opts.pitch ?? 7;
  const C = opts.cell ?? 5;
  const G = P - C;
  const M = P; // margin around the die
  const W = 2 * M + lay.cols * P - G;
  const H = 2 * M + lay.rows * P - G;
  const S = nl.nSignals;
  const first = 2 + nl.nIn;
  const maxScale = opts.maxScale ?? 4;
  const wireAlpha = opts.wireAlpha ?? 0.08;
  const defaultDuration = opts.duration ?? 2400;
  const raf = opts.requestFrame ?? ((cb: (t: number) => void) => requestAnimationFrame(cb));
  const caf = opts.cancelFrame ?? ((id: number) => cancelAnimationFrame(id));
  const makeCanvas =
    opts.createCanvas ??
    ((w: number, h: number): AnyCanvas => {
      const c = document.createElement('canvas');
      c.width = w;
      c.height = h;
      return c;
    });
  const ctx = canvas.getContext('2d')!;
  let theme = opts.theme ?? THEME_DARK;
  let dpr = opts.dpr ?? (typeof devicePixelRatio === 'number' ? devicePixelRatio : 1);
  let scale = 1;
  let base: AnyCanvas | null = null;

  // Pixel origin of every signal's cell and of every output pad.
  const X = new Float32Array(S);
  const Y = new Float32Array(S);
  for (let s = 0; s < S; s++) {
    X[s] = M + lay.x[s] * P;
    Y[s] = M + lay.y[s] * P;
  }
  const OX = new Float32Array(nl.nOut);
  const OY = new Float32Array(nl.nOut);
  for (let j = 0; j < nl.nOut; j++) {
    OX[j] = M + lay.outX[j] * P;
    OY[j] = M + lay.outY[j] * P;
  }

  // Logic cells and LATCH cells, and the state bit each LATCH cell shows.
  const logic: number[] = [];
  const latch: number[] = [];
  const latchBit: number[] = [];
  for (let s = first; s < S; s++) {
    if (lay.kind[s] === KIND_LATCH) {
      latch.push(s);
      latchBit.push(nl.stateBase[lay.element[s]]);
    } else logic.push(s);
  }

  // When the wavefront reaches each level, as a fraction of the sweep: half by level number,
  // half by the share of cells below that level, so neither a crowded level nor a long tail of
  // sparse ones takes the whole sweep. `below[l]` = logic cells with a level under l.
  const below = new Uint32Array(lay.maxLevel + 2);
  for (const s of logic) below[lay.level[s] + 1]++;
  for (let l = 1; l < below.length; l++) below[l] += below[l - 1];
  const reach = new Float32Array(lay.maxLevel + 2);
  for (let l = 0; l < reach.length; l++) {
    reach[l] = (0.5 * l) / (lay.maxLevel + 1) + (0.5 * below[l]) / Math.max(1, logic.length);
  }

  // What is on screen. `prev` shows through wherever the wavefront has not arrived yet.
  let cur: Signals = null;
  let prev: Signals = null;
  let before: Packed = null;
  let after: Packed = null;
  let pads: Packed = null;
  let progress = 1;
  let frame = 0;
  let settle: (() => void) | null = null;
  let selSignal = -1;
  let selOutput = -1;

  // A wire from the cell at (sx, sy) to the cell at (dx, dy), all in pixels: down into the
  // gap under the source row, along it, then up or down the gap beside the destination column.
  // `track` (0 or 1) picks one of the two pixel tracks of a gap.
  const wire = (c: CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D, sx: number, sy: number, dx: number, dy: number, track: number): void => {
    const fromLeft = sx <= dx;
    const xh = sx + C / 2;
    const yh = sy + C + 0.5 + track;
    const xv = fromLeft ? dx - 0.5 - track : dx + C + 0.5 + track;
    const yd = dy + C / 2;
    c.moveTo(xh, sy + C);
    c.lineTo(xh, yh);
    c.lineTo(xv, yh);
    c.lineTo(xv, yd);
    c.lineTo(fromLeft ? dx : dx + C, yd);
  };

  // The signals that feed a cell: a and b of a NAND, d of a LATCH, the inputs of a REF.
  const sources = (s: number): number[] => {
    const e = lay.element[s];
    if (e < 0) return [];
    const op = nl.op[e];
    if (op === 0) return nl.a[e] === nl.b[e] ? [nl.a[e]] : [nl.a[e], nl.b[e]];
    if (op === 1) return [nl.a[e]];
    return Array.from(nl.refs[nl.b[e]].ins);
  };

  const renderBase = (): void => {
    const k = scale * dpr;
    // One offscreen canvas for the lifetime of the renderer; setting its size clears it.
    if (!base) base = makeCanvas(canvas.width, canvas.height);
    else {
      base.width = canvas.width;
      base.height = canvas.height;
    }
    const c = (base as HTMLCanvasElement).getContext('2d')!;
    c.globalAlpha = 1;
    c.setTransform(k, 0, 0, k, 0, 0);
    c.fillStyle = theme.bg;
    c.fillRect(0, 0, W, H);
    c.fillStyle = theme.core;
    c.fillRect(M + lay.core.x * P - G, M - G, lay.core.w * P + G, lay.core.h * P + G);
    c.fillStyle = theme.strip;
    for (const b of lay.blocks) {
      if (b.latches > 0) c.fillRect(M + b.stripX * P - G / 2, M + b.y * P - G / 2, (b.x + b.w - b.stripX) * P, b.h * P);
    }

    // Wires. Each record is stroked on its own so that overlapping wires add up and busy
    // channels come out brighter. Wires from the two constants are not drawn.
    c.lineWidth = 1;
    c.globalAlpha = wireAlpha;
    for (let pass = 0; pass < 2; pass++) {
      // pass 0: logic to logic; pass 1: the state loop (out of and into LATCH cells)
      c.strokeStyle = pass ? theme.feedback : theme.wire;
      for (let s = first; s < S; s++) {
        if (lay.element[s] === lay.element[s - 1] && s > first) continue; // further outputs of one REF
        const src = sources(s);
        let any = false;
        for (let i = 0; i < src.length; i++) {
          const from = src[i];
          if (from < 2) continue;
          const loop = lay.kind[s] === KIND_LATCH || lay.kind[from] === KIND_LATCH;
          if (loop !== (pass === 1)) continue;
          if (!any) c.beginPath();
          any = true;
          wire(c, X[from], Y[from], X[s], Y[s], i & 1);
        }
        if (any) c.stroke();
      }
    }
    c.strokeStyle = theme.wire;
    for (let j = 0; j < nl.nOut; j++) {
      const s = S - nl.nOut + j;
      c.beginPath();
      wire(c, X[s], Y[s], OX[j], OY[j], 0);
      c.stroke();
    }
    c.globalAlpha = 1;

    // Cells holding 0: logic, register strip, pads.
    c.fillStyle = theme.off;
    for (const s of logic) c.fillRect(X[s], Y[s], C, C);
    c.fillStyle = theme.latchOff;
    for (const s of latch) c.fillRect(X[s], Y[s], C, C);
    c.fillStyle = theme.padOff;
    for (let s = 0; s < first; s++) c.fillRect(X[s], Y[s], C, C);
    for (let j = 0; j < nl.nOut; j++) c.fillRect(OX[j], OY[j], C, C);

    // Block outlines and names, when a block map was given.
    if (lay.blocks.length > 1) {
      c.strokeStyle = theme.outline;
      c.font = '8px system-ui, sans-serif';
      c.textBaseline = 'top';
      for (const b of lay.blocks) {
        const bx = M + b.x * P - G / 2;
        const by = M + b.y * P - G / 2;
        c.strokeRect(bx, by, b.w * P, b.h * P);
        if (b.name) {
          const tw = c.measureText(b.name).width;
          c.globalAlpha = 0.8;
          c.fillStyle = theme.bg;
          c.fillRect(bx + 1, by + 1, tw + 4, 10);
          c.globalAlpha = 1;
          c.fillStyle = theme.label;
          c.fillText(b.name, bx + 3, by + 2);
        }
      }
    }
  };

  const paint = (): void => {
    if (!base) return;
    const t = progress;
    const k = scale * dpr;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = 1;
    ctx.drawImage(base, 0, 0);
    ctx.setTransform(k, 0, 0, k, 0, 0);
    const f = (t - SWEEP0) / (SWEEP1 - SWEEP0);
    const level = lay.level;

    // Logic cells holding 1: the new value behind the wavefront, the old one ahead of it.
    ctx.fillStyle = theme.on;
    ctx.beginPath();
    for (let i = 0; i < logic.length; i++) {
      const s = logic[i];
      const src = reach[level[s]] <= f ? cur : prev;
      if (src && src[s]) ctx.rect(X[s], Y[s], C, C);
    }
    ctx.fill();

    // Register strip: the stored state until the clock edge, the new state after it.
    const st = t >= CLOCK ? after : before;
    ctx.fillStyle = theme.latchOn;
    ctx.beginPath();
    for (let i = 0; i < latch.length; i++) {
      const s = latch[i];
      if (st ? bitOf(st, latchBit[i]) : cur && cur[s]) ctx.rect(X[s], Y[s], C, C);
    }
    ctx.fill();

    // Pads: constant 1, inputs, and outputs (which resolve after the sweep).
    ctx.fillStyle = theme.padOn;
    ctx.beginPath();
    ctx.rect(X[1], Y[1], C, C);
    for (let i = 0; i < nl.nIn; i++) {
      if (pads ? bitOf(pads, i) : cur && cur[2 + i]) ctx.rect(X[2 + i], Y[2 + i], C, C);
    }
    const outs = t >= OUT ? cur : prev;
    for (let j = 0; j < nl.nOut; j++) {
      if (outs && outs[S - nl.nOut + j]) ctx.rect(OX[j], OY[j], C, C);
    }
    ctx.fill();

    if (t < 1 && cur) {
      // Pulses on whatever changed, fading out after the wavefront (or the clock edge) passes.
      ctx.fillStyle = theme.pulse;
      const flash = (x: number, y: number, age: number, life: number): void => {
        if (age < 0 || age >= life) return;
        ctx.globalAlpha = 1 - age / life;
        ctx.fillRect(x - 1, y - 1, C + 2, C + 2);
      };
      const span = SWEEP1 - SWEEP0;
      for (let i = 0; i < logic.length; i++) {
        const s = logic[i];
        if (cur[s] !== (prev ? prev[s] : 0)) flash(X[s], Y[s], t - SWEEP0 - reach[level[s]] * span, PULSE);
      }
      for (let i = 0; i < nl.nIn; i++) {
        if (cur[2 + i] !== (prev ? prev[2 + i] : 0)) flash(X[2 + i], Y[2 + i], t, PULSE);
      }
      for (let j = 0; j < nl.nOut; j++) {
        const s = S - nl.nOut + j;
        if (cur[s] !== (prev ? prev[s] : 0)) flash(OX[j], OY[j], t - OUT, PULSE);
      }
      for (let i = 0; i < latch.length; i++) {
        if (bitOf(before, latchBit[i]) !== bitOf(after, latchBit[i])) flash(X[latch[i]], Y[latch[i]], t - CLOCK, CLOCK_PULSE);
      }
      // The wavefront itself, where the layout is a single block and columns follow levels.
      if (lay.blocks.length === 1 && f >= 0 && f <= 1) {
        let l = 0;
        while (l + 1 < reach.length && reach[l + 1] <= f) l++;
        const done = l + 1 < below.length ? below[l + 1] : logic.length;
        const x = M + (lay.core.x + Math.floor(done / lay.core.h)) * P - G / 2;
        ctx.globalAlpha = 0.45;
        ctx.fillRect(x - 0.5, M - G, 1, lay.rows * P + G);
      }
      ctx.globalAlpha = 1;
    }

    // Selection: outline the cell, and draw the wires that feed it at full strength.
    if (selSignal >= 0 && selSignal < S) {
      ctx.strokeStyle = theme.select;
      ctx.lineWidth = 1;
      ctx.beginPath();
      if (selOutput >= 0) {
        wire(ctx, X[selSignal], Y[selSignal], OX[selOutput], OY[selOutput], 0);
        ctx.rect(OX[selOutput] - 1, OY[selOutput] - 1, C + 2, C + 2);
      } else {
        const src = sources(selSignal);
        for (let i = 0; i < src.length; i++) {
          if (src[i] >= 2) wire(ctx, X[src[i]], Y[src[i]], X[selSignal], Y[selSignal], i & 1);
          ctx.rect(X[src[i]] - 0.5, Y[src[i]] - 0.5, C + 1, C + 1);
        }
      }
      ctx.rect(X[selSignal] - 1, Y[selSignal] - 1, C + 2, C + 2);
      ctx.stroke();
    }
  };

  const stop = (): void => {
    if (frame) caf(frame);
    frame = 0;
    progress = 1;
    if (settle) {
      const done = settle;
      settle = null;
      prev = cur;
      done();
    }
  };

  const resize = (cssWidth: number): void => {
    const next = Math.max(0.1, Math.min(maxScale, cssWidth / W));
    if (typeof devicePixelRatio === 'number' && opts.dpr === undefined) dpr = devicePixelRatio;
    const w = Math.max(1, Math.round(W * next * dpr));
    const h = Math.max(1, Math.round(H * next * dpr));
    if (base && w === canvas.width && h === canvas.height && next === scale) return;
    scale = next;
    canvas.width = w;
    canvas.height = h;
    if (canvas.style) {
      canvas.style.width = `${W * scale}px`;
      canvas.style.height = `${H * scale}px`;
    }
    renderBase();
    paint();
  };

  return {
    layout: lay,
    width: W,
    height: H,
    resize,
    draw(signals, state, inputs) {
      stop();
      cur = signals ?? null;
      prev = cur;
      before = state ?? null;
      after = before;
      pads = inputs ?? null;
      if (!base) resize(W);
      else paint();
    },
    animate(previousSignals, signals, stateBefore, stateAfter, duration = defaultDuration) {
      stop();
      prev = previousSignals ?? null;
      cur = signals;
      before = stateBefore ?? null;
      after = stateAfter ?? null;
      pads = null;
      if (!base) resize(W);
      if (!(duration > 0)) {
        prev = cur;
        paint();
        return Promise.resolve();
      }
      return new Promise<void>((resolve) => {
        settle = resolve;
        let start = -1;
        const tick = (now: number): void => {
          if (start < 0) start = now;
          progress = Math.min(1, (now - start) / duration);
          paint();
          if (progress < 1) frame = raf(tick);
          else {
            frame = 0;
            stop();
          }
        };
        progress = 0;
        paint();
        frame = raf(tick);
      });
    },
    cancel() {
      stop();
      paint();
    },
    pick(x, y) {
      const cx = Math.floor((x / scale - M + G / 2) / P);
      const cy = Math.floor((y / scale - M + G / 2) / P);
      if (cx < 0 || cy < 0 || cx >= lay.cols || cy >= lay.rows) return null;
      const g = lay.grid[cy * lay.cols + cx];
      if (g === -1) return null;
      return g < -1 ? { signal: S - nl.nOut + (-2 - g), output: -2 - g } : { signal: g, output: -1 };
    },
    select(signal, output = -1) {
      if (signal === selSignal && output === selOutput) return;
      selSignal = signal;
      selOutput = output;
      if (!frame) paint();
    },
    setTheme(next) {
      theme = next;
      if (base) {
        renderBase();
        paint();
      }
    },
    destroy() {
      stop();
      base = null;
    },
  };
}
