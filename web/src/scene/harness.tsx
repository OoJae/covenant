// Dev harness for the stage (web/scene.html, dev server only; nothing in the site imports this file). It mounts
// DieStage with stand-in chapters written from the real data (the landing's own chapters are written in
// routes/Landing.tsx), and exposes frame timings on window.__scene for a scripted scroll.
//
//   /scene.html             the stage
//   /scene.html?flat        the Canvas 2D fallback, as without WebGL2
//   /scene.html?t=0.4       the bare scene: one still frame at that progress (camera tuning); ?t=still draws
//                           the composed still
//   ?nodegrade              no auto-degrade; ?finish also times each frame through a GPU read-back (measurement
//                           only); ?slow=40 adds that many milliseconds to every frame (to see the degrade steps)

import { render } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import '../styles/tokens.css';
import '../styles/fonts.css';
import '../styles/motion.css';
import { fgModeName, pct256 } from '../kernel/chip.ts';
import { landingDemo, type LandingDemo } from '../kernel/demo.ts';
import { DieStage, type StageHandle } from './DieStage.tsx';
import { buildScene, mountScene } from './index.ts';

declare global {
  interface Window {
    __scene?: {
      cpu: number[];
      gpu: number[];
      frames: number[];
      t: number;
      chapter: number;
      handoff: number;
      ready: boolean;
      mode?: string;
      failed?: string;
      degraded?: number;
      stage?: StageHandle | null;
    };
  }
}

const q = new URLSearchParams(location.search);
const finish = q.has('finish');
const pixel = new Uint8Array(4);
const slow = Number(q.get('slow') ?? 0);
const stats: NonNullable<Window['__scene']> = { cpu: [], gpu: [], frames: [], t: 0, chapter: 0, handoff: 0, ready: false };
window.__scene = stats;

const count = (d: LandingDemo, kind: number): number => d.layout.kind.reduce((n: number, k: number) => n + (k === kind ? 1 : 0), 0);
const grouped = (n: number): string => n.toLocaleString('en-US');

function Harness() {
  const [demo, setDemo] = useState<LandingDemo | null>(null);
  useEffect(() => {
    void landingDemo().then(setDemo);
  }, []);
  const d = demo;
  return (
    <>
      <DieStage
        demo={demo}
        fallback={q.has('flat')}
        onProgress={(t, chapter, handoff) => Object.assign(stats, { t, chapter, handoff })}
        onStage={(s) => {
          stats.stage = s;
          stats.mode = s?.mode;
          stats.ready = !!s;
        }}
        sceneOptions={{
          autoDegrade: !q.has('nodegrade'),
          onFrame: (ms) => {
            stats.cpu.push(ms);
            stats.frames.push(performance.now());
            // ?slow=40: spend that many milliseconds per frame, to see the auto-degrade step in.
            for (const until = performance.now() + slow; performance.now() < until; );
            // ?finish: wait for the GPU after each frame (a one-pixel read-back forces the frame through) and record
            // the whole cost. A measurement only: it stalls the pipeline.
            if (finish) {
              const t0 = performance.now();
              document.querySelector<HTMLCanvasElement>('.die-stage__canvas')?.getContext('webgl2')?.readPixels(0, 0, 1, 1, 0x1908, 0x1401, pixel);
              stats.gpu.push(ms + performance.now() - t0);
            }
          },
          onFail: (why) => (stats.failed = why),
          onDegrade: (level) => (stats.degraded = level),
        }}
      >
        <section class="chapter hx" data-chapter="0">
          <p class="hx-label">Tapeout circuit · X Layer 196 · Flow Governor · {d ? `${grouped(count(d, 2))} NAND + ${count(d, 3)} latch` : '…'}</p>
          <h1 class="hx-h1">
            A token's trading tax, routed by a chip anyone can read <em>and nobody can change.</em>
          </h1>
          <p class="hx-lede">Send an IGNIX token's trading tax to a Covenant kernel instead of a wallet. Scroll to watch one beat of the chip.</p>
        </section>
        <section class="chapter hx" data-chapter="1">
          <p class="hx-label">I · Input</p>
          <h2 class="hx-h2">The word goes in.</h2>
          <p>{d ? `The ${d.netlist.nIn} input pads take this epoch's word x = ${d.x}.` : '…'}</p>
        </section>
        <section class="chapter hx" data-chapter="2">
          <p class="hx-label">II · Beat</p>
          <h2 class="hx-h2">One beat, level by level.</h2>
          <p>{d ? `The wavefront runs through ${d.layout.maxLevel} levels. Gates that output 1 rise and turn gold.` : '…'}</p>
        </section>
        <section class="chapter hx" data-chapter="3">
          <p class="hx-label">III · Memory</p>
          <h2 class="hx-h2">The latches form the seal.</h2>
          <p>{d ? `The ${d.netlist.nState} latches hold state A ${d.stateA}. The seal turns to state B ${d.stateB} and the die runs again on the same word.` : '…'}</p>
        </section>
        <section class="chapter hx" data-chapter="4">
          <p class="hx-label">IV · Route</p>
          <h2 class="hx-h2">Same word, a different route.</h2>
          <p>
            {d
              ? `From state A: ${fgModeName(d.routeA.mode)}, buy ${pct256(d.routeA.buy)}, allowance ${pct256(d.routeA.allow)}, reserve ${pct256(d.routeA.res)}. From state B: ${fgModeName(d.routeB.mode)}, buy ${pct256(d.routeB.buy)}, allowance ${pct256(d.routeB.allow)}, reserve ${pct256(d.routeB.res)}.`
              : '…'}
          </p>
        </section>
      </DieStage>
      <section class="paper hx-after">
        <p class="hx-label">§01</p>
        <h2 class="hx-h2">Check that the chip decides</h2>
        <p>The landing continues here, on paper.</p>
      </section>
    </>
  );
}

/** ?t=: the bare scene, one still frame, for tuning the camera. */
async function bare(t: string): Promise<void> {
  const host = document.getElementById('stage')!;
  host.innerHTML = '<div class="silicon" style="position:fixed;inset:0"><canvas style="width:100%;height:100%;display:block" aria-hidden="true"></canvas></div>';
  const demo = await landingDemo();
  const scene = mountScene(host.querySelector('canvas')!, buildScene(demo), { reducedMotion: true });
  if (!scene) {
    stats.failed = 'no WebGL2';
    return;
  }
  if (t === 'still') scene.still();
  else scene.still(Number(t));
  stats.ready = true;
  stats.mode = 'bare';
}

const t = q.get('t');
if (t !== null) void bare(t);
else render(<Harness />, document.getElementById('stage')!);
