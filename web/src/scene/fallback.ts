// The stage without WebGL2 (none, a failed start, or a lost context): the Canvas 2D die shot of @covenant/dieshot,
// in silicon colours, tilted in a CSS perspective container (rotateX 28°, rotateZ −8°; the rule is in
// src/styles/scene.css). DieStage.tsx loads this module only when it is needed.
//
// With motion allowed it follows the chapters: dark with the state on the register strip, then the input pads lit
// with the word, then the beat from state A swept in level order, then the beat from state B with the strip flipped
// to B, and the container drifts a little as the page scrolls (transform only). Without motion it draws the beat
// from state A once and stays still.

import { createDieShot, type DieShot, type Theme } from '@covenant/dieshot';
import { hexToBytes } from '@covenant/tap20';
import type { SceneSource } from './data.ts';
import { chapterAt } from './scroll.ts';

/** The die shot in the brand's silicon tokens (docs/brand/README.md): gold for logic at 1, quartz for memory. */
export const THEME_SILICON: Theme = {
  bg: '#0b0d10',
  core: '#0e1115',
  strip: '#12161b',
  wire: '#8e949c',
  feedback: '#e6b450',
  off: '#1a1f26',
  on: '#e6b450',
  latchOff: '#262d36',
  latchOn: '#e8e4da',
  padOff: '#262d36',
  padOn: '#e6b450',
  pulse: '#e8e4da',
  outline: '#262d36',
  label: '#8e949c',
  select: '#e6b450',
};

export interface FlatDie {
  setProgress(t: number): void;
  resize(): void;
  destroy(): void;
}

/** Draws the die on `canvas`, sized to `box` (the perspective container's inner element, which it also moves). */
export function mountFlat(box: HTMLElement, canvas: HTMLCanvasElement, src: SceneSource, motion: boolean): FlatDie {
  const d: DieShot = createDieShot(canvas, src.netlist, { theme: THEME_SILICON, maxScale: 8, dpr: Math.min(devicePixelRatio || 1, 2), duration: 1600 });
  const stateA = hexToBytes(src.stateA);
  const stateB = hexToBytes(src.stateB);
  const x = hexToBytes(src.x);
  const dark = new Uint8Array(x.length);
  let shown = -1;

  let fitted = 0;
  // Hidden until it has its size: the stage shows this layer only after the die is mounted, and a canvas painted
  // once at its default 300 × 150 and then at full size would count as a layout shift.
  canvas.style.visibility = 'hidden';
  const fit = (): void => {
    const bw = box.clientWidth;
    const bh = box.clientHeight;
    // Not laid out yet: the ResizeObserver fits it once it is.
    if (!bw || !bh) return;
    // The tilt shortens the die; let it run a little wider than the box.
    const w = Math.max(1, Math.floor(Math.min(bw * 1.08, (d.width * bh * 1.2) / d.height)));
    // Only a new size redraws, so the observer's callback settles at once.
    if (w === fitted) return;
    fitted = w;
    d.resize(w);
    canvas.style.visibility = '';
    shown = -1;
    if (!motion) d.draw(src.signalsA, stateA, x);
  };

  const step = (stage: number): void => {
    const forward = stage > shown;
    shown = stage;
    if (stage === 0) d.draw(null, stateA, dark);
    else if (stage === 1) d.draw(null, stateA, x);
    else if (stage === 2) {
      if (forward) void d.animate(null, src.signalsA, stateA, stateA);
      else d.draw(src.signalsA, stateA, x);
    } else if (forward && stage === 3) void d.animate(src.signalsA, src.signalsB, stateB, stateB);
    else d.draw(src.signalsB, stateB, x);
  };

  fit();
  const ro = typeof ResizeObserver === 'function' ? new ResizeObserver(fit) : null;
  if (ro) ro.observe(box);
  else requestAnimationFrame(fit);

  return {
    setProgress(t) {
      if (!motion) return;
      // The chapter decides what is drawn; the beat of chapter II starts once its wavefront would.
      const c = chapterAt(t);
      const stage = c === 2 && t < 0.29 ? 1 : c;
      if (stage !== shown) step(stage);
      box.style.transform = `rotateX(28deg) rotateZ(${(-8 + 5 * t).toFixed(3)}deg) translate3d(0, ${((0.5 - t) * 6).toFixed(3)}vh, 0) scale(${(0.96 + 0.1 * t).toFixed(4)})`;
    },
    resize: fit,
    destroy() {
      ro?.disconnect();
      d.destroy();
    },
  };
}
