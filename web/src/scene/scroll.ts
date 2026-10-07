// From the page's scroll position to the scene's progress, without a DOM (DieStage.tsx measures, this computes).
//
// The stage is a scroll track with a sticky full-height canvas; the landing's chapter blocks (children 0..IV) lie
// in the track in order, then a tail where the paper comes in. Chapter 0 (the hero) starts with the track at the
// top of the viewport; every later chapter starts when its block's top crosses the middle of the viewport and ends
// when the next one starts; the last ends when its block's bottom has nearly left the top (its text is gone).
// Progress is linear in the scroll offset inside each chapter, so the scene's chapter boundaries (choreo.ts
// CHAPTERS) land exactly where the text does, whatever height the text takes at a given width. The tail then runs
// the paper handoff from 0 to 1 while progress stays at 1, ending when the sticky canvas lets go.

import { CHAPTERS } from './choreo.ts';
import { clamp01 } from './math.ts';

/** Where in the viewport (from the top, as a share of its height) a block's top marks a chapter's start. */
export const LEAD = 0.5;
/** Where the last block's bottom marks the end of the last chapter and the start of the handoff. */
export const LEAD_END = 0.15;

export interface StageBlock {
  /** Offset of the block's top from the track's top, and its height, in CSS pixels. */
  top: number;
  height: number;
}

/**
 * The scroll offsets of the boundaries, measured as how far the track's top is above the viewport's top: anchor i
 * (0..4) is where chapter i starts, anchor 5 where the last chapter ends and the handoff starts, anchor 6 where the
 * handoff ends (the track's bottom meets the viewport's bottom). Non-decreasing. Without one block per chapter the
 * chapters share the track by their lengths and there is no handoff.
 */
export function stageAnchors(trackHeight: number, vh: number, blocks: readonly StageBlock[], out = new Float64Array(CHAPTERS.length + 2)): Float64Array {
  const n = CHAPTERS.length;
  const end = Math.max(0, trackHeight - vh);
  if (blocks.length < n) {
    for (let i = 0; i < n; i++) out[i] = CHAPTERS[i].from * end;
    out[n] = out[n + 1] = end;
    return out;
  }
  out[0] = 0;
  for (let i = 1; i < n; i++) out[i] = blocks[i].top - vh * LEAD;
  out[n] = blocks[n - 1].top + blocks[n - 1].height - vh * LEAD_END;
  out[n + 1] = end;
  for (let i = 1; i <= n + 1; i++) out[i] = Math.min(end, Math.max(out[i], out[i - 1]));
  return out;
}

export interface StageProgress {
  /** Scene progress, 0..1 (CHAPTERS). */
  t: number;
  /** Index into CHAPTERS of the chapter on screen. */
  chapter: number;
  /** The paper handoff after the last chapter, 0..1. */
  handoff: number;
}

/** Progress at scroll offset `s` (how far the track's top is above the viewport's top) for `stageAnchors` `a`. */
export function stageProgress(s: number, a: ArrayLike<number>, o: StageProgress = { t: 0, chapter: 0, handoff: 0 }): StageProgress {
  const n = CHAPTERS.length;
  o.handoff = 0;
  if (s >= a[n]) {
    o.t = 1;
    o.chapter = n - 1;
    o.handoff = a[n + 1] > a[n] ? clamp01((s - a[n]) / (a[n + 1] - a[n])) : 0;
    return o;
  }
  let i = 0;
  while (i < n - 1 && s >= a[i + 1]) i++;
  const c = CHAPTERS[i];
  const f = a[i + 1] > a[i] ? clamp01((s - a[i]) / (a[i + 1] - a[i])) : 0;
  o.t = c.from + f * (c.to - c.from);
  o.chapter = i;
  return o;
}

/** Index into CHAPTERS of the chapter that progress t falls in. */
export function chapterAt(t: number): number {
  let i = 0;
  while (i < CHAPTERS.length - 1 && t >= CHAPTERS[i].to) i++;
  return i;
}
