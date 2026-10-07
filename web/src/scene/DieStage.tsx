// STUB on the Track 3 branch: Track 2 owns this file and its real DieStage replaces this one at merge (the fallback
// ladder, offscreen pause, context loss, the Canvas 2D dieshot, sealRect for the press handoff). This stub keeps the
// agreed interface so the landing can be built and seen against the phase-0 scene:
//
//   <DieStage demo={LandingDemo | null} onProgress?={(t, chapter) => void}>{chapters}</DieStage>
//
// It renders a .silicon section: a sticky full-viewport canvas, and the chapter blocks
// (<section class="chapter" data-chapter="0".."4">) in normal flow over it. The section's scroll maps to
// mountScene().setProgress(t). Under reduced motion it draws one still frame at the top and does not pin.

import type { ComponentChildren } from 'preact';
import { useEffect, useRef } from 'preact/hooks';
import '../styles/scene.css';
import type { LandingDemo } from '../kernel/demo.ts';
import { motionAllowed } from '../motion/prefs.ts';
import { CHAPTERS, buildScene, mountScene } from './index.ts';

export interface DieStageProps {
  demo: LandingDemo | null;
  onProgress?: (t: number, chapter: number) => void;
  children: ComponentChildren;
}

export function DieStage({ demo, onProgress, children }: DieStageProps) {
  const section = useRef<HTMLElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const still = !motionAllowed();

  useEffect(() => {
    const el = section.current;
    const cv = canvas.current;
    if (!demo || !el || !cv) return;
    const scene = mountScene(cv, buildScene(demo), { reducedMotion: still });
    if (!scene) return;
    cv.classList.add('is-ready');
    if (still) {
      scene.still();
      return () => scene.destroy();
    }
    const onScroll = (): void => {
      const max = el.offsetHeight - innerHeight;
      const t = max > 0 ? Math.min(1, Math.max(0, -el.getBoundingClientRect().top / max)) : 0;
      scene.setProgress(t);
      const i = CHAPTERS.findIndex((c) => t < c.to);
      onProgress?.(t, i < 0 ? CHAPTERS.length - 1 : i);
    };
    addEventListener('scroll', onScroll, { passive: true });
    addEventListener('resize', onScroll);
    onScroll();
    return () => {
      removeEventListener('scroll', onScroll);
      removeEventListener('resize', onScroll);
      scene.destroy();
    };
  }, [demo]);

  return (
    <section ref={section} class={`silicon die-stage${still ? ' is-still' : ''}`} style={REL} aria-label="How one settle runs through the chip">
      <div class="scene-sticky" aria-hidden="true" style={still ? STILL_PIN : undefined}>
        <canvas ref={canvas} class="scene-canvas" />
      </div>
      <div class="die-stage__chapters" style={still ? REL : OVER}>
        {children}
      </div>
    </section>
  );
}

const REL = { position: 'relative' } as const;
const OVER = { position: 'relative', marginTop: '-100lvh' } as const;
const STILL_PIN = { position: 'absolute', inset: '0 0 auto 0', height: '100lvh' } as const;
