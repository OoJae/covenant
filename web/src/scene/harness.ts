// Dev harness for the die scene (web/scene.html): a 400vh scroll track drives setProgress, a few labels name the
// chapters with the real numbers, and window.__scene exposes frame timings for a scripted scroll.
// Not part of the production build.

import '../styles/scene.css';
import { pct256, routeView } from '../kernel/chip.ts';
import { toHex } from '@covenant/chain';
import { CHAPTERS, buildScene, flowGovernorSource, mountScene } from './index.ts';

declare global {
  interface Window {
    __scene?: { cpu: number[]; frames: number[]; t: number; ready: boolean; failed?: string; data?: unknown; sealRect?: () => unknown };
  }
}

const q = new URLSearchParams(location.search);
const canvas = document.querySelector<HTMLCanvasElement>('.scene-canvas')!;
const track = document.getElementById('track')!;
const labels = document.getElementById('labels')!;
const hud = document.getElementById('hud')!;
const stats: NonNullable<Window['__scene']> = { cpu: [], frames: [], t: 0, ready: false };
window.__scene = stats;

const src = await flowGovernorSource();
const data = buildScene(src);
const rv = routeView(toHex(data.outB));
const text: Record<string, string> = {
  '0': `Power on: <b>1,888</b> NAND gates and <b>64</b> latches, laid out by level (${data.cols} x ${data.rows} cells).`,
  I: `Input: the <b>96</b> input pads take the word x = <b>${src.x}</b>.`,
  II: `One beat: the wavefront runs through <b>${data.maxLevel}</b> levels. Gates that output 1 rise and turn gold.`,
  III: `Memory: the <b>64</b> latches form the seal. State A <b>${src.stateA}</b> becomes state B <b>${src.stateB}</b>, and the die runs again.`,
  IV: `Route, from state B: buy <b>${pct256(rv.buy)}</b>, allowance <b>${pct256(rv.allow)}</b>, reserve <b>${pct256(rv.res)}</b>.`,
};
const ps = CHAPTERS.map((c) => {
  const p = document.createElement('p');
  p.innerHTML = `${c.id} · ${text[c.id]}`;
  labels.append(p);
  return p;
});

const reduced = q.has('reduced');
const fixed = q.get('t');
const scene = mountScene(canvas, data, {
  reducedMotion: reduced || fixed !== null,
  smooth: q.has('smooth') ? Number(q.get('smooth')) : undefined,
  onFrame: (ms) => {
    stats.cpu.push(ms);
    stats.frames.push(performance.now());
  },
  onFail: (why) => {
    stats.failed = why;
    hud.textContent = `scene stopped: ${why}`;
  },
  onDegrade: () => (hud.textContent = 'degraded to DPR 1'),
});

const show = (t: number): void => {
  stats.t = t;
  ps.forEach((p, i) => p.classList.toggle('on', t >= CHAPTERS[i].from && (t < CHAPTERS[i].to || i === CHAPTERS.length - 1)));
};

if (!scene) {
  stats.failed = 'no WebGL2';
  hud.textContent = 'WebGL2 is not available here: the page would show the Canvas 2D die instead.';
} else {
  canvas.classList.add('is-ready');
  stats.data = { cells: data.cells, seals: data.seals, wires: data.wireCount, cols: data.cols, rows: data.rows, maxLevel: data.maxLevel };
  stats.sealRect = () => ({ ...scene.sealRect() });
  if (fixed !== null) {
    track.style.height = '100vh';
    scene.still(Number(fixed));
    show(Number(fixed));
  } else if (reduced) {
    scene.still();
    show(0.57);
  } else {
    const onScroll = (): void => {
      const max = track.offsetHeight - innerHeight;
      const t = max > 0 ? Math.min(1, Math.max(0, scrollY / max)) : 0;
      scene.setProgress(t);
      show(t);
    };
    addEventListener('scroll', onScroll, { passive: true });
    addEventListener('resize', onScroll);
    onScroll();
  }
  stats.ready = true;
}
