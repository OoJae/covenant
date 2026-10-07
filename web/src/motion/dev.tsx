// The motion bench behind web/motion.html (dev server only; nothing imports this file, so the build leaves it out).
// It shows the Seal (states A and B, the cold seal, the loading fill, the press), RevealLines, the CTA press, the
// reveal-once utility and a view transition, with the real witness data.

import { render, type ComponentChildren } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import '../styles/motion.css';
import { RevealLines } from '../components/RevealLines.tsx';
import { Seal } from '../components/Seal.tsx';
import { FG_STATE, FG_STATE_NOTES, fgModeName, pct256, witness } from '../kernel/chip.ts';
import { landingDemo, type LandingDemo } from '../kernel/demo.ts';
import { jumpTo, smoothScroll } from './lenis.ts';
import { installPress } from './press.ts';
import { useReveal } from './reveal.ts';
import { afterRender, withViewTransition } from './transitions.ts';

const COLD = '0x0000000000000000';

function WireArrow() {
  return (
    <svg class="wire-arrow" viewBox="0 0 24 24" width="18" height="18" aria-hidden="true">
      <path d="M3 12H16" stroke="currentColor" stroke-width="1.5" fill="none" />
      <rect x="16" y="9" width="6" height="6" fill="currentColor" />
    </svg>
  );
}

function Fig({ caption, children }: { caption: string; children: ComponentChildren }) {
  return (
    <figure>
      {children}
      <figcaption>{caption}</figcaption>
    </figure>
  );
}

function Bench() {
  const [demo, setDemo] = useState<LandingDemo | null>(null);
  const [replay, setReplay] = useState(0);
  const [flip, setFlip] = useState(false);
  const [field, setField] = useState<{ name: string; value: number } | null>(null);
  const [page, setPage] = useState(1);
  const card = useReveal<HTMLDivElement>();

  useEffect(() => {
    installPress();
    void smoothScroll();
    // Hold the loaded data back briefly so the loading seal can be seen.
    void landingDemo().then((d) => setTimeout(() => setDemo(d), 1500));
  }, []);

  const route = (r: LandingDemo['routeA']): string => `${fgModeName(r.mode)}: buy ${pct256(r.buy)}, allowance ${pct256(r.allow)}, reserve ${pct256(r.res)}`;

  return (
    <>
      <section class="silicon">
        <p class="label">Tapeout circuit · X Layer 196 · Flow Governor · 1,888 NAND + 64 latch</p>
        <RevealLines as="h1" key={replay}>
          A token's trading tax, routed by a chip anyone can read <em>and nobody can change.</em>
        </RevealLines>
        <div class="row">
          <button class="cta primary press" onClick={() => jumpTo(document.getElementById('seals')!.offsetTop)}>
            Watch the chip decide <WireArrow />
          </button>
          <button class="cta ghost press" onClick={() => setReplay((n) => n + 1)}>
            Replay the lines
          </button>
        </div>
      </section>

      <section class="silicon" id="seals">
        <p class="label">Seal · silicon · real witness states</p>
        <div class="row">
          <Fig caption={`STATE A ${witness.reachA.state}`}>
            <Seal hex={witness.reachA.state} label="State A" size={144} fields={FG_STATE} onField={setField} />
          </Fig>
          <Fig caption={`STATE B ${witness.reachB.state}`}>
            <Seal hex={witness.reachB.state} label="State B" size={144} fields={FG_STATE} onField={setField} />
          </Fig>
          <Fig caption={`cold ${COLD}`}>
            <Seal hex={COLD} label="Cold state" size={144} />
          </Fig>
          <Fig caption={demo ? 'loaded' : 'loading: level-order fill'}>
            <Seal hex={demo ? demo.nextB : COLD} label="State after B" size={144} loading={!demo} press />
          </Fig>
          <Fig caption={`pressed: ${flip ? 'B' : 'A'}`}>
            <Seal hex={flip ? witness.reachB.state : witness.reachA.state} label={flip ? 'State B' : 'State A'} size={144} press />
          </Fig>
        </div>
        <p class="readout" aria-live="polite">
          {field ? `${field.name} = ${field.value}: ${FG_STATE_NOTES[field.name]}` : 'Hover a seal cell to name its field.'}
        </p>
        <p class="readout">
          {demo ? `A → ${route(demo.routeA)} · B → ${route(demo.routeB)}` : 'Computing the two beats…'}
        </p>
        <div class="row">
          <button class="cta ghost press" onClick={() => setFlip((f) => !f)}>
            Press the other state <WireArrow />
          </button>
        </div>
      </section>

      <section class="paper">
        <p class="label">Seal · paper</p>
        <div class="row">
          <Fig caption="STATE A">
            <Seal hex={witness.reachA.state} label="State A" size={112} material="paper" />
          </Fig>
          <Fig caption="STATE B">
            <Seal hex={witness.reachB.state} label="State B" size={112} material="paper" />
          </Fig>
          <Fig caption="cold">
            <Seal hex={COLD} label="Cold state" size={112} material="paper" />
          </Fig>
          <Fig caption="loading">
            <Seal hex={COLD} label="Latch state" size={112} material="paper" loading />
          </Fig>
        </div>
        <div class="tall" />
        <RevealLines as="h2">
          Same inputs, two latch states, <em>two different routes.</em>
        </RevealLines>
        <div class="card reveal" ref={card}>
          <p data-stagger style={{ '--i': 0 }}>
            One epoch's input word goes into the flagship chip twice. The only difference is the 64-bit state the chip carries from earlier
            epochs.
          </p>
          <p data-stagger style={{ '--i': 1 }}>
            Both states were reached from a cold start by real kernel input words.
          </p>
          <button class="cta ghost press" data-stagger style={{ '--i': 2 }} onClick={() => void withViewTransition(async () => {
            setPage((p) => p + 1);
            await afterRender();
          })}>
            Page transition ({page})
          </button>
        </div>
        <div class="tall" />
      </section>
    </>
  );
}

render(<Bench />, document.getElementById('bench')!);
