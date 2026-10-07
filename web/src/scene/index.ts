// The landing page's 3D die. mountScene() draws the Flow Governor's real floorplan, wires and two beats into a
// transparent WebGL2 canvas and plays the five chapters of choreo.ts as setProgress(t) moves from 0 to 1.
// Rendering is on demand: a frame is drawn only while something moves (the power-on, the eased catch-up to the
// scroll position, the idle sway of chapter 0), never offscreen and never in a hidden tab.
//
// mountScene returns null when WebGL2 or the shaders are unavailable; the caller then shows the Canvas 2D die.
// A lost context is reported through opts.onFail and the scene stops drawing. Slow frames lower the cost in two
// steps (opts.onDegrade): first pixel ratio 1 and no glow, then one still frame. The canvas carries no meaning of
// its own (aria-hidden); the page's text says what each chapter shows.

import {
  CAM_SIZE,
  FOV,
  INTRO_SECONDS,
  P_PRESS,
  SEAL_HALF,
  SEAL_PITCH,
  STILL_T,
  SWAY_UNTIL,
  cameraAt,
  cameraStill,
  lensShift,
  phaseAt,
  sealZ,
  swayAt,
} from './choreo.ts';
import { PACK, createRenderer } from './gl.ts';
import { lookAt, m4, mul, perspective, project } from './math.ts';
import type { SceneData } from './data.ts';

export { CHAPTERS, STILL_T } from './choreo.ts';
export { buildScene } from './data.ts';
export type { SceneData, SceneSource } from './data.ts';

export interface SceneOptions {
  /** Draw still frames only: no power-on, no easing, no sway. */
  reducedMotion?: boolean;
  /** Time constant of the catch-up to the scroll position, in seconds (0: none). Default 0.09. */
  smooth?: number;
  /** The idle sway of chapter 0 (±1.5°). Default: on unless reducedMotion. */
  sway?: boolean;
  /** Watch frame times and lower the cost when they are slow. Default true. */
  autoDegrade?: boolean;
  /** Progress to start at, without easing toward it (default 0). */
  progress?: number;
  /** Called once when the scene stops for good ('webglcontextlost'). */
  onFail?: (reason: string) => void;
  /** Called after each frame with the time spent drawing it (CPU side), in milliseconds. */
  onFrame?: (ms: number) => void;
  /** Called when slow frames lowered the cost: level 1 is pixel ratio 1 without glow, level 2 one still frame. */
  onDegrade?: (level: 1 | 2) => void;
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
  /** Stop all motion and draw one frame: at progress t, or without t the composed still (choreo.ts STILL_T: the
   * beat from state A lit, the seal formed). */
  still(t?: number): void;
  destroy(): void;
  /** Where the seal plate is on screen in the last frame, or null when it is not in front of the camera. The
   * object is reused by the next call. */
  sealRect(): SceneRect | null;
}

/** Frame interval (ms) above which the 90th percentile makes the scene lower its cost. */
export const SLOW_FRAME_MS = 28;
/** Seconds without a scroll after which the hero's sway settles and the scene stops drawing. */
export const SWAY_IDLE = 8;
/** Frame interval (ms) of a machine that cannot draw the scene at all: ten in a row and it goes to the still frame. */
export const HOPELESS_MS = 50;

/** A software rasteriser behind WebGL (SwiftShader, llvmpipe), where the browser says so. */
function softwareRenderer(gl: WebGL2RenderingContext): boolean {
  const ext = gl.getExtension('WEBGL_debug_renderer_info');
  const name = ext ? String(gl.getParameter(ext.UNMASKED_RENDERER_WEBGL)) : '';
  return /SwiftShader|llvmpipe|softpipe|Software/i.test(name);
}
/** Height-only resizes smaller than this (a mobile browser's address bar) keep the drawing buffer as it is. */
export const RESIZE_SLACK_PX = 120;

export function mountScene(canvas: HTMLCanvasElement, data: SceneData, opts: SceneOptions = {}): Scene | null {
  let gl: WebGL2RenderingContext | null = null;
  try {
    // A software renderer (SwiftShader, llvmpipe: Chrome with the GPU blocklisted, a VM) would block the main
    // thread for seconds before the auto-degrade could step in: refuse it, and the stage takes the Canvas 2D die.
    // The default power preference: the die is a background, not a reason to wake a discrete GPU.
    gl = canvas.getContext('webgl2', { alpha: true, antialias: true, premultipliedAlpha: true, depth: true, powerPreference: 'default', failIfMajorPerformanceCaveat: true });
  } catch {
    gl = null;
  }
  if (!gl) return null;
  if (softwareRenderer(gl)) {
    gl.getExtension('WEBGL_lose_context')?.loseContext();
    return null;
  }
  const R = createRenderer(gl, data);
  if (!R) return null;
  const g = gl;

  const coarse = typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches;
  const reduced = !!opts.reducedMotion;
  let cap = coarse ? 1.5 : 2;
  let glow = true;
  const tau = reduced ? 0 : (opts.smooth ?? 0.09);
  const swayOn = opts.sway ?? !reduced;
  let target = Math.min(1, Math.max(0, opts.progress ?? 0));
  let cur = target;
  let intro = reduced ? 1 : 0;
  let swayClock = 0;
  // The sway settles after SWAY_IDLE seconds without a scroll and the scene stops drawing; the next scroll brings
  // it back. An idle page costs no frames.
  let swayIdle = 0;
  let swayGain = 1;
  let composed = false;
  let frozen = false;
  let raf = 0;
  let last = 0;
  let visible = true;
  let dead = false;
  let aspect = 1;
  let portrait = false;
  let cssW = 0;
  let cssH = 0;

  const phase = new Float32Array(8);
  const cam = new Float32Array(CAM_SIZE);
  const proj = m4();
  const view = m4();
  const vp = m4();
  const pack = new Float32Array(PACK);
  const ndc = new Float32Array(2);
  const shift = new Float32Array(2);
  const rect: SceneRect = { x: 0, y: 0, width: 0, height: 0 };

  // Frame intervals while animating, for the auto-degrade check: a window of 45, judged every 15 frames, after
  // 20 frames of grace (the page is busiest while it loads). Gaps over 250 ms are a tab switch or a hitch, not a
  // frame rate, and are left out. A machine that cannot draw at all (the first 10 frames after the grace all over
  // HOPELESS_MS) goes straight to the still frame instead of waiting for the window.
  const WINDOW = 45;
  const ring = new Float32Array(WINDOW);
  const sorted = new Float32Array(WINDOW);
  let ringN = 0;
  let grace = 20;
  let level = 0;

  pack[0] = data.cols;
  pack[1] = data.rows;
  pack[2] = data.maxLevel;

  const draw = (): void => {
    const t0 = performance.now();
    if (composed) {
      phaseAt(STILL_T, 1, data.reach, phase);
      cameraStill(portrait, aspect, cam);
    } else {
      phaseAt(cur, intro, data.reach, phase);
      cameraAt(cur, portrait, aspect, cam, swayOn ? swayGain * swayAt(swayClock, cur, Math.min(1, swayClock / 2)) : 0);
    }
    perspective(proj, FOV, aspect, Math.max(0.5, cam[9] * 0.05), cam[9] * 4 + 120);
    // Shift the image off-axis (x_ndc += s.x): proj[8] and proj[9] multiply the view z, and w = -z.
    lensShift(aspect, shift);
    proj[8] -= shift[0];
    proj[9] -= shift[1];
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
    R.draw(vp, pack, glow);
    opts.onFrame?.(performance.now() - t0);
  };

  const sample = (ms: number): void => {
    if (opts.autoDegrade === false || frozen || ms > 250) return;
    if (grace > 0) {
      grace--;
      return;
    }
    ring[ringN++ % WINDOW] = ms;
    let hopeless = level === 0 && ringN === 10;
    for (let i = 0; hopeless && i < 10; i++) hopeless = ring[i] > HOPELESS_MS;
    if (!hopeless) {
      if (ringN < WINDOW || ringN % 15 !== 0) return;
      sorted.set(ring);
      sorted.sort();
      if (sorted[Math.floor(WINDOW * 0.9)] <= SLOW_FRAME_MS) return;
    }
    level = hopeless ? 2 : level + 1;
    ringN = 0;
    grace = 10;
    if (level === 1) {
      cap = 1;
      glow = false;
      size(true);
    } else {
      frozen = true;
      composed = true;
      intro = 1;
    }
    opts.onDegrade?.(level as 1 | 2);
  };

  const frame = (now: number): void => {
    raf = 0;
    if (dead || !visible || document.hidden) {
      last = 0;
      return;
    }
    const dt = last ? Math.min(0.1, (now - last) / 1000) : 1 / 60;
    if (last) sample(now - last);
    last = now;
    let again = false;
    if (!frozen) {
      if (intro < 1) {
        intro = Math.min(1, intro + dt / INTRO_SECONDS);
        again = true;
      }
      if (cur !== target) {
        cur = tau > 0 ? cur + (target - cur) * (1 - Math.exp(-dt / tau)) : target;
        if (Math.abs(target - cur) < 2e-4) cur = target;
        else again = true;
      }
      // The idle sway: only in chapter 0, and only once the die has powered on.
      if (swayOn && intro >= 1 && cur < SWAY_UNTIL) {
        swayIdle += dt;
        const want = swayIdle < SWAY_IDLE ? 1 : 0;
        swayGain += (want - swayGain) * Math.min(1, dt * 1.2);
        if (want === 1 || swayGain > 0.002) {
          swayClock += dt;
          again = true;
        } else swayGain = 0;
      }
    }
    draw();
    if (again) raf = requestAnimationFrame(frame);
    else last = 0;
  };

  const kick = (): void => {
    if (!raf && !dead && !frozen) raf = requestAnimationFrame(frame);
  };

  /** Fits the drawing buffer to the canvas's CSS size; false when nothing changed or the change was ignored. */
  const size = (force = false): boolean => {
    const w = canvas.clientWidth || 1;
    const h = canvas.clientHeight || 1;
    if (!force && w === cssW && (h === cssH || (cssH > 0 && Math.abs(h - cssH) < RESIZE_SLACK_PX))) return false;
    cssW = w;
    cssH = h;
    const dpr = Math.min(typeof devicePixelRatio === 'number' ? devicePixelRatio : 1, cap);
    const bw = Math.max(1, Math.round(w * dpr));
    const bh = Math.max(1, Math.round(h * dpr));
    if (canvas.width !== bw || canvas.height !== bh) {
      canvas.width = bw;
      canvas.height = bh;
    }
    aspect = w / h;
    portrait = aspect < 0.8;
    g.viewport(0, 0, g.drawingBufferWidth, g.drawingBufferHeight);
    return true;
  };

  const resize = (): void => {
    if (dead || !size()) return;
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

  size(true);
  if (reduced) draw();
  else kick();

  return {
    setProgress(t) {
      const v = t < 0 ? 0 : t > 1 ? 1 : t;
      if (v === target && !composed) return;
      target = v;
      swayIdle = 0;
      if (frozen) return;
      composed = false;
      if (tau === 0 && !raf) {
        cur = v;
        if (visible && !document.hidden && !dead) draw();
      } else kick();
    },
    resize,
    still(t) {
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      last = 0;
      intro = 1;
      composed = t === undefined;
      if (t !== undefined) target = cur = t < 0 ? 0 : t > 1 ? 1 : t;
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
