// The landing page's 3D die. mountScene() draws the Flow Governor's real floorplan, wires and two beats into a
// transparent WebGL2 canvas and plays the five chapters of choreo.ts as setProgress(t) moves from 0 to 1.
// Rendering is on demand: a frame is drawn only while something moves (the power-on, the eased catch-up to the
// scroll position), never offscreen and never in a hidden tab.
//
// mountScene returns null when WebGL2 or the shaders are unavailable; the caller then shows the Canvas 2D die.
// A lost context is reported through opts.onFail and the scene stops drawing. The canvas carries no meaning
// of its own (aria-hidden); the page's text says what each chapter shows.

import { CAM_SIZE, FOV, P_PRESS, SEAL_HALF, SEAL_PITCH, cameraAt, phaseAt, sealZ } from './choreo.ts';
import { PACK, createRenderer } from './gl.ts';
import { lookAt, m4, mul, perspective, project } from './math.ts';
import type { SceneData } from './data.ts';

export { CHAPTERS } from './choreo.ts';
export { buildScene, flowGovernorSource } from './data.ts';
export type { SceneData, SceneSource } from './data.ts';

export interface SceneOptions {
  /** Draw still frames only: no power-on, no easing. */
  reducedMotion?: boolean;
  /** Time constant of the catch-up to the scroll position, in seconds (0: none). Default 0.09. */
  smooth?: number;
  /** Called once when the scene stops for good ('webglcontextlost'). */
  onFail?: (reason: string) => void;
  /** Called after each frame with the time spent drawing it (CPU side), in milliseconds. */
  onFrame?: (ms: number) => void;
  /** Called when slow frames made the scene lower its pixel ratio. */
  onDegrade?: () => void;
}

/** A rectangle in CSS pixels relative to the canvas's top-left corner. */
export interface SceneRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface Scene {
  /** Scroll progress through the chapters, 0..1. */
  setProgress(t: number): void;
  /** Call when the canvas's CSS size may have changed (a ResizeObserver also calls it). */
  resize(): void;
  /** Stop all motion and draw one frame at progress t (default: the end of chapter II, the lit die). */
  still(t?: number): void;
  destroy(): void;
  /** Where the seal plate is on screen in the last frame, or null when it is not in front of the camera. The
   * object is reused by the next call. */
  sealRect(): SceneRect | null;
}

/** The frame still() draws by default: the wavefront has crossed every level. */
export const STILL_T = 0.57;

export function mountScene(canvas: HTMLCanvasElement, data: SceneData, opts: SceneOptions = {}): Scene | null {
  let gl: WebGL2RenderingContext | null = null;
  try {
    gl = canvas.getContext('webgl2', { alpha: true, antialias: true, premultipliedAlpha: true, depth: true, powerPreference: 'high-performance' });
  } catch {
    gl = null;
  }
  if (!gl) return null;
  const R = createRenderer(gl, data);
  if (!R) return null;
  const g = gl;

  const coarse = typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches;
  let cap = coarse ? 1.5 : 2;
  const tau = opts.reducedMotion ? 0 : (opts.smooth ?? 0.09);
  let target = 0;
  let cur = 0;
  let intro = opts.reducedMotion ? 1 : 0;
  let raf = 0;
  let last = 0;
  let visible = true;
  let dead = false;
  let aspect = 1;
  let portrait = false;
  let cssW = 1;
  let cssH = 1;

  const phase = new Float32Array(8);
  const cam = new Float32Array(CAM_SIZE);
  const proj = m4();
  const view = m4();
  const vp = m4();
  const pack = new Float32Array(PACK);
  const ndc = new Float32Array(2);
  const rect: SceneRect = { x: 0, y: 0, width: 0, height: 0 };
  // Frame intervals while animating, for the auto-degrade check.
  const ring = new Float32Array(30);
  const sorted = new Float32Array(30);
  let ringN = 0;
  let degraded = false;

  pack[0] = data.cols;
  pack[1] = data.rows;
  pack[2] = data.maxLevel;

  const draw = (): void => {
    const t0 = performance.now();
    phaseAt(cur, intro, data.reach, phase);
    cameraAt(cur, portrait, aspect, cam);
    perspective(proj, FOV, aspect, Math.max(0.5, cam[9] * 0.05), cam[9] * 4 + 120);
    lookAt(view, cam);
    mul(vp, proj, view);
    pack[3] = portrait ? 1 : 0;
    for (let k = 0; k < 8; k++) pack[4 + k] = phase[k];
    pack[12] = 0;
    pack[13] = 0;
    pack[14] = sealZ(phase[P_PRESS]);
    pack[15] = SEAL_PITCH;
    pack[16] = cam[0];
    pack[17] = cam[1];
    pack[18] = cam[2];
    pack[19] = cam[9];
    pack[20] = g.drawingBufferHeight / (2 * Math.tan(FOV / 2));
    R.draw(vp, pack);
    opts.onFrame?.(performance.now() - t0);
  };

  const p90 = (): number => {
    sorted.set(ring);
    sorted.sort();
    return sorted[Math.floor(ring.length * 0.9)];
  };

  const frame = (now: number): void => {
    raf = 0;
    if (dead || !visible || document.hidden) {
      last = 0;
      return;
    }
    const dt = last ? Math.min(0.1, (now - last) / 1000) : 1 / 60;
    if (last && !degraded) {
      ring[ringN++ % ring.length] = now - last;
      if (ringN >= ring.length && ringN % 10 === 0 && p90() > 28) {
        degraded = true;
        cap = 1;
        size();
        opts.onDegrade?.();
      }
    }
    last = now;
    let again = false;
    if (intro < 1) {
      intro = Math.min(1, intro + dt / 1.6);
      again = true;
    }
    if (cur !== target) {
      cur = tau > 0 ? cur + (target - cur) * (1 - Math.exp(-dt / tau)) : target;
      if (Math.abs(target - cur) < 2e-4) cur = target;
      else again = true;
    }
    draw();
    if (again) raf = requestAnimationFrame(frame);
    else last = 0;
  };

  const kick = (): void => {
    if (!raf && !dead) raf = requestAnimationFrame(frame);
  };

  const size = (): void => {
    cssW = canvas.clientWidth || 1;
    cssH = canvas.clientHeight || 1;
    const dpr = Math.min(typeof devicePixelRatio === 'number' ? devicePixelRatio : 1, cap);
    const w = Math.max(1, Math.round(cssW * dpr));
    const h = Math.max(1, Math.round(cssH * dpr));
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    aspect = cssW / cssH;
    portrait = aspect < 0.8;
    g.viewport(0, 0, g.drawingBufferWidth, g.drawingBufferHeight);
  };

  const resize = (): void => {
    if (dead) return;
    size();
    if (raf) return;
    if (visible && !document.hidden) draw();
  };

  const onLost = (e: Event): void => {
    e.preventDefault();
    if (dead) return;
    stop();
    opts.onFail?.('webglcontextlost');
  };
  const onVisibility = (): void => {
    if (!document.hidden) kick();
  };
  const io =
    typeof IntersectionObserver === 'function'
      ? new IntersectionObserver((entries) => {
          visible = entries[entries.length - 1].isIntersecting;
          if (visible) kick();
        })
      : null;
  const ro = typeof ResizeObserver === 'function' ? new ResizeObserver(resize) : null;
  canvas.addEventListener('webglcontextlost', onLost);
  document.addEventListener('visibilitychange', onVisibility);
  io?.observe(canvas);
  ro?.observe(canvas);

  const stop = (): void => {
    dead = true;
    if (raf) cancelAnimationFrame(raf);
    raf = 0;
    io?.disconnect();
    ro?.disconnect();
    canvas.removeEventListener('webglcontextlost', onLost);
    document.removeEventListener('visibilitychange', onVisibility);
  };

  size();
  if (opts.reducedMotion) draw();
  else kick();

  return {
    setProgress(t) {
      const v = t < 0 ? 0 : t > 1 ? 1 : t;
      if (v === target) return;
      target = v;
      if (tau === 0 && !raf) {
        cur = v;
        if (visible && !document.hidden && !dead) draw();
      } else kick();
    },
    resize,
    still(t = STILL_T) {
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      last = 0;
      intro = 1;
      target = cur = t < 0 ? 0 : t > 1 ? 1 : t;
      if (!dead) draw();
    },
    destroy() {
      if (dead) return;
      stop();
      R.destroy();
    },
    sealRect() {
      const z = sealZ(phase[P_PRESS]) + 0.3;
      const h = SEAL_HALF * SEAL_PITCH;
      let x0 = Infinity;
      let y0 = Infinity;
      let x1 = -Infinity;
      let y1 = -Infinity;
      for (let k = 0; k < 4; k++) {
        if (!project(vp, k & 1 ? h : -h, k & 2 ? h : -h, z, ndc)) return null;
        const x = (ndc[0] * 0.5 + 0.5) * cssW;
        const y = (0.5 - ndc[1] * 0.5) * cssH;
        x0 = Math.min(x0, x);
        y0 = Math.min(y0, y);
        x1 = Math.max(x1, x);
        y1 = Math.max(y1, y);
      }
      rect.x = x0;
      rect.y = y0;
      rect.width = x1 - x0;
      rect.height = y1 - y0;
      return rect;
    },
  };
}
