// The scroll choreography: five chapters over progress 0..1, the per-frame phase values the shaders read,
// and the camera keyframes (one set for landscape screens, one for portrait, where the die is turned 90°).
// Pure functions over preallocated arrays, so the tests can run them without a DOM.

import { ease, span } from './math.ts';

export interface Chapter {
  id: string;
  name: string;
  from: number;
  to: number;
}

/** 0 the die powers on in level order; I the input pads light with the word; II the wavefront runs through the
 * levels; III the latches fly into the 8 x 8 seal and it flips from state A to state B; IV the output pads resolve. */
export const CHAPTERS: readonly Chapter[] = [
  { id: '0', name: 'Power', from: 0, to: 0.14 },
  { id: 'I', name: 'Input', from: 0.14, to: 0.28 },
  { id: 'II', name: 'Beat', from: 0.28, to: 0.58 },
  { id: 'III', name: 'Memory', from: 0.58, to: 0.8 },
  { id: 'IV', name: 'Route', from: 0.8, to: 1 },
];

/** Slots of the phase array. Fronts are in levels; the rest run 0..1. */
export const P_POWER = 0;
export const P_INPUT = 1;
export const P_WAVE = 2;
export const P_RELIGHT = 3;
export const P_FLY = 4;
export const P_FLIP = 5;
export const P_ROUTE = 6;
export const P_PRESS = 7;

/**
 * Where a wavefront that has covered `u` (0..1) of its sweep stands, in levels: half by level number, half by the
 * share of logic cells below that level (as dieshot's own animation paces it), so neither the crowded first levels
 * nor the sparse last ones take the whole sweep. From 4 levels before level 0 to 4 past the last one.
 */
export function levelAt(reach: Float32Array, u: number): number {
  const n = reach.length - 1; // reach[0] = 0, reach[n] = 1
  const pad = 4;
  if (u <= 0) return -pad;
  if (u >= 1) return n - 1 + pad;
  let lo = 0;
  let hi = n;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (reach[mid] <= u) lo = mid;
    else hi = mid;
  }
  const f = (u - reach[lo]) / Math.max(1e-9, reach[hi] - reach[lo]);
  const l = lo + f; // 0 .. n
  return -pad + (l * (n - 1 + 2 * pad)) / n;
}

/** The reach table of `levelAt` for a scene: per level, the share of the sweep at which the front gets there. */
export function reachTable(levels: ArrayLike<number>, kinds: ArrayLike<number>, maxLevel: number): Float32Array {
  const below = new Float64Array(maxLevel + 2);
  let logic = 0;
  for (let i = 0; i < levels.length; i++) {
    if (kinds[i] !== 2 && kinds[i] !== 4) continue;
    below[levels[i] + 1]++;
    logic++;
  }
  for (let l = 1; l < below.length; l++) below[l] += below[l - 1];
  const r = new Float32Array(maxLevel + 2);
  for (let l = 0; l < r.length; l++) r[l] = (0.5 * l) / (maxLevel + 1) + (0.5 * below[l]) / Math.max(1, logic);
  r[r.length - 1] = 1;
  return r;
}

/**
 * The phase values at progress t: `intro` (0..1) is the time-driven power-on that plays once on load; the scroll
 * position completes it too, so a reader who lands mid-page never sees a dark die.
 */
export function phaseAt(t: number, intro: number, reach: Float32Array, o: Float32Array): Float32Array {
  const top = reach.length + 7;
  o[P_POWER] = Math.max(intro, span(t, 0, 0.1)) * top - 6;
  o[P_INPUT] = span(t, 0.15, 0.26);
  o[P_WAVE] = levelAt(reach, span(t, 0.29, 0.56));
  o[P_FLY] = ease(span(t, 0.59, 0.69));
  o[P_FLIP] = span(t, 0.695, 0.745);
  o[P_RELIGHT] = levelAt(reach, span(t, 0.735, 0.79));
  o[P_ROUTE] = span(t, 0.81, 0.93);
  o[P_PRESS] = ease(span(t, 0.93, 0.99));
  return o;
}

/** Camera keyframes: progress, target x y (die-local, in cells) and z, span (world units across the shorter screen
 * side), azimuth and elevation (degrees). Seven numbers per key. */
const KEYS_LANDSCAPE = [
  0.0, -13, 4, 0, 58, -22, 36,
  0.14, -23, 0, 0, 30, -48, 36,
  0.28, -14, 0, 0, 32, -30, 32,
  0.43, 2, 0, 1, 36, -10, 38,
  0.58, 8, 0, 2, 44, 8, 46,
  0.69, 0, 0, 7, 34, 0, 60,
  0.8, 0, 0, 8, 26, 4, 68,
  0.92, 19, 0, 2, 32, 30, 44,
  1.0, 2, 0, 1, 48, 0, 76,
];
const KEYS_PORTRAIT = [
  0.0, -12, 0, 0, 46, -18, 40,
  0.14, -22, 0, 0, 30, -40, 40,
  0.28, -12, 0, 0, 36, -24, 36,
  0.43, 2, 0, 1, 40, -8, 40,
  0.58, 8, 0, 2, 46, 6, 48,
  0.69, 0, 0, 7, 30, 0, 62,
  0.8, 0, 0, 8, 24, 2, 70,
  0.92, 19, 0, 2, 34, 20, 46,
  1.0, 2, 0, 1, 48, 0, 76,
];
const KN = 7;

export const FOV = (28 * Math.PI) / 180;

/** Camera slots: eye xyz, target xyz, up xyz, distance. */
export const CAM_SIZE = 10;

const cr = (p0: number, p1: number, p2: number, p3: number, u: number): number =>
  0.5 * (2 * p1 + (p2 - p0) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u + (3 * p1 - p0 - 3 * p2 + p3) * u * u * u);

/** The camera at progress t, through the keyframes by Catmull-Rom. Portrait turns the die 90° (x, y) -> (y, -x). */
export function cameraAt(t: number, portrait: boolean, aspect: number, o: Float32Array): Float32Array {
  const K = portrait ? KEYS_PORTRAIT : KEYS_LANDSCAPE;
  const n = K.length / KN;
  let i = 0;
  while (i < n - 2 && t > K[(i + 1) * KN]) i++;
  const a = Math.max(0, i - 1);
  const d = Math.min(n - 1, i + 2);
  const u = span(t, K[i * KN], K[(i + 1) * KN]);
  const b = (i + 1) * KN;
  let tx = cr(K[a * KN + 1], K[i * KN + 1], K[b + 1], K[d * KN + 1], u);
  let ty = cr(K[a * KN + 2], K[i * KN + 2], K[b + 2], K[d * KN + 2], u);
  if (portrait) {
    const x = tx;
    tx = ty;
    ty = -x;
  }
  const tz = cr(K[a * KN + 3], K[i * KN + 3], K[b + 3], K[d * KN + 3], u);
  const dist = cr(K[a * KN + 4], K[i * KN + 4], K[b + 4], K[d * KN + 4], u) / (2 * Math.tan(FOV / 2) * Math.min(aspect, 1));
  const az = (cr(K[a * KN + 5], K[i * KN + 5], K[b + 5], K[d * KN + 5], u) * Math.PI) / 180;
  const el = (cr(K[a * KN + 6], K[i * KN + 6], K[b + 6], K[d * KN + 6], u) * Math.PI) / 180;
  const ce = Math.cos(el);
  const se = Math.sin(el);
  const sa = Math.sin(az);
  const ca = Math.cos(az);
  o[0] = tx + dist * ce * sa;
  o[1] = ty - dist * ce * ca;
  o[2] = tz + dist * se;
  o[3] = tx;
  o[4] = ty;
  o[5] = tz;
  o[6] = -se * sa;
  o[7] = se * ca;
  o[8] = ce;
  o[9] = dist;
  return o;
}

/** The seal hangs above the die's centre; it is pressed down onto the die at the end of chapter IV. */
export const SEAL_Z = 9;
export const SEAL_PITCH = 1.9;
export const SEAL_PRESSED_Z = 1.2;
export const sealZ = (press: number): number => SEAL_Z + (SEAL_PRESSED_Z - SEAL_Z) * press;
/** Half the seal plate's side, in seal pitches. */
export const SEAL_HALF = 4.45;
