// Deterministic synthetic netlists for the layout and renderer tests.

import { parse, type Netlist } from '@covenant/tap20';

export function prng(seed: number): () => number {
  let s = seed >>> 0 || 1;
  return () => {
    s ^= s << 13;
    s >>>= 0;
    s ^= s >>> 17;
    s ^= s << 5;
    s >>>= 0;
    return s;
  };
}

const u24 = (v: number): number[] => [(v >> 16) & 255, (v >> 8) & 255, v & 255];

/**
 * A netlist shaped like a Covenant chip: `nLatch` LATCH records first, then `nNand` NAND
 * records. Each NAND reads two earlier signals, biased towards recent ones so the logic has
 * depth; each LATCH is fed by a NAND near the end.
 */
export function synthetic(nIn: number, nOut: number, nLatch: number, nNand: number, seed: number = 1): Netlist {
  const rnd = prng(seed);
  const bytes: number[] = [];
  const firstNand = 2 + nIn + nLatch;
  const S = firstNand + nNand;
  for (let k = 0; k < nLatch; k++) {
    const d = nNand > 0 ? S - 1 - (rnd() % Math.min(nNand, 400)) : 2 + nIn + k;
    bytes.push(1, ...u24(d));
  }
  for (let k = 0; k < nNand; k++) {
    const next = firstNand + k;
    const pickOne = (): number => {
      const span = next - 2; // signals 2 .. next - 1 are available
      if (span <= 0) return 1;
      return rnd() % 16 === 0 ? 2 + (rnd() % span) : next - 1 - (rnd() % Math.min(span, 40 + (rnd() % 400)));
    };
    const a = pickOne();
    const b = rnd() % 3 === 0 ? a : pickOne();
    bytes.push(0, ...u24(a), ...u24(b));
  }
  return parse(Uint8Array.from(bytes), nIn, nOut);
}

/** Records every drawing call; enough of CanvasRenderingContext2D for the renderer. */
export class FakeContext {
  calls = 0;
  fillStyle = '';
  strokeStyle = '';
  globalAlpha = 1;
  lineWidth = 1;
  font = '';
  textBaseline = '';
  /** Top-left corners of the rect() calls in the current path. */
  private pending: [number, number][] = [];
  /** Per fillStyle: how many path rects fill() covered, and where they were. */
  filledRects = new Map<string, number>();
  filledAt = new Map<string, [number, number][]>();
  /** Per fillStyle: how many fillRect() calls. */
  fillRects = new Map<string, number>();
  images = 0;
  strokes = 0;

  reset(): void {
    this.filledRects.clear();
    this.filledAt.clear();
    this.fillRects.clear();
    this.images = 0;
    this.strokes = 0;
    this.calls = 0;
  }
  setTransform(): void { this.calls++; }
  beginPath(): void { this.calls++; this.pending = []; }
  rect(x: number, y: number): void { this.calls++; this.pending.push([x, y]); }
  moveTo(): void { this.calls++; }
  lineTo(): void { this.calls++; }
  fill(): void {
    this.calls++;
    this.filledRects.set(this.fillStyle, (this.filledRects.get(this.fillStyle) ?? 0) + this.pending.length);
    this.filledAt.set(this.fillStyle, [...(this.filledAt.get(this.fillStyle) ?? []), ...this.pending]);
    this.pending = [];
  }
  stroke(): void { this.calls++; this.strokes++; }
  fillRect(): void { this.calls++; this.fillRects.set(this.fillStyle, (this.fillRects.get(this.fillStyle) ?? 0) + 1); }
  strokeRect(): void { this.calls++; }
  fillText(): void { this.calls++; }
  measureText(text: string): { width: number } { return { width: text.length * 4 }; }
  drawImage(): void { this.calls++; this.images++; }
}

export class FakeCanvas {
  width = 0;
  height = 0;
  style: Record<string, string> = {};
  context = new FakeContext();
  getContext(): FakeContext { return this.context; }
}

/** A requestAnimationFrame that only advances when the test says so. */
export function manualFrames() {
  let queue: ((t: number) => void)[] = [];
  let now = 0;
  let id = 0;
  return {
    request: (cb: (t: number) => void): number => {
      queue.push(cb);
      return ++id;
    },
    cancel: (): void => {
      queue = [];
    },
    /** Run the pending callbacks at `now + ms`. Returns how many ran. */
    advance: (ms: number): number => {
      now += ms;
      const run = queue;
      queue = [];
      for (const cb of run) cb(now);
      return run.length;
    },
    pending: (): number => queue.length,
  };
}
