// #/
// A deed with a window. On silicon: the thesis (the real chip, its tagline, what it does, the two live kernels),
// then one settle told in four chapters over the 3D die. On paper: §01 the demonstration that the chip decides,
// §02 what no chip can do, §03 what is live on X Layer, §04 where to check it, §05 the circuit reader.
//
// The entry script carries the hero and the chapters' text (LandingChapters.tsx) and nothing else. When the page
// mounts, four things load in parallel: the die stage (src/scene/DieStage.tsx), the demonstration (kernel/demo.ts:
// the simulator and the netlist), §01 (components/TwoStates.tsx) and §02 to §05 (LandingClauses.tsx), the last two
// with their own styles. Each clause holds a placeholder of about its own height until it arrives, so nothing on
// screen moves. Until the stage arrives, or if it cannot load, the chapters are stacked on plain silicon. The hero
// and the stage share one grid cell, so the die starts behind the headline; chapter 0 is a spacer of the hero's
// height, measured before the first paint.

import { useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks';
import { RevealLines } from '../components/RevealLines.tsx';
import { SimBanner } from '../components/SimBanner.tsx';
import { CHAIN, COVENANT } from '../config.ts';
import { fmtInt } from '../format.ts';
import { FG_SIZE, landingDemo, type LandingDemo } from '../kernel/demo.ts';
import { jumpTo } from '../motion/lenis.ts';
import { useAsync, type Async } from '../router.ts';
import type { Bound } from '../kernel/bound.ts';
import { Chapters } from './LandingChapters.tsx';

type Stage = typeof import('../scene/DieStage.tsx').DieStage;
type S01 = typeof import('../components/TwoStates.tsx').TwoStates;
type Rest = typeof import('./LandingClauses.tsx').Clauses;
const loadStage = (): Promise<Stage> => import('../scene/DieStage.tsx').then((m) => m.DieStage);
const loadS01 = (): Promise<S01> => import('../components/TwoStates.tsx').then((m) => m.TwoStates);
const loadRest = (): Promise<Rest> => import('./LandingClauses.tsx').then((m) => m.Clauses);

export type { Bound };

/** The flagship kernels deployments/xlayer.json names, v1 first. */
export function flagships(): { version: 1 | 2; kernel: string }[] {
  const ks: { version: 1 | 2; kernel: string }[] = [];
  if (COVENANT.kernel) ks.push({ version: 1, kernel: COVENANT.kernel });
  if (COVENANT.kernelV2) ks.push({ version: 2, kernel: COVENANT.kernelV2 });
  return ks;
}

/** Bound token, its symbol and the settle count of each flagship kernel. The reads (and the chain's kernel ABI)
 * load on demand, so they stay out of the entry script. */
const boundTokens = (): Promise<Bound[]> => import('../kernel/bound.ts').then((m) => m.boundTokens(flagships()));

export const settles = (n: number | null): string => (n === null ? '? settles' : `${fmtInt(n)} settle${n === 1 ? '' : 's'}`);

/** Scroll to an element (a chapter, a clause) and give it the focus, so the keyboard continues from there. */
export function goTo(el: HTMLElement | null, immediate = false): void {
  if (!el) return;
  jumpTo(el.getBoundingClientRect().top + scrollY, { immediate });
  el.focus({ preventScroll: true });
}

export function Landing() {
  const bound = useAsync(boundTokens, []);
  const [demo, setDemo] = useState<LandingDemo | null>(null);
  const [Stage, setStage] = useState<Stage | null>(null);
  const [S01, setS01] = useState<S01 | null>(null);
  const [Rest, setRest] = useState<Rest | null>(null);
  const hero = useRef<HTMLElement>(null);
  const band = useRef<HTMLDivElement>(null);
  const first = useRef<HTMLElement>(null);

  useEffect(() => {
    let live = true;
    // A chunk that fails to load leaves its placeholder; the stage's failure leaves the chapters stacked.
    const take = <T,>(p: Promise<T>, set: (v: () => T) => void): void => {
      p.then(
        (v) => live && set(() => v),
        () => {},
      );
    };
    take(loadStage(), setStage);
    take(loadS01(), setS01);
    take(loadRest(), setRest);
    landingDemo().then(
      (d) => live && setDemo(d),
      () => {},
    );
    return () => {
      live = false;
    };
  }, []);

  // The hero's height sizes chapter 0, the spacer in front of the chapters. Written straight to a CSS variable (no
  // render), from a ResizeObserver set up before the first paint, whose first answer also comes before it.
  useLayoutEffect(() => {
    const el = hero.current;
    const b = band.current;
    if (!el || !b || typeof ResizeObserver !== 'function') return;
    const ro = new ResizeObserver(() => b.style.setProperty('--hero-h', `${Math.ceil(el.getBoundingClientRect().height)}px`));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const chapters = <Chapters demo={demo} first={first} />;

  return (
    <article class="landing">
      <button type="button" class="skip-anim" onClick={() => goTo(document.getElementById('s01'), true)}>
        Keyboard: skip the animation
      </button>
      <SimBanner />

      <div ref={band} class="landing__si silicon">
        <header ref={hero} class="hero">
          <div class="l-wrap hero__inner">
            <p class="label hero__label">
              TapeOut circuit · {CHAIN.name} {CHAIN.id} · Flow Governor · {fmtInt(FG_SIZE.nand)} NAND + {FG_SIZE.latch} latch
            </p>
            <RevealLines as="h1" class="hero__title" delay={150}>
              A token’s trading tax, routed by a chip anyone can read <em>and nobody can change.</em>
            </RevealLines>
            <div class="hero__foot">
              <p class="hero__lede">
                Send an IGNIX token's trading tax to a Covenant <b>kernel</b> instead of a wallet. Once per epoch anyone can call{' '}
                <span class="mono">settle()</span>: the kernel asks one TapeOut circuit, the <b>chip</b>, how to split the tax, and carries out
                that split inside an <b>envelope</b> of limits fixed when the kernel was created.
              </p>
              <div class="hero__ctas">
                <button type="button" class="btn btn--primary" onClick={() => goTo(first.current)}>
                  Watch the chip decide <WireIcon dir="down" />
                </button>
                <a class="btn btn--secondary" href="#/judge">
                  Run the eight checks <WireIcon dir="right" />
                </a>
              </div>
              <LiveLedger q={bound} />
            </div>
          </div>
        </header>

        <div class="landing__stage">
          {Stage ? (
            <Stage demo={demo}>{chapters}</Stage>
          ) : (
            <section class="silicon stage-stacked" aria-label="How one settle runs through the chip">
              {chapters}
            </section>
          )}
        </div>
      </div>

      <div class="landing__pa paper">
        {S01 ? <S01 n="01" /> : <div id="s01" class="l-ph l-ph--s01" tabIndex={-1} aria-busy="true" />}
        {Rest ? <Rest bound={bound} /> : <div class="l-ph l-ph--rest" aria-busy="true" />}
      </div>
    </article>
  );
}

/** The two live kernels in one ledger: token symbol and settle count, both read from the chain. The rows are there
 * from the first paint (the kernels come from deployments/xlayer.json), so the hero does not grow when the chain
 * answers. */
function LiveLedger({ q }: { q: Async<Bound[]> }) {
  const rows = flagships();
  if (rows.length === 0) return null;
  return (
    <div class={`hero__ledger${q.data ? ' is-live' : ''}`}>
      <p class="label">
        <span class="live-pad" aria-hidden="true" /> {q.loading ? `Reading ${CHAIN.name}…` : q.error ? `Could not read ${CHAIN.name}` : `Live on ${CHAIN.name}`}
        {q.error && (
          <button type="button" class="hero__retry" onClick={q.reload}>
            Try again
          </button>
        )}
      </p>
      <dl class="ledger" aria-busy={q.loading ? 'true' : undefined}>
        {rows.map((r) => {
          const b = q.data?.find((x) => x.version === r.version);
          return (
            <div key={r.kernel}>
              <dt>
                <a href={`#/k/${r.kernel}`}>
                  {b ? (b.symbol ?? (b.token ? 'Token' : 'No token yet')) : '…'} <span class="hero__ledger-k">kernel v{r.version}</span>
                </a>
              </dt>
              <dd>{b ? settles(b.count) : '…'}</dd>
            </div>
          );
        })}
      </dl>
    </div>
  );
}

/** The icon system's arrow: a wire that ends in a pad. */
export function WireIcon({ dir }: { dir: 'down' | 'right' }) {
  return (
    <svg class="btn__icon" data-dir={dir} viewBox="0 0 24 24" width="20" height="20" aria-hidden="true">
      <path d={dir === 'down' ? 'M12 3V16' : 'M3 12H16'} fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="square" />
      <rect class="pad" fill="currentColor" x={dir === 'down' ? 9.5 : 16} y={dir === 'down' ? 16 : 9.5} width="5" height="5" />
    </svg>
  );
}
