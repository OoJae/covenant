// The landing's stage: a silicon section whose scroll track holds a sticky, full-height canvas with the 3D die
// (index.ts) behind the landing's chapter blocks. The landing loads this module with import() and passes the
// chapters as children: <section class="chapter" data-chapter="0".."4">, the hero first.
//
//   - Scroll stays native (Lenis only smooths the wheel). The blocks' positions set where each chapter of the
//     scene starts (scroll.ts), so the die and the text change chapter together at any width.
//   - After the last chapter the seal is pressed into the die; in the track's tail the paper comes in over it
//     (opacity only) and the Seal (components/Seal.tsx) is stamped in ink where the 3D seal was: the crossing from
//     silicon to paper. The next section of the page continues on paper.
//   - Reduced motion: one composed still frame behind the hero, the chapters stacked below, nothing pinned.
//   - No WebGL2, a failed start or a lost context: the Canvas 2D die shot in a CSS perspective container
//     (fallback.ts, loaded only then).
//   - The canvas is aria-hidden: the chapters' text carries the meaning. Drawing pauses offscreen and in hidden tabs.
//
// Styles: src/styles/scene.css. Data: a LandingDemo (kernel/demo.ts); this chunk never bundles the netlist.

import { toChildArray, type ComponentChildren } from 'preact';
import { useEffect, useRef, useState } from 'preact/hooks';
import { Seal } from '../components/Seal.tsx';
import type { LandingDemo } from '../kernel/demo.ts';
import { motionAllowed, onMotionChange } from '../motion/prefs.ts';
import '../styles/scene.css';
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
  children?: ComponentChildren;
}

/** The DOM Seal's cell grid matches the 3D seal's: 8 cells over 7.9 of 8.9 pitches there, 78 of 102 units here. */
const SEAL_FIT = (7.9 / 8.9) * (102 / 78);
/** The DOM Seal is drawn at this size and scaled to the 3D one. */
const SEAL_PX = 240;
/** Handoff points: the paper comes in over [PAPER_FROM, PAPER_TO]; the Seal is stamped at STAMP. */
const PAPER_FROM = 0.2;
const PAPER_TO = 0.7;
const STAMP = 0.62;

const smooth = (x: number): number => x * x * (3 - 2 * x);

export function DieStage({ demo, onProgress, onStage, fallback = false, sceneOptions, children }: DieStageProps) {
  const [motion, setMotion] = useState(motionAllowed);
  const [mode, setMode] = useState<StageMode>('wait');
  const [stamped, setStamped] = useState(false);
  const root = useRef<HTMLElement>(null);
  const track = useRef<HTMLDivElement>(null);
  const pin = useRef<HTMLDivElement>(null);
  const glCanvas = useRef<HTMLCanvasElement>(null);
  const flatBox = useRef<HTMLDivElement>(null);
  const flatCanvas = useRef<HTMLCanvasElement>(null);
  const chapters = useRef<HTMLDivElement>(null);
  const paper = useRef<HTMLDivElement>(null);
  const seal = useRef<HTMLDivElement>(null);

  // What the scroll handler talks to; refs, so a scroll never re-renders.
  const scene = useRef<Scene | null>(null);
  const flat = useRef<FlatDie | null>(null);
  const modeRef = useRef<StageMode>('wait');
  const prog = useRef<StageProgress>({ t: 0, chapter: 0, handoff: 0 });
  const update = useRef<() => void>(() => {});
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
      const top = tr.getBoundingClientRect().top;
      const blocks: StageBlock[] = [];
      for (const el of box.children as HTMLCollectionOf<HTMLElement>) {
        const r = el.getBoundingClientRect();
        blocks.push({ top: r.top - top, height: r.height });
      }
      stageAnchors(tr.offsetHeight, vh, blocks, anchors);
    };

    // The DOM Seal goes where the 3D seal was pressed (in the 3D die's last frame); over the 2D die, on its
    // middle; over a still frame, in the middle of the stage.
    const placeSeal = (): void => {
      const el = seal.current;
      const box = pin.current;
      if (!el || !box) return;
      let cx = box.clientWidth / 2;
      let cy = box.clientHeight / 2;
      let side = Math.min(box.clientWidth, box.clientHeight) * 0.3;
      const r = modeRef.current === 'gl' ? scene.current?.sealRect() : null;
      if (r) {
        cx = r.x + r.width / 2;
        cy = r.y + r.height / 2;
        side = r.width * SEAL_FIT;
      } else if (modeRef.current === '2d' && flatBox.current) {
        const f = flatBox.current.getBoundingClientRect();
        const b = box.getBoundingClientRect();
        cx = f.left + f.width / 2 - b.left;
        cy = f.top + f.height / 2 - b.top;
      }
      el.style.transform = `translate3d(${(cx - side / 2).toFixed(1)}px, ${(cy - side / 2).toFixed(1)}px, 0) scale(${(side / SEAL_PX).toFixed(4)})`;
    };

    const onScroll = (): void => {
      const box = chapters.current;
      if (!box) return;
      stageProgress(-tr.getBoundingClientRect().top, anchors, p);
      scene.current?.setProgress(p.t);
      flat.current?.setProgress(p.t);
      // For the CSS: data-chapter on the stage names the chapter on screen ("end" once the paper starts to come
      // in), and data-on marks its block.
      const shown = p.handoff > 0 ? -1 : p.chapter;
      if (shown !== chapter) {
        chapter = shown;
        root.current?.setAttribute('data-chapter', shown < 0 ? 'end' : String(shown));
        Array.from(box.children).forEach((el, i) => el.toggleAttribute('data-on', i === shown));
      }
      const h = p.handoff;
      const moved = p.t !== lastT || h !== lastHandoff;
      if (h !== lastHandoff) {
        const o = smooth(span(h, PAPER_FROM, PAPER_TO));
        if (paper.current) paper.current.style.opacity = o > 0 ? o.toFixed(3) : '';
        // Once the paper is more there than not, the stage counts as paper for the header (app.tsx).
        const el = root.current;
        if (el && o >= 0.5 !== el.hasAttribute('data-cover')) {
          if (o >= 0.5) el.setAttribute('data-cover', 'paper');
          else el.removeAttribute('data-cover');
        }
        if (h > 0) placeSeal();
        if (h >= STAMP) setStamped(true);
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
    // The track keeps its height while text reflows inside it (fonts arriving, a live number), so the blocks are
    // watched too.
    const ro = typeof ResizeObserver === 'function' ? new ResizeObserver(refresh) : null;
    ro?.observe(tr);
    for (const el of chapters.current!.children) ro?.observe(el);
    addEventListener('scroll', onScroll, { passive: true });
    addEventListener('resize', refresh);
    refresh();
    return () => {
      ro?.disconnect();
      removeEventListener('scroll', onScroll);
      removeEventListener('resize', refresh);
      update.current = () => {};
      root.current?.removeAttribute('data-chapter');
      root.current?.removeAttribute('data-cover');
      for (const el of chapters.current?.children ?? []) el.removeAttribute('data-on');
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
            <div ref={paper} class="paper die-stage__paper">
              <div ref={seal} class="die-stage__seal">
                {stamped && demo && <Seal hex={demo.stateB} size={SEAL_PX} material="paper" press label="State B" />}
              </div>
            </div>
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
