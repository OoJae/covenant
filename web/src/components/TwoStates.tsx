// The landing page's demonstration: the flagship chip, one input word, two reachable latch states, two routes.
// Computed in the browser by the TAP-20 simulator from chips/out/fg.hex; once the chip is taped out, also asked
// of X Layer with two free eth_call `step` calls, whose terminal form is printed.

import { useEffect, useState } from 'preact/hooks';
import { processor, read, type StepResult } from '@covenant/chain';
import { CAST_RPC, CHAIN_LABEL, COVENANT, rpc } from '../config.ts';
import { approxCode, fgModeName, fgFlagNames, fgState, routeDiff, routeView, witness } from '../kernel/chip.ts';
import { inputFields } from '../kernel/model.ts';
import { Command } from './common.tsx';
import { RouteBar } from './kit.tsx';

type Local = { a: string; b: string; aState: string; bState: string; reachA: string; reachB: string; keccak: string };
type Chain = { a: StepResult | Error; b: StepResult | Error };

const live = COVENANT.processor !== null && COVENANT.chipId !== null;

export function TwoStates() {
  const w = witness;
  const [local, setLocal] = useState<Local | null>(null);
  const [localErr, setLocalErr] = useState<string | null>(null);
  const [chain, setChain] = useState<Chain | null>(null);

  useEffect(() => {
    import('../kernel/sim.ts').then(
      (sim) => {
        const fg = sim.flowGovernor();
        const a = sim.beat(fg.netlist, w.reachA.state, w.x);
        const b = sim.beat(fg.netlist, w.reachB.state, w.x);
        setLocal({
          a: a.outputs,
          b: b.outputs,
          aState: a.newState,
          bState: b.newState,
          reachA: sim.reach(fg.netlist, w.reachA.inputs),
          reachB: sim.reach(fg.netlist, w.reachB.inputs),
          keccak: fg.keccak,
        });
      },
      (e: unknown) => setLocalErr(String(e)),
    );
    if (!live) return;
    const p = processor(COVENANT.processor!);
    const ask = (s: string): Promise<StepResult | Error> => read(rpc, p.step(COVENANT.chipId!, s, w.x)).catch((e: unknown) => (e instanceof Error ? e : new Error(String(e))));
    void Promise.all([ask(w.reachA.state), ask(w.reachB.state)]).then(([a, b]) => setChain({ a, b }));
  }, []);

  const x = inputFields(w.x);
  const outA = chain && !(chain.a instanceof Error) ? chain.a.outputs : (local?.a ?? w.outA.y);
  const outB = chain && !(chain.b instanceof Error) ? chain.b.outputs : (local?.b ?? w.outB.y);
  const diff = routeDiff(outA, outB);
  const cast = (s: string): string =>
    `cast call ${COVENANT.processor ?? '<processor>'} "step(uint256,bytes,bytes)(bytes,bytes)" ${COVENANT.chipId ?? '<chip id>'} ${s} ${w.x} --rpc-url ${CAST_RPC}`;

  // Verdicts
  const localOk = local ? local.a === w.outA.y && local.b === w.outB.y && local.reachA === w.reachA.state && local.reachB === w.reachB.state : null;
  const chainOk = chain ? !(chain.a instanceof Error) && !(chain.b instanceof Error) && local !== null && chain.a.outputs === local.a && chain.b.outputs === local.b && chain.a.newState === local.aState && chain.b.newState === local.bState : null;

  return (
    <section class="twostates" aria-labelledby="two-title">
      <div class="eyebrow">The chip is not decorative</div>
      <h2 id="two-title" class="bare">Same inputs, two latch states, two different routes</h2>
      <p class="muted">
        One epoch's input word goes into the flagship chip twice. The only difference is the 64-bit state the chip carries from
        earlier epochs. Both states were reached from a cold start by real kernel input words, so neither is made up.
      </p>

      <div class="xword">
        <span class="tag mono">input word {w.x}</span>
        <span>
          tax this epoch ≈ {approxCode(x.TAX)} OKB · cumulative ≈ {approxCode(x.TAXCUM)} OKB · reserve ≈ {approxCode(x.RES)} OKB · {x.DT}{' '}
          epoch{x.DT === 1 ? '' : 's'} since the last step
        </span>
      </div>

      <div class="pair">
        {[
          { id: 'A', st: w.reachA, out: outA, steps: w.reachA.inputs.length },
          { id: 'B', st: w.reachB, out: outB, steps: w.reachB.inputs.length },
        ].map(({ id, st, out, steps }) => {
          const v = routeView(out);
          const s = fgState(st.state);
          const get = (n: string) => s.find((f) => f.name === n)!.value;
          return (
            <div class="chipcard" key={id}>
              <div class="cardhead">
                <span class="pinid">STATE {id}</span>
                <span class="mono muted">{st.state}</span>
              </div>
              <p class="muted small">
                After {steps} epochs from a cold start. Average {get('A')}, peak {get('PK')}, patience {get('LIVE')}, clock {get('CLOCK')}.
              </p>
              <div class="mode">
                → <b>{fgModeName(v.mode)}</b> {fgFlagNames(v.flags).map((f) => (
                  <span class="flag" key={f}>
                    {f}
                  </span>
                ))}
              </div>
              <RouteBar view={v} />
              <div class="mono muted small">outputs {out}</div>
            </div>
          );
        })}
      </div>

      <div class={`plate ${diff.length > 0 ? 'ok' : 'bad'}`}>
        <div class="verdict">
          <strong>{diff.length > 0 ? 'DIFFERENT ROUTES' : 'SAME ROUTE'}</strong>
          <span>{diff.length > 0 ? `the state changed ${diff.join(', ')}` : 'the two states routed alike'}</span>
        </div>
        <p class="small">
          {chain === null && live && `Asking ${CHAIN_LABEL}… `}
          {chain && chainOk && (
            <>
              <b>Asked {CHAIN_LABEL}:</b> TapeOut's <span class="mono">Circuits.step</span> on chip #{COVENANT.chipId} returned these outputs and new
              states, the same as this browser's simulation of the netlist bytes. MATCH on both.{' '}
            </>
          )}
          {chain && chainOk === false && (
            <>
              <b>{CHAIN_LABEL} disagrees or could not be asked:</b>{' '}
              {[chain.a, chain.b].map((c) => (c instanceof Error ? c.message : '')).filter(Boolean).join('; ') || 'outputs differ from the local simulation'}.{' '}
            </>
          )}
          {!live && (
            <>
              Computed in your browser by a TAP-20 simulator from <span class="mono">chips/out/fg.hex</span>. The on-chain check runs here
              automatically once the Flow Governor is taped out on Covenant's processor.{' '}
            </>
          )}
          {local && localOk && <>The browser also replayed both histories from the zero state and reached exactly states A and B. </>}
          {local && localOk === false && <b>The local simulation does not reproduce chips/out/fg.witness.json. </b>}
          {localErr && <>Local simulation failed: {localErr}. </>}
          {local && <span class="muted">Netlist keccak256 {local.keccak.slice(0, 18)}…</span>}
        </p>
      </div>

      <details>
        <summary>Repeat it from a terminal (two free read calls, no wallet)</summary>
        <Command label="State A:" line={cast(w.reachA.state)} />
        <Command label="State B:" line={cast(w.reachB.state)} />
        <p class="muted small">
          Each returns (new state, outputs). Outputs are 14 bytes, little-endian bit fields: bits 0–8 buy share, 18–26 allowance share,
          27–35 reserve share (each of 256), 72–80 release share of the reserve. The input words that reach each state are in{' '}
          <span class="mono">chips/out/fg.witness.json</span>.
        </p>
        <ol class="mono small reach">
          {w.reachB.inputs.map((x, i) => (
            <li key={i}>
              {x}
              {i === w.reachA.inputs.length - 1 && ' → state A'}
              {i === w.reachB.inputs.length - 1 && ' → state B'}
            </li>
          ))}
        </ol>
      </details>
    </section>
  );
}
