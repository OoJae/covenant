// Smooth scrolling with Lenis (MIT, https://github.com/darkroomengineering/lenis), loaded on demand and only for a
// fine pointer with motion allowed: touch scrolling and reduced motion keep the browser's own scroll. Scroll stays
// native (Lenis smooths the wheel; it does not take over the scrollbar or the keys). `anchors: false`: the site's
// routes live in the hash, so there are no in-page #id links for Lenis to handle; every in-page jump is a button that
// calls `jumpTo`.

import type Lenis from 'lenis';
import { finePointer, motionAllowed, onMotionChange } from './prefs.ts';

export interface SmoothScroll {
  lenis: Lenis;
  /** Scroll the page to `top` (pixels from the top), smoothly unless `immediate`. */
  scrollTo(top: number, opts?: { immediate?: boolean }): void;
  /** Stop the raf loop and give the scroll back to the browser. */
  destroy(): void;
}

let current: Promise<SmoothScroll | null> | undefined;
let active: SmoothScroll | null = null;

const wanted = (): boolean => finePointer() && motionAllowed();

/** Starts Lenis once, if this device and setting want it; null otherwise (or if the chunk could not be loaded). */
export function smoothScroll(): Promise<SmoothScroll | null> {
  if (!wanted()) return Promise.resolve(null);
  current ??= start().catch(() => {
    current = undefined;
    return null;
  });
  return current;
}

async function start(): Promise<SmoothScroll | null> {
  const { default: LenisClass } = await import('lenis');
  if (!wanted()) return null; // the setting changed while the chunk loaded
  const lenis = new LenisClass({ lerp: 0.1, anchors: false, autoRaf: false });
  let frame = 0;
  const loop = (t: number): void => {
    lenis.raf(t);
    frame = requestAnimationFrame(loop);
  };
  frame = requestAnimationFrame(loop);
  const s: SmoothScroll = {
    lenis,
    scrollTo: (top, opts) => lenis.scrollTo(top, { immediate: opts?.immediate ?? false, force: true }),
    destroy: () => {
      cancelAnimationFrame(frame);
      off();
      lenis.destroy();
      if (active === s) active = null;
      current = undefined;
    },
  };
  // Turning reduced motion on mid-visit hands the scroll straight back.
  const off = onMotionChange((allowed) => {
    if (!allowed) s.destroy();
  });
  active = s;
  return s;
}

/** Scroll to `top`: through Lenis when it runs, else natively (smooth only with motion allowed). */
export function jumpTo(top: number, opts: { immediate?: boolean } = {}): void {
  if (active) return active.scrollTo(top, opts);
  scrollTo({ top, behavior: opts.immediate || !motionAllowed() ? 'auto' : 'smooth' });
}
