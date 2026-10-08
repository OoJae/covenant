// The landing page's demonstration (§01): the flagship chip, one input word, two reachable latch states, two routes.
// Computed in the browser by the TAP-20 simulator from chips/out/fg.hex (shared with the 3D scene through
// kernel/demo.ts); once the chip is taped out, also asked of X Layer with two free eth_call `step` calls, whose
// terminal form is printed.
//
// Loaded on demand by the landing page (its own chunk), with its styles (styles/landing-paper.ts).
//
// Layout: a deed with two windows. Each state is a silicon card (its Seal, its mode, the share it buys and locks,
// the route bar, the output word); the verdicts are stamped on the paper below them when they are known and in view.

import { useEffect, useState } from 'preact/hooks';
import { processor, read, type StepResult } from '@covenant/chain';
import { CAST_RPC, CHAIN_LABEL, COVENANT, rpc } from '../config.ts';
import { approxCode, FG_NSTATE, FG_STATE, FG_STATE_NOTES, fgModeName, fgFlagNames, fgState, pct256, routeDiff, routeView, witness } from '../kernel/chip.ts';
import { landingDemo } from '../kernel/demo.ts';
import { inputFields } from '../kernel/model.ts';
import { CopyButton } from '../motion/copy.tsx';
import { useReveal } from '../motion/reveal.ts';
import { RouteBar, Pin } from './kit.tsx';
import { paperStyles } from '../styles/landing-paper.ts';
import { RevealLines } from './RevealLines.tsx';
import { Seal } from './Seal.tsx';

paperStyles();

type Local = { a: string; b: string; aState: string; bState: string; reachA: string; reachB: string; keccak: string };
type Chain = { a: StepResult | Error; b: StepResult | Error };

const live = COVENANT.processor !== null && COVENANT.chipId !== null;

export function TwoStates({ n, again }: { n: string; again: number }) {
  const w = witness;
  const [local, setLocal] = useState<Local | null>(null);
  const [localErr, setLocalErr] = useState<string | null>(null);
  const [chain, setChain] = useState<Chain | null>(null);
  const [seen, setSeen] = useState(false);
  const verdicts = useReveal<HTMLDivElement>(() => setSeen(true));
  const head = useReveal<HTMLDivElement>();
  const cards = useReveal<HTMLDivElement>();
  const term = useReveal<HTMLDivElement>();

  useEffect(() => {
    landingDemo().then(
      (d) =>
        setLocal({ a: d.outA, b: d.outB, aState: d.nextA, bState: d.nextB, reachA: d.reachedA, reachB: d.reachedB, keccak: d.keccak }),
      (e: unknown) => setLocalErr(String(e)),
    );
  }, []);
  // The two step reads. They run again when the hero's "Try again" does (`again`), so a node that was unreachable
  // and has come back turns NOT CHECKED into an answer without a reload.
  useEffect(() => {
    if (!live) return;
    let on = true;
    setChain(null);
    const p = processor(COVENANT.processor!);
    const ask = (s: string): Promise<StepResult | Error> => read(rpc, p.step(COVENANT.chipId!, s, w.x)).catch((e: unknown) => (e instanceof Error ? e : new Error(String(e))));
    void Promise.all([ask(w.reachA.state), ask(w.reachB.state)]).then(([a, b]) => on && setChain({ a, b }));
    return () => {
      on = false;
    };
  }, [again]);

  const x = inputFields(w.x);
  const outA = chain && !(chain.a instanceof Error) ? chain.a.outputs : (local?.a ?? w.outA.y);
  const outB = chain && !(chain.b instanceof Error) ? chain.b.outputs : (local?.b ?? w.outB.y);
  const diff = routeDiff(outA, outB);
  const cast = (s: string): string =>
    `cast call ${COVENANT.processor ?? '<processor>'} "step(uint256,bytes,bytes)(bytes,bytes)" ${COVENANT.chipId ?? '<chip id>'} ${s} ${w.x} --rpc-url ${CAST_RPC}`;

  // Verdicts
  const localOk = local ? local.a === w.outA.y && local.b === w.outB.y && local.reachA === w.reachA.state && local.reachB === w.reachB.state : null;
  const chainErr = chain ? [chain.a, chain.b].filter((c): c is Error => c instanceof Error) : [];
  // null while either side is still computing; false as soon as the chain could not be asked.
  const chainOk =
    chain === null
      ? null
      : chainErr.length > 0
        ? false
        : local === null
          ? null
          : (chain.a as StepResult).outputs === local.a &&
            (chain.b as StepResult).outputs === local.b &&
            (chain.a as StepResult).newState === local.aState &&
            (chain.b as StepResult).newState === local.bState;
  // The chain plate: never MATCH unless both answers equal the local simulation.
  const chainPlate: { tone: string; word: string; note: string } = !live
    ? { tone: 'wait', word: 'NOT TAPED OUT', note: 'the on-chain check runs once the chip is' }
    : chainOk === null
      ? { tone: 'wait', word: 'WAITING', note: `asking ${CHAIN_LABEL}: Circuits.step, twice` }
      : chainOk
        ? { tone: 'ok', word: 'MATCH', note: `${CHAIN_LABEL} returned the same outputs and new states` }
        : chainErr.length > 0
          ? { tone: 'warn', word: 'NOT CHECKED', note: `${CHAIN_LABEL} could not be asked` }
          : { tone: 'bad', word: 'MISMATCH', note: 'the chain disagrees with this browser' };

  const states = [
    { id: 'A', st: w.reachA, out: outA, steps: w.reachA.inputs.length },
    { id: 'B', st: w.reachB, out: outB, steps: w.reachB.inputs.length },
  ];

  return (
    <section class="ts l-sec" id={`s${n}`} tabIndex={-1} aria-labelledby="two-title">
      <div class="l-wrap">
        <Pin id={n}>
          <RevealLines as="span" id="two-title">
            Check that the chip <em>decides.</em>
          </RevealLines>
        </Pin>
        <div class="l-body reveal" ref={head}>
          <p class="l-lede" data-stagger style={{ '--i': 0 }}>
            <b>Same inputs, two latch states, two different routes.</b> One epoch's input word goes into the flagship chip twice. The only
            difference is the {FG_NSTATE}-bit state the chip carries from earlier epochs. Both states were reached from a cold start by real
            kernel input words, so neither is made up.
          </p>
          <dl class="ledger ts-word" data-stagger style={{ '--i': 1 }}>
            <div>
              <dt>Input word</dt>
              <dd class="mono">{w.x}</dd>
            </div>
            <div>
              <dt>Tax this epoch</dt>
              <dd>≈ {approxCode(x.TAX)} OKB</dd>
            </div>
            <div>
              <dt>Cumulative</dt>
              <dd>≈ {approxCode(x.TAXCUM)} OKB</dd>
            </div>
            <div>
              <dt>Reserve</dt>
              <dd>≈ {approxCode(x.RES)} OKB</dd>
            </div>
            <div>
              <dt>Since the last step</dt>
              <dd>
                {x.DT} epoch{x.DT === 1 ? '' : 's'}
              </dd>
            </div>
          </dl>
        </div>

        <div class="ts-pair reveal" ref={cards}>
          {states.map(({ id, st, out, steps }, i) => (
            <StateCard key={id} id={id} state={st.state} out={out} steps={steps} i={i} />
          ))}
        </div>

        <div class="ts-verdicts" ref={verdicts}>
          <div class="ts-plates">
          <div class={`plate ${diff.length > 0 ? 'ok' : 'bad'}${seen ? ' stamp' : ''}`} key={`d${seen}`}>
            <div class="verdict">
              <strong>{diff.length > 0 ? 'DIFFERENT ROUTES' : 'SAME ROUTE'}</strong>
              <span>{diff.length > 0 ? `the state changed the ${shareList(diff)}` : 'the two states routed alike'}</span>
            </div>
          </div>
          <div class={`plate ${chainPlate.tone}${seen ? ' stamp' : ''}`} key={`${chainPlate.word}${seen}`} role="status">
            <div class="verdict">
              <strong>{chainPlate.word}</strong>
              <span>{chainPlate.note}</span>
            </div>
          </div>
          </div>
          <p class="ts-explain">
            {chain && chainOk && (
              <>
                <b>Asked {CHAIN_LABEL}:</b> TapeOut's <span class="mono">Circuits.step</span> on chip #{COVENANT.chipId} returned these outputs and new
                states, the same as this browser's simulation of the netlist bytes. MATCH on both.{' '}
              </>
            )}
            {chain && chainOk === false && (
              <>
                <b>{CHAIN_LABEL} disagrees or could not be asked:</b> {chainErr.map((c) => c.message).join('; ') || 'outputs differ from the local simulation'}.{' '}
              </>
            )}
            {!live && (
              <>
                Computed in your browser by a TAP-02 simulator from <span class="mono">chips/out/fg.hex</span>. The on-chain check runs here
                automatically once the Flow Governor is taped out on Covenant's processor.{' '}
              </>
            )}
            {local && localOk && <>The browser also replayed both histories from the zero state and reached exactly states A and B. </>}
            {local && localOk === false && <b>The local simulation does not reproduce chips/out/fg.witness.json. </b>}
            {localErr && <>Local simulation failed: {localErr}. </>}
            {local && <span class="mono ts-keccak">Netlist keccak256 {local.keccak.slice(0, 18)}…</span>}
          </p>
        </div>

        <div class="ts-term reveal" ref={term}>
          <div class="terminal silicon" data-stagger style={{ '--i': 0 }}>
            <p class="label terminal__title">Repeat it from a terminal: two free read calls, no wallet</p>
            {[
              ['State A', cast(w.reachA.state)],
              ['State B', cast(w.reachB.state)],
            ].map(([label, line]) => (
              <div class="terminal__line" key={label}>
                <span class="terminal__prompt"># {label}</span>
                <pre class="mono" tabIndex={0}>
                  {line}
                </pre>
                <CopyButton text={line} what={`command for ${label}`} />
              </div>
            ))}
          </div>
          <p class="ts-note" data-stagger style={{ '--i': 1 }}>
            Each returns (new state, outputs). Outputs are 14 bytes, little-endian bit fields: bits 0–8 buy share, 18–26 allowance share, 27–35
            reserve share (each of 256), 72–80 release share of the reserve. The input words that reach each state are in{' '}
            <span class="mono">chips/out/fg.witness.json</span>.
          </p>
          <details class="ts-reach" data-stagger style={{ '--i': 2 }}>
            <summary>
              The {w.reachB.inputs.length} input words that reach states A and B
            </summary>
            <ol class="mono">
              {w.reachB.inputs.map((x, i) => (
                <li key={i}>
                  {x}
                  {i === w.reachA.inputs.length - 1 && <b> → state A</b>}
                  {i === w.reachB.inputs.length - 1 && <b> → state B</b>}
                </li>
              ))}
            </ol>
          </details>
        </div>
      </div>
    </section>
  );
}

/** The chip's route fields (kernel/chip.ts routeDiff) in the reader's words. */
const SHARE_NAMES: Record<string, string> = { T_BUY: 'buy', T_HOLD: 'hold', T_ALLOW: 'allowance', T_RES: 'reserve', REL: 'release', CEIL: 'ceiling' };

/** "buy, allowance, reserve and release shares" (the ceiling is a cap, not a share). */
function shareList(fields: string[]): string {
  const shares = fields.filter((f) => f !== 'CEIL').map((f) => SHARE_NAMES[f] ?? f);
  const words = shares.length > 1 ? `${shares.slice(0, -1).join(', ')} and ${shares[shares.length - 1]}` : (shares[0] ?? '');
  const ceil = fields.includes('CEIL');
  if (!words) return 'allowance ceiling';
  return `${words} share${shares.length > 1 ? 's' : ''}${ceil ? ' and the allowance ceiling' : ''}`;
}

/** One state as a silicon window: its Seal, what the chip answers from it, and the route. */
function StateCard({ id, state, out, steps, i }: { id: string; state: string; out: string; steps: number; i: number }) {
  const [field, setField] = useState<{ name: string; value: number } | null>(null);
  const v = routeView(out);
  const s = fgState(state);
  const get = (n: string) => s.find((f) => f.name === n)!.value;
  return (
    <article class="ts-card silicon" aria-labelledby={`ts-${id}`} data-stagger style={{ '--i': i }}>
      <header class="ts-card__head">
        <h3 id={`ts-${id}`} class="label">
          State {id}
        </h3>
        <span class="mono ts-card__hex">{state}</span>
      </header>
      <div class="ts-card__mem">
        <Seal hex={state} label={`State ${id}`} size={104} fields={FG_STATE} onField={setField} />
        <div>
          <p class="ts-card__hist">
            After {steps} epochs from a cold start. Average {get('A')}, peak {get('PK')}, patience {get('LIVE')}, clock {get('CLOCK')}.
          </p>
          <p class="ts-card__field mono" aria-live="polite">
            {field ? `${field.name} = ${field.value}: ${FG_STATE_NOTES[field.name]}` : 'Tap or point at a latch to read its field.'}
          </p>
        </div>
      </div>
      <p class="ts-card__mode">
        <span class="label">answers</span> <b>{fgModeName(v.mode)}</b>
        {fgFlagNames(v.flags).map((f) => (
          <span class="tag" key={f}>
            {f}
          </span>
        ))}
      </p>
      <p class="ts-card__num">
        <span class="ts-num">{pct256(v.buy)}</span>
        <span class="label">of the tax bought and locked</span>
      </p>
      <RouteBar view={v} />
      <p class="mono ts-card__out">outputs {out}</p>
    </article>
  );
}
