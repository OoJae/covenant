// The landing page's four chapters (#/): one settle told over the die stage, from the reader's side. Part of the
// entry script, so they hold their place from the first paint; their numbers arrive with the two lazy pieces of the
// demonstration: landingFacts() (the witness read through kernel/chip.ts) and landingDemo() (the netlist stepped by
// the simulator). Until then a number reads "…". None is typed in.

import type { ComponentChildren } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { RevealLines } from '../components/RevealLines.tsx';
import { Seal } from '../components/Seal.tsx';
import { fmtInt } from '../format.ts';
import { FG_SIZE, landingFacts, type LandingDemo, type LandingFacts } from '../kernel/demo.ts';
import { useReveal } from '../motion/reveal.ts';

const COLD = '0x0000000000000000';

function Chapter(props: { n: number; roman: string; name: string; title: ComponentChildren; children: ComponentChildren; root?: { current: HTMLElement | null } }) {
  const body = useReveal<HTMLDivElement>();
  return (
    <section ref={props.root as never} class="chapter" data-chapter={props.n} aria-labelledby={`ch-${props.n}`} tabIndex={-1}>
      <div class="l-wrap chapter__wrap">
        <div class="chapter__card">
          <p class="label">
            {props.roman} · {props.name}
          </p>
          <RevealLines as="h2" id={`ch-${props.n}`} class="chapter__title">
            {props.title}
          </RevealLines>
          <div class="chapter__body reveal" ref={body}>
            {props.children}
          </div>
        </div>
      </div>
    </section>
  );
}

/** A number the chip or the chain gave, or "…" while it is being computed. */
function D({ v, mode }: { v: string | number | null | undefined; mode?: boolean }) {
  return v === null || v === undefined ? <span class="d d--wait">…</span> : <b class={mode ? 'd d--mode' : 'd'}>{typeof v === 'number' ? fmtInt(v) : v}</b>;
}

const MEMORY: [field: string, name: string][] = [
  ['MODE', 'mode'],
  ['A', 'average'],
  ['PK', 'peak'],
  ['LIVE', 'patience'],
  ['CLOCK', 'clock'],
];

/** The chapters' numbers read from the witness (landingFacts), or null while they load. */
export function useLandingFacts(): LandingFacts | null {
  const [f, setF] = useState<LandingFacts | null>(null);
  useEffect(() => {
    let live = true;
    landingFacts().then(
      (x) => live && setF(x),
      () => {},
    );
    return () => {
      live = false;
    };
  }, []);
  return f;
}

/**
 * One settle in four chapters (plus chapter 0, the room the hero takes), with the demonstration's numbers. Returned
 * as five separate children, not one component: the die stage (scene/DieStage.tsx) wraps each child in its own
 * block, and the blocks set where each chapter of the scene starts.
 */
export function chapters({ demo, f, first }: { demo: LandingDemo | null; f: LandingFacts | null; first: { current: HTMLElement | null } }) {
  const ones = demo ? demo.signalsA.reduce((n, v) => n + v, 0) : null;
  const a = f?.routeA;
  const b = f?.routeB;
  return [
      <section key="0" class="chapter chapter--power" data-chapter="0" aria-hidden="true" />,
      <Chapter key="1" n={1} roman="I" name="Input" title="The kernel writes the question." root={first}>
        <p>
          Every epoch, <span class="mono">settle()</span> builds one <D v={f && `${f.inputBits}-bit`} /> word from chain state. Nobody supplies it, not
          even the caller. This one says: tax this epoch <D v={f && `≈ ${f.tax} OKB`} />, cumulative <D v={f && `≈ ${f.taxCum} OKB`} />, reserve{' '}
          <D v={f && `≈ ${f.reserve} OKB`} />, <D v={f?.dt} /> epoch{f?.dt === 1 ? '' : 's'} since the last step.
        </p>
        <p class="chapter__data mono">x = {f ? f.x : '…'}</p>
      </Chapter>,
      <Chapter
        key="2"
        n={2}
        roman="II"
        name="Beat"
        title={
          <>
            One beat runs it through <em>every gate.</em>
          </>
        }
      >
        <p>
          The word enters <D v={FG_SIZE.nand} /> NAND gates arranged in <D v={demo?.layout.maxLevel} /> levels. Each level waits for the one before it,
          so the answer crosses the die like a wavefront.{' '}
          {demo && ones !== null && (
            <>
              After the beat from state A, <D v={ones} /> of its <D v={demo.signalsA.length} /> signals carry a 1.
            </>
          )}
        </p>
      </Chapter>,
      <Chapter key="3" n={3} roman="III" name="Memory" title="The chip remembers.">
        <p>
          Its <D v={FG_SIZE.latch} /> latches carry an average, a peak, a patience counter and a clock from one epoch to the next. That memory is the
          second input. States A and B were both reached from a cold start by real kernel words.
        </p>
        <div class="chapter__seals">
          {(['A', 'B'] as const).map((id) => {
            const hex = f ? (id === 'A' ? f.stateA : f.stateB) : null;
            return (
              <figure key={id}>
                <Seal hex={hex ?? COLD} label={`State ${id}`} size={72} loading={hex === null} />
                <figcaption>
                  State {id}
                  <br />
                  {hex ?? '…'}
                </figcaption>
              </figure>
            );
          })}
        </div>
        <table class="chapter__mem">
          <thead>
            <tr>
              <th scope="col">Latch field</th>
              <th scope="col" class="num">
                A
              </th>
              <th scope="col" class="num">
                B
              </th>
            </tr>
          </thead>
          <tbody>
            {MEMORY.map(([k, name]) => (
              <tr key={k}>
                <th scope="row">{name}</th>
                <td class="num">{f ? f.fieldsA[k] : '…'}</td>
                <td class="num">{f ? f.fieldsB[k] : '…'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Chapter>,
      <Chapter
        key="4"
        n={4}
        roman="IV"
        name="Route"
        title={
          <>
            Same word, <em>a different answer.</em>
          </>
        }
      >
        <p>
          From state A the chip answers <D v={a?.mode} mode />: buy and lock <D v={a?.buy} />, allowance <D v={a?.allow} />, reserve <D v={a?.res} />.
          From state B the same word gets <D v={b?.mode} mode />: buy and lock <D v={b?.buy} />, and release <D v={b?.rel} /> of the reserve into it. The
          kernel carries out the split, clipped to its envelope.
        </p>
        <div class="l-flow" role="img" aria-label="tax flows to the kernel, which asks the chip, then routes to buy and lock, allowance or reserve">
          <span class="l-flow__node">trading tax</span>
          <span class="l-flow__wire" />
          <span class="l-flow__node l-flow__node--strong">kernel</span>
          <span class="l-flow__wire l-flow__wire--both" />
          <span class="l-flow__node l-flow__node--chip">chip · {fmtInt(FG_SIZE.nand + FG_SIZE.latch)} gates</span>
          <span class="l-flow__wire" />
          <span class="l-flow__dests">
            <span class="l-flow__node l-flow__node--buy">buy &amp; lock</span>
            <span class="l-flow__node l-flow__node--allow">allowance, capped</span>
            <span class="l-flow__node l-flow__node--res">reserve, released later</span>
          </span>
        </div>
      </Chapter>,
  ];
}
