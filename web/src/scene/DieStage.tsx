// The landing's stage: a silicon section whose scroll track holds a sticky, full-height canvas with the 3D die
// (index.ts) behind the landing's chapter blocks. The landing loads this module with import() and passes the
// chapters as children: <section class="chapter" data-chapter="0".."4">, the hero first.
//
//   - Scroll stays native (Lenis only smooths the wheel). The blocks' positions set where each chapter of the
//     scene starts (scroll.ts), so the die and the text change chapter together at any width.
//   - After the last chapter the seal is pressed into the die. In the track's tail the press makes the crossing
//     from silicon to paper: the Seal (components/Seal.tsx) is stamped in ink on a square of paper exactly where
//     the 3D seal lies, and that square spreads from the impression until it covers the screen (transform only;
//     the paper's grain comes in by opacity at the very end). Once the paper is under them, two lines rise beside the
//     Seal (or under it, where there is no room beside it) and say what the reader is looking at: the chip's memory,
//     which only the chip writes and the kernel feeds back in at the next settle. The words are the landing's (prop
//     `say`), which also puts them in its reading order after chapter IV. The next section of the page continues on
//     paper.
//   - Reduced motion: one composed still frame behind the hero, the chapters stacked below, nothing pinned.
//   - No WebGL2, a failed start or a lost context: the Canvas 2D die shot in a CSS perspective container
//     (fallback.ts, loaded only then).
//   - The canvas is aria-hidden: the chapters' text carries the meaning. Drawing pauses offscreen and in hidden tabs.
//
// Styles: src/styles/scene.css, which travels beside this chunk, not inside it (styles/scene.ts; this chunk stays
// under its 24 KB limit): whoever loads DieStage calls sceneStyles() before it first renders, as Landing.tsx does.
// Data: a LandingDemo (kernel/demo.ts); this chunk never bundles the netlist.

import { toChildArray, type ComponentChildren } from 'preact';
import { useEffect, useRef, useState } from 'preact/hooks';
import { Seal } from '../components/Seal.tsx';
import type { LandingDemo } from '../kernel/demo.ts';
import { motionAllowed, onMotionChange } from '../motion/prefs.ts';
import type { FlatDie } from './fallback.ts';
import { RESIZE_SLACK_PX, buildScene, mountScene, type Scene, type SceneData, type SceneOptions } from './index.ts';
import { span } from './math.ts';
import { stageAnchors, stageProgress, type StageBlock, type StageProgress } from './scroll.ts';

/** wait: the data or the chunk is not ready; gl: the 3D die; 2d: the Canvas 2D fallback; still: one still frame. */
export type StageMode = 'wait' | 'gl' | '2d' | 'still';

export interface StageHandle {
  readonly mode: StageMode;
  /** The seal plate's rectangle in viewport pixels in the last frame drawn (null in 2d mode or offscreen). */
  sealRect(): DOMRect | null;
}

export interface DieStageProps {
  /** The demonstration (kernel/demo.ts landingDemo()); null while it loads (the chapters show, the die waits). */
  demo: LandingDemo | null;
  /** Called on scroll with the scene progress (0..1), the chapter on screen (0..4) and the paper handoff (0..1). */
  onProgress?: (t: number, chapter: number, handoff: number) => void;
  /** Receives the stage once it draws, and null when it goes. */
  onStage?: (stage: StageHandle | null) => void;
  /** Show the Canvas 2D fallback even where WebGL2 works (tests, the dev harness). */
  fallback?: boolean;
  /** Extra scene options (the dev harness reads frame times through onFrame). */
  sceneOptions?: SceneOptions;
  /** What the held Seal says: two paragraphs, p.say__line and p.say__body (Landing.tsx), shown beside it after the
   * press in this aria-hidden layer. */
  say?: ComponentChildren;
  children?: ComponentChildren;
}

/** The DOM Seal's cell grid matches the 3D seal's: 8 cells over 7.9 of 8.9 pitches there, 78 of 102 units here. */
const SEAL_FIT = (7.9 / 8.9) * (102 / 78);
/** The DOM Seal's nominal size; the stage sizes it to the 3D one (scene.css stretches the svg). */
const SEAL_PX = 240;
/** The strip at the top of the screen the header covers, in CSS pixels (base.css --header-h, at most 4rem). */
const HEADER_STRIP = 64;
/** Handoff points, as shares of the handoff (scroll.ts: from chapter IV's end to the track's end): the Seal is
 * stamped on its square of paper at STAMP; the paper spreads from it over [SPREAD_FROM, PAPER_TO] and its grain
 * comes in over the last tenth of that. The page's paper (landing.css .landing__pa) overlaps the track's last 20lvh,
 * so §01 rises beside the held Seal, never before the paper is whole: scene.css sizes the tail so that 20lvh is
 * less than the handoff after PAPER_TO. */
const STAMP = 0.06;
const SPREAD_FROM = 0.12;
const PAPER_TO = 0.45;
const GRAIN_FROM = PAPER_TO - 0.1 * (PAPER_TO - SPREAD_FROM);
/** The paper square's last scale, as a share of the size that just covers the screen. */
const SPREAD_END = 1.2;
/** The words beside the Seal keep this far (CSS px) from it, from the header's strip and from §01. */
const WORDS_GAP = 32;
/** The share of the stage's height at its bottom that §01 comes up into at the end of the track (landing.css: the
 * page's paper overlaps the track's last 20lvh, and the pin is 100lvh tall). */
const PAPER_OVERLAP = 0.2;
/** Where the words can go, best first: beside the Seal in the grid's first 5, 4 or 3 columns (at most half the grid),
 * under its caption, or under it with their first line only (scene.css). */
const PLACES = ['side-5', 'side-4', 'side-3', 'below', 'line'];

const smooth = (x: number): number => x * x * (3 - 2 * x);

/** The reveal ease, cubic-bezier(.16, 1, .3, 1) (motion/prefs.ts EASE_REVEAL), for a value the scroll drives. */
function revealEase(x: number): number {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  const bx = (u: number): number => 3 * (1 - u) * (1 - u) * u * 0.16 + 3 * (1 - u) * u * u * 0.3 + u * u * u;
  let lo = 0;
  let hi = 1;
  for (let i = 0; i < 24; i++) {
    const mid = (lo + hi) / 2;
    if (bx(mid) < x) lo = mid;
    else hi = mid;
  }
  const u = (lo + hi) / 2;
  return 3 * (1 - u) * (1 - u) * u + 3 * (1 - u) * u * u + u * u * u;
}

/**
 * A chapter holds still at the stage's hold line (scene.css --stage-hold) while its block passes; one too tall to
 * fit below that line holds higher instead, so its last line stays on screen (never above the header).
 */
function fitHolds(box: HTMLElement, vh: number): void {
  const header = document.querySelector<HTMLElement>('header.top')?.offsetHeight ?? 64;
  for (const block of box.children) {
    const ch = block.firstElementChild as HTMLElement | null;
    if (!ch || block.getAttribute('data-block') === '0') continue;
    ch.style.removeProperty('top');
    const cs = getComputedStyle(ch);
    const hold = parseFloat(cs.top);
    const padTop = parseFloat(cs.paddingTop) || 0;
    const need = ch.offsetHeight - (parseFloat(cs.paddingBottom) || 0);
    if (!Number.isFinite(hold)) continue;
    const fit = Math.max(header + 8 - padTop, Math.min(hold, vh - need - 16));
    if (fit < hold - 0.5) ch.style.top = `${Math.round(fit)}px`;
  }
}

export function DieStage({ demo, onProgress, onStage, fallback = false, sceneOptions, say: lines, children }: DieStageProps) {
  const [motion, setMotion] = useState(motionAllowed);
  const [mode, setMode] = useState<StageMode>('wait');
  // Counts the stamps: the Seal is pressed again (a new element, so the press plays) each time the scroll crosses
  // STAMP going down.
  const [stamps, setStamps] = useState(0);
  const root = useRef<HTMLElement>(null);
  const track = useRef<HTMLDivElement>(null);
  const pin = useRef<HTMLDivElement>(null);
  const glCanvas = useRef<HTMLCanvasElement>(null);
  const flatBox = useRef<HTMLDivElement>(null);
  const flatCanvas = useRef<HTMLCanvasElement>(null);
  const chapters = useRef<HTMLDivElement>(null);
  const sheet = useRef<HTMLDivElement>(null);
  const paper = useRef<HTMLDivElement>(null);
  const seal = useRef<HTMLDivElement>(null);
  const cap = useRef<HTMLDivElement>(null);
  const words = useRef<HTMLDivElement>(null);

  // What the scroll handler talks to; refs, so a scroll never re-renders.
  const scene = useRef<Scene | null>(null);
  const flat = useRef<FlatDie | null>(null);
  const modeRef = useRef<StageMode>('wait');
  const prog = useRef<StageProgress>({ t: 0, chapter: 0, handoff: 0 });
  const update = useRef<() => void>(() => {});
  // Called after each frame the 3D die draws: during the handoff the press follows the seal while the camera
  // settles (a fast scroll reaches the tail before the scene has caught up).
  const afterFrame = useRef<() => void>(() => {});
  const cbs = useRef({ onProgress, onStage, sceneOptions });
  cbs.current = { onProgress, onStage, sceneOptions };
  const built = useRef<{ demo: LandingDemo; data: SceneData } | null>(null);

  useEffect(() => onMotionChange(setMotion), []);

  // The die: the 3D scene, or the fallback. Rebuilt when the data arrives and when the motion setting changes.
  useEffect(() => {
    if (!demo) return;
    let gone = false;
    const set = (m: StageMode): void => {
      modeRef.current = m;
      setMode(m);
      cbs.current.onStage?.(handle);
    };
    const handle: StageHandle = {
      get mode() {
        return modeRef.current;
      },
      sealRect() {
        const r = scene.current && modeRef.current !== '2d' ? scene.current.sealRect() : null;
        const c = glCanvas.current?.getBoundingClientRect();
        return r && c ? new DOMRect(c.left + r.x, c.top + r.y, r.width, r.height) : null;
      },
    };
    const toFlat = (): void => {
      scene.current?.destroy();
      scene.current = null;
      void import('./fallback.ts').then((m) => {
        if (gone || !flatBox.current || !flatCanvas.current) return;
        flat.current = m.mountFlat(flatBox.current, flatCanvas.current, demo, motion);
        set('2d');
        update.current();
      });
    };

    if (built.current?.demo !== demo) built.current = { demo, data: buildScene(demo) };
    const s = fallback
      ? null
      : mountScene(glCanvas.current!, built.current.data, {
          ...cbs.current.sceneOptions,
          onFrame: (ms) => {
            cbs.current.sceneOptions?.onFrame?.(ms);
            afterFrame.current();
          },
          reducedMotion: !motion,
          // A reader who arrives mid-page sees that chapter at once, not a fly-through from the top.
          progress: motion ? prog.current.t : undefined,
          onFail: (why) => {
            cbs.current.sceneOptions?.onFail?.(why);
            if (!gone) toFlat();
          },
          onDegrade: (level) => {
            cbs.current.sceneOptions?.onDegrade?.(level);
            if (level === 2 && !gone) set('still');
          },
        });
    if (s) {
      scene.current = s;
      if (motion) {
        set('gl');
        update.current();
      } else {
        s.still();
        set('still');
      }
    } else toFlat();

    return () => {
      gone = true;
      scene.current?.destroy();
      scene.current = null;
      flat.current?.destroy();
      flat.current = null;
      modeRef.current = 'wait';
      cbs.current.onStage?.(null);
    };
  }, [demo, motion, fallback]);

  // The scroll track: measure where the chapters lie, then follow the scroll. Only with motion allowed; under
  // reduced motion the chapters are stacked and nothing listens.
  useEffect(() => {
    if (!motion) {
      update.current = () => {};
      return;
    }
    const tr = track.current!;
    const anchors = new Float64Array(7);
    const p = prog.current;
    let vw = -1;
    let vh = 0;
    let lastT = -1;
    let lastHandoff = -1;
    let chapter = -1;

    const measure = (): void => {
      // The stage can leave the page a moment before this effect is cleaned up (a route change from the menu
      // sheet): a late scroll or resize then finds no chapters, and does nothing.
      const box = chapters.current;
      if (!box) return;
      // A height-only change smaller than RESIZE_SLACK_PX is a mobile address bar: keep the old viewport height.
      if (innerWidth !== vw || Math.abs(innerHeight - vh) >= RESIZE_SLACK_PX) {
        vw = innerWidth;
        vh = innerHeight;
      }
      press.big = 0;
      measureWords();
      fitHolds(box, vh);
      const top = tr.getBoundingClientRect().top;
      const blocks: StageBlock[] = [];
      for (const el of box.children as HTMLCollectionOf<HTMLElement>) {
        const r = el.getBoundingClientRect();
        blocks.push({ top: r.top - top, height: r.height });
      }
      stageAnchors(tr.offsetHeight, vh, blocks, anchors);
    };

    // Where the press happens: the 3D seal's place in the die's last frame; over the 2D die, its middle; over a
    // still frame, the middle of the stage. `side` is the DOM Seal's size, whose cells line up with the 3D seal's.
    const press = { cx: 0, cy: 0, side: 0, w: 0, h: 0, big: 0, sized: 0 };
    let stamped = false;

    // The words beside the Seal. Where they can go is measured with the layout (on resize, not each frame): for each
    // place, how tall they are there and where their grid columns end; and how deep the Seal's caption hangs under it
    // (1rem, then two lines of the micro step: scene.css). placeSeal takes the first place that fits.
    const say = { places: [] as { place: string; right: number; h: number }[], cap: 0, place: '' };
    const measureWords = (): void => {
      const wd = words.current;
      const s = wd?.firstElementChild as HTMLElement | null | undefined;
      const box = pin.current;
      say.places = [];
      if (!wd || !s || !box) return;
      const cols = getComputedStyle(wd).gridTemplateColumns.split(' ').length;
      const left = box.getBoundingClientRect().left;
      for (const place of PLACES.filter((p) => !p.startsWith('side') || 2 * Number(p.slice(-1)) <= cols)) {
        wd.dataset.place = place;
        say.places.push({ place, right: s.getBoundingClientRect().right - left, h: s.offsetHeight });
      }
      wd.dataset.place = say.place || 'none';
      say.cap = (parseFloat(getComputedStyle(document.documentElement).fontSize) || 16) * (1 + 2 * 0.6875 * 1.6);
    };
    const placeSeal = (): void => {
      const box = pin.current;
      if (!box) return;
      const w = box.clientWidth;
      const hh = box.clientHeight;
      let cx = w / 2;
      let cy = hh / 2;
      let side = Math.min(w, hh) * 0.3;
      const r = modeRef.current === 'gl' ? scene.current?.sealRect() : null;
      if (r) {
        cx = r.x + r.width / 2;
        cy = r.y + r.height / 2;
        side = r.width * SEAL_FIT;
      } else if (modeRef.current === '2d' && flatBox.current) {
        // The middle of the part of the 2D die on screen: on a phone the die is wider than the screen.
        const f = flatBox.current.getBoundingClientRect();
        const b = box.getBoundingClientRect();
        cx = (Math.max(f.left, b.left) + Math.min(f.right, b.right)) / 2 - b.left;
        cy = (Math.max(f.top, b.top) + Math.min(f.bottom, b.bottom)) / 2 - b.top;
      }
      // The paper is one square, as big as the screen needs from this centre, drawn at full size and scaled down to
      // the Seal: scaling down keeps its edge sharp.
      const big = Math.ceil(2 * Math.max(cx, w - cx, cy, hh - cy)) + 4;
      if (big !== press.big && sheet.current) sheet.current.style.width = sheet.current.style.height = `${big}px`;
      const el = seal.current;
      // Resized when it is half a pixel off the size it was last given (not the last frame's: small steps add up).
      if (el && Math.abs(side - press.sized) > 0.5) el.style.width = el.style.height = `${(press.sized = side).toFixed(1)}px`;
      if (el) el.style.transform = `translate3d(${(cx - side / 2).toFixed(1)}px, ${(cy - side / 2).toFixed(1)}px, 0)`;
      // The caption hangs from the Seal's bottom-left corner, placed by transform too: as the Seal is resized while the
      // camera settles, nothing moves in the layout.
      if (cap.current) cap.current.style.transform = `translate3d(${(cx - side / 2).toFixed(1)}px, ${(cy + side / 2).toFixed(1)}px, 0)`;
      // The words: beside the Seal in the widest columns that end short of it, their last line level with its bottom
      // edge (never under the header); else under its caption; never down where §01 comes up at the track's end.
      const wd = words.current;
      if (wd && say.places.length > 0) {
        const limit = hh * (1 - PAPER_OVERLAP) + WORDS_GAP;
        let place = 'none';
        let y = 0;
        for (const p of say.places) {
          const beside = p.place.startsWith('side');
          if (beside && p.right + WORDS_GAP > cx - side / 2) continue;
          const top = beside ? Math.max(cy + side / 2, HEADER_STRIP + WORDS_GAP + p.h) : cy + side / 2 + say.cap + WORDS_GAP;
          if ((beside ? top : top + p.h) > limit) continue;
          place = p.place;
          y = top;
          break;
        }
        if (place !== say.place) wd.dataset.place = say.place = place;
        wd.style.transform = `translate3d(0, ${y.toFixed(1)}px, 0)`;
      }
      Object.assign(press, { cx, cy, side, w, h: hh, big });
    };

    /** The press at handoff h: stamp the Seal, spread the paper from it, bring in the grain. */
    const pressAt = (h: number): void => {
      const sh = sheet.current;
      const pa = paper.current;
      const el = seal.current;
      const cp = cap.current;
      if (!sh || !pa || !el || !cp) return;
      const on = h >= STAMP;
      if (on !== stamped) {
        stamped = on;
        el.style.opacity = cp.style.opacity = on ? '1' : '';
        sh.style.opacity = on ? '1' : '';
        if (on) setStamps((n) => n + 1);
      }
      let covers = false;
      // Halfway through the spread the paper is under the whole screen: the caption and the words come in (once
      // per press: they go at once if the paper recedes, and rise again when it comes back).
      const spread = on && h >= SPREAD_FROM + 0.5 * (PAPER_TO - SPREAD_FROM);
      cp.toggleAttribute('data-spread', spread);
      words.current?.toggleAttribute('data-said', spread);
      if (on) {
        // It grows a fifth past the size that covers the screen, so the ease's long tail happens off screen and the
        // paper is whole (and the header turns) well before PAPER_TO.
        const k0 = press.side / press.big;
        const k = k0 + (SPREAD_END - k0) * revealEase(span(h, SPREAD_FROM, PAPER_TO));
        const x = press.cx - press.big / 2;
        const y = press.cy - press.big / 2;
        sh.style.transform = `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0) scale(${k.toFixed(4)})`;
        // Once the square reaches past the header's strip, the stage counts as paper for the header (app.tsx).
        const half = (press.big * k) / 2;
        covers = press.cx - half <= 0 && press.cx + half >= press.w && press.cy - half <= HEADER_STRIP;
      }
      const g = smooth(span(h, GRAIN_FROM, PAPER_TO));
      pa.style.opacity = g > 0 ? g.toFixed(3) : '';
      const st = root.current;
      if (st && covers !== st.hasAttribute('data-cover')) {
        if (covers) st.setAttribute('data-cover', 'paper');
        else st.removeAttribute('data-cover');
      }
    };

    const onScroll = (): void => {
      const box = chapters.current;
      if (!box) return;
      stageProgress(-tr.getBoundingClientRect().top, anchors, p);
      scene.current?.setProgress(p.t);
      flat.current?.setProgress(p.t);
      // For the CSS: data-chapter on the stage names the chapter on screen ("end" once the handoff starts), and
      // data-on marks its block.
      const shown = p.handoff > 0 ? -1 : p.chapter;
      if (shown !== chapter) {
        chapter = shown;
        root.current?.setAttribute('data-chapter', shown < 0 ? 'end' : String(shown));
        Array.from(box.children).forEach((el, i) => el.toggleAttribute('data-on', i === shown));
      }
      const h = p.handoff;
      const moved = p.t !== lastT || h !== lastHandoff;
      if (h !== lastHandoff) {
        if (h > 0) placeSeal();
        pressAt(h);
        lastHandoff = h;
      }
      lastT = p.t;
      if (moved) cbs.current.onProgress?.(p.t, p.chapter, h);
    };

    const refresh = (): void => {
      measure();
      lastHandoff = -1;
      onScroll();
    };
    update.current = refresh;
    afterFrame.current = () => {
      if (lastHandoff <= 0) return;
      placeSeal();
      pressAt(lastHandoff);
    };
    // The track keeps its height while text reflows inside it (fonts arriving, a live number), so the blocks are
    // watched too.
    const ro = typeof ResizeObserver === 'function' ? new ResizeObserver(refresh) : null;
    ro?.observe(tr);
    for (const el of chapters.current!.children) ro?.observe(el);
    // The words get their text with the demonstration; measure them again then (and when fonts reflow them).
    if (words.current) ro?.observe(words.current);
    addEventListener('scroll', onScroll, { passive: true });
    addEventListener('resize', refresh);
    refresh();
    return () => {
      ro?.disconnect();
      removeEventListener('scroll', onScroll);
      removeEventListener('resize', refresh);
      update.current = () => {};
      afterFrame.current = () => {};
      root.current?.removeAttribute('data-chapter');
      root.current?.removeAttribute('data-cover');
      for (const el of [seal.current, cap.current, sheet.current, paper.current, words.current]) el?.removeAttribute('style');
      cap.current?.removeAttribute('data-spread');
      words.current?.removeAttribute('data-said');
      for (const el of chapters.current?.children ?? []) {
        el.removeAttribute('data-on');
        (el.firstElementChild as HTMLElement | null)?.style.removeProperty('top');
      }
    };
  }, [motion]);

  return (
    <section ref={root} class="silicon die-stage" data-mode={mode} data-motion={motion ? 'on' : 'off'}>
      <div ref={track} class="die-stage__track">
        <div ref={pin} class="die-stage__pin" aria-hidden="true">
          <canvas ref={glCanvas} class="die-stage__canvas" />
          <div class="die-stage__flat">
            <div ref={flatBox} class="die-stage__flat-die">
              <canvas ref={flatCanvas} />
            </div>
          </div>
          <div class="die-stage__scrim" />
          {motion && (
            <>
              <div ref={sheet} class="die-stage__sheet" />
              <div ref={paper} class="paper die-stage__paper" />
              <div ref={seal} class="paper die-stage__seal">
                {stamps > 0 && demo && <Seal key={stamps} hex={demo.stateB} size={SEAL_PX} material="paper" press label="State B" />}
              </div>
              <div ref={cap} class="paper die-stage__cap">
                {demo && (
                  <p class="die-stage__caption">
                    State B · {demo.stateB}
                    <br />
                    {demo.netlist.nState} latches, one square each
                  </p>
                )}
              </div>
              <div ref={words} class="paper die-stage__words">
                {demo && lines && <div class="die-stage__say">{lines}</div>}
              </div>
            </>
          )}
        </div>
        <div ref={chapters} class="die-stage__chapters">
          {toChildArray(children).map((child, i) => (
            <div key={i} class="die-stage__block" data-block={i}>
              {child}
            </div>
          ))}
        </div>
        {motion && <div class="die-stage__tail" />}
      </div>
    </section>
  );
}

export default DieStage;
