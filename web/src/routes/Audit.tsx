// #/k/:kernel/:n
// Audit one settle: the record as the kernel stored it, recomputed by the Lens on both evaluators and by this
// browser from the netlist bytes; what the envelope clipped and why; and whether the chip's state changed the route.
// On a v2 kernel (USD₮0 quote) the amounts are USD₮0 on the curve, the input codes carry the kernel's code shift, and
// the Lens is LensV2 (data/kernel.ts loadAudit picks it by factory).

import { useRef } from 'preact/hooks';
import type { DieShot } from '@covenant/dieshot';
import { toBytes } from '@covenant/chain';
import type { Replay } from '@covenant/chain/kernel';
import { Command } from '../components/common.tsx';
import { Die } from '../components/Die.tsx';
import { Icon } from '../components/Icon.tsx';
import { Seal } from '../components/Seal.tsx';
import { CheckRow, Pin, RouteBar, SimBanner } from '../components/kit.tsx';
import { CAST_RPC, CHAIN, COVENANT, rpc } from '../config.ts';
import { loadAudit, loadNetlist, quoteLegIn, type AuditData } from '../data/kernel.ts';
import { amount, approx, approxCodeIn, FG_KECCAK, fgFlagNames, fgModeName, pct256, routeView, type Unit } from '../kernel/chip.ts';
import { bitsOf, CLAMPS, exp8s, fallbackWord, bytesOf, inputFields, lg8, lg8s, LG8_MAX, outputFields, RECORD_FLAGS, route, stateBytes, wordOf } from '../kernel/model.ts';
import { beat, chipFromBytes, replayLocal } from '../kernel/sim.ts';
import { fmtTime, fmtUnits, shortHex } from '../format.ts';
import { useAsync } from '../router.ts';
import { Failure, Loading, PageHead } from './shared.tsx';

export function Audit({ kernel, n }: { kernel: string; n: number }) {
  const q = useAsync(async () => {
    if (!COVENANT.lens && !COVENANT.lensV2) throw new Error('No Lens is in deployments/xlayer.json yet, so the on-chain replays cannot be asked.');
    const a = await loadAudit(rpc, COVENANT, kernel, n);
    const nl = await loadNetlist(rpc, a.globals);
    return { a, chip: chipFromBytes(`chip ${a.globals.chipId}`, nl.bytes), keccak: nl.keccak };
  }, [kernel, n]);
  if (q.loading) return <Loading what={`settle ${n} of ${kernel.slice(0, 10)}… and its replays from ${CHAIN.name}`} />;
  if (q.error || !q.data) return <Failure error={q.error} retry={q.reload} />;
  return <View key={`${kernel}/${n}`} kernel={kernel} d={q.data.a} chip={q.data.chip} isFG={q.data.keccak === FG_KECCAK} />;
}

type Cell = { outputs: string; state: string } | Error | null;

function View({ kernel, d, chip, isFG }: { kernel: string; d: AuditData; chip: ReturnType<typeof chipFromBytes>; isFG: boolean }) {
  const { row, envelope: e, globals: g } = d;
  const r = row.rec;
  const n = row.n;
  const fallback = (r.flags & 1) !== 0;
  const grad = (r.flags & 64) !== 0;
  const v2 = d.kind.version === 2;
  /** The kernel's code shift for this record: its quoteShift on the curve, 0 after graduation and on kernel v1. */
  const sh = grad ? 0 : d.kind.shift;
  const qu: Unit = { symbol: d.kind.quoteSymbol, decimals: d.kind.quoteDecimals };
  /** The record's regime asset. */
  const ru: Unit = grad ? { symbol: 'tokens', decimals: 18 } : qu;
  const die = useRef<DieShot | null>(null);

  // the browser's own recomputation
  const local = fallback ? null : replayLocal(chip.netlist, row.stateBefore, r.inputs);
  const localCell: Cell = fallback ? { outputs: bytesOf(fallbackWord(e.fbAllow, e.relMax), 14), state: row.stateBefore } : { outputs: local!.outputs, state: local!.stateAfter32 };
  const lensCell = (x: Replay | Error): Cell => (x instanceof Error ? x : x.ran ? { outputs: x.outputs, state: x.stateAfter } : new Error('the evaluator did not answer within the gas a settle gives it'));
  const cells: { name: string; c: Cell; note: string }[] = [
    { name: 'kernel record', c: { outputs: r.outputs, state: r.stateAfter }, note: `records(${n})` },
    { name: "TapeOut's step", c: lensCell(d.replayTapeout), note: 'Lens.replayOn(…, false)' },
    { name: 'SealedVM', c: lensCell(d.replaySealed), note: 'Lens.replayOn(…, true)' },
    { name: 'this browser', c: localCell, note: 'TAP-20 simulator' },
  ];
  const eq = (c: Cell, k: 'outputs' | 'state'): boolean | null => (c === null || c instanceof Error ? null : c[k].toLowerCase() === (k === 'outputs' ? r.outputs : r.stateAfter).toLowerCase());
  const allMatch = cells.every((c) => eq(c.c, 'outputs') === true && eq(c.c, 'state') === true);

  // the kernel's routing, recomputed with the TypeScript port of its clip
  const allowBefore = row.allowPaidCum - r.allow;
  const rt = route(e, wordOf(r.outputs), r.inflow, r.reserveBefore, row.cumInflow, allowBefore, grad, sh);
  const amountsOk = rt.clamp === r.clampBits && rt.allow === r.allow && rt.buyDecided === r.buyDecided && r.buyExecuted <= r.buyDecided;
  const lensT = d.replayTapeout instanceof Error ? null : d.replayTapeout;
  const ask = outputFields(r.outputs);
  const x = inputFields(r.inputs);
  const view = routeView(r.outputs);
  const unit = ru.symbol;
  const codeNote = (x: bigint): string => (sh > 0 && x > 0n ? ` = lg8 ${lg8(x)} + ${8 * sh} (the shift)` : '');
  const sm = d.stateMatters instanceof Error ? null : d.stateMatters;
  const zeroLocal = fallback ? null : beat(chip.netlist, '0x' + '00'.repeat(Math.ceil(g.nState / 8)), r.inputs).outputs;

  const play = (): void => {
    if (!die.current || !local) return;
    const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
    void die.current.animate(null, local.signals, toBytes(stateBytes(row.stateBefore, g.nState)), toBytes(stateBytes(r.stateAfter, g.nState)), still ? 0 : undefined);
  };

  return (
    <article class="page page--audit">
      <SimBanner />
      <PageHead
        crumbs={
          <>
            <a href="#/">Covenant</a> / <a href={`#/k/${kernel}`}>vault</a> / settle {n}
          </>
        }
        title={
          <>
            Settle #{n}, <em>recomputed three ways</em>
          </>
        }
        lede={
          <>
            The kernel stored what its chip answered on {fmtTime(r.time)} (epoch {r.epoch}). Below, the chain's two evaluators and this browser
            compute the same step again from the stored state and inputs, and the kernel's routing is recomputed from the stored answer.
          </>
        }
      >
        {v2 && (
          <p class="muted small">
            Kernel v2 (USD₮0 quote): amounts are {qu.symbol} on the curve, project tokens after graduation; the chip reads them through a fixed shift of{' '}
            {d.kind.shift} bits (<a href={`#/k/${kernel}`}>vault page</a>, section 03).
          </p>
        )}
      </PageHead>

      <section class="clause audit-verdict" aria-label="Four answers to the same step">
        <span class="clause__no" aria-hidden="true">
          Verdict
        </span>
        {/* The page's one beat: the four answers stamp down one after another, then the verdict. */}
        <div class="evaluators bleed">
          {cells.map((c, k) => {
            const cell = c.c;
            const verdict = cell === null || cell instanceof Error ? null : eq(cell, 'outputs') === true && eq(cell, 'state') === true;
            return (
              <div key={c.name} class={`plate silicon evaluator ${verdict === null ? 'warn' : verdict ? 'ok' : 'bad'}`} style={{ '--i': k }}>
                <div class="evaluator__head">
                  <b>{c.name}</b>
                  <span class="micro">{c.note}</span>
                </div>
                {cell instanceof Error ? (
                  <p class="small warn">{cell.message}</p>
                ) : cell ? (
                  <dl class="evaluator__rows">
                    {(['outputs', 'state'] as const).map((key) => (
                      <div key={key}>
                        <dt class="micro">{key === 'outputs' ? 'outputs (14 bytes)' : 'new state'}</dt>
                        <dd class="mono small">
                          <span class={`mark ${eq(cell, key) ? 'ok' : 'bad'}`}>{eq(cell, key) ? '✓' : '✗'}</span>{' '}
                          {shortHex(key === 'state' ? '0x' + cell.state.slice(2, 2 + 2 * Math.ceil(g.nState / 8)) : cell.outputs, 8)}
                        </dd>
                      </div>
                    ))}
                  </dl>
                ) : null}
                <div class="verdict">
                  <strong>{verdict === null ? 'NOT ASKED' : verdict ? 'MATCH' : 'MISMATCH'}</strong>
                </div>
              </div>
            );
          })}
        </div>
      <div class={`plate silicon audit-sum ${allMatch && amountsOk ? 'ok' : 'bad'}`}>
        <div class="verdict">
          <strong>{allMatch && amountsOk ? 'MATCH' : 'MISMATCH'}</strong>
          <span>
            {allMatch ? 'outputs and new state agree four ways' : 'the four answers do not all agree'}; {amountsOk ? 'the routed amounts follow from the envelope' : 'the routed amounts do not follow'}
          </span>
        </div>
        {fallback && <p class="small">This record applied the fallback word (flag 1): no evaluator answered, the state was left as it was.</p>}
        <ul class="checks small">
          <CheckRow
            ok={amountsOk}
            note={`TypeScript port of the kernel's clip (tested against chips/golden/vectors.json${v2 ? ' and vectors_v2.json' : ''}) on the stored outputs, inflow, reserve and totals${sh > 0 ? `, through the ${sh}-bit shift` : ''}`}
          >
            Allowance {amount(rt.allow, qu)}, buy decided {approx(rt.buyDecided, ru.decimals)} {unit}, clamp bits {rt.clamp}: as recorded
          </CheckRow>
          {sh > 0 && (
            <CheckRow ok={x.TAX === lg8s(r.inflow, sh) && x.TAXCUM === lg8s(row.cumInflow, sh) && x.RES === lg8s(r.reserveBefore, sh)} note={`computed here: lg8(amount << ${sh}) for the inflow, the cumulative inflow and the reserve`}>
              The input word's TAX, TAXCUM and RES are the stored amounts' codes plus {8 * sh}
            </CheckRow>
          )}
          <CheckRow ok={lensT ? lensT.amountsMatch && lensT.inputsMatch : null} note={`Lens${v2 ? 'V2' : ''}: KernelMath${v2 ? 'V2' : ''}.route over the stored values, and the input word's TAX, TAXCUM, RES and GRAD codes against the stored amounts`}>
            The Lens agrees on the amounts and the input word
          </CheckRow>
        </ul>
      </div>
      </section>

      <section class="clause">
        <Pin id="01">What went in</Pin>
        <dl class="facts">
          <dt>Input word</dt>
          <dd class="mono">{r.inputs}</dd>
          <dt>{v2 ? 'Inflow this settle' : 'Tax this settle'}</dt>
          <dd>
            {fmtUnits(r.inflow, ru.decimals)} {unit}{' '}
            <span class="muted">
              (code TAX {x.TAX}
              {codeNote(r.inflow)} ≈ {approxCodeIn(x.TAX, sh, ru.decimals)})
            </span>
            {v2 && !grad && <div class="muted small">Tax claimed from the vault plus any {qu.symbol} paid to the kernel directly (revenue), routed as tax: the kernel cannot tell them apart.</div>}
          </dd>
          <dt>{v2 ? 'Inflow so far' : 'Tax so far'}</dt>
          <dd>
            {fmtUnits(row.cumInflow, ru.decimals)} {unit} <span class="muted">(TAXCUM {x.TAXCUM}{codeNote(row.cumInflow)})</span>
          </dd>
          <dt>Reserve before</dt>
          <dd>
            {fmtUnits(r.reserveBefore, ru.decimals)} {unit} <span class="muted">(RES {x.RES}{codeNote(r.reserveBefore)})</span>
          </dd>
          <dt>Other inputs</dt>
          <dd class="small">
            DT {x.DT} epoch{x.DT === 1 ? '' : 's'} since the last step · curve progress {x.PROG}/255 · locked {x.LOCK}/255 · graduated {x.GRAD}
          </dd>
          <dt>State before</dt>
          <dd class="mono small">{stateBytes(row.stateBefore, g.nState)}{n === 1 && ' (zero: the first step)'}</dd>
        </dl>
        <div class="audit-die bleed silicon">
          <Die
            maxHeight={440}
            netlist={chip.netlist}
            onReady={(dd) => {
              die.current = dd;
              play();
            }}
            onHover={() => {}}
            onPick={() => {}}
            label={`This settle's step drawn on chip ${g.chipId}`}
          />
          <div class="audit-seals">
            <figure>
              <Seal hex={stateBytes(row.stateBefore, g.nState)} n={g.nState} size={104} label="State before this settle" />
              <figcaption class="micro">before</figcaption>
            </figure>
            <Icon name="arrow-right" size={24} class="audit-seals__arrow" />
            <figure>
              <Seal hex={stateBytes(r.stateAfter, g.nState)} n={g.nState} size={104} label="State after this settle, as recorded" />
              <figcaption class="micro">after, as recorded</figcaption>
            </figure>
            <button type="button" class="small press" onClick={play} disabled={!local}>
              play this step again
            </button>
          </div>
        </div>
      </section>

      <section class="clause">
        <Pin id="02">What the chip asked, and what the envelope let through</Pin>
        <div class="pair">
          <div class="chipcard">
            <div class="cardhead">
              <span class="pinid">CHIP ASKED</span>
              {isFG && <span>{fgModeName(view.mode)} {fgFlagNames(view.flags).map((f) => <span class="flag" key={f}>{f}</span>)}</span>}
            </div>
            <RouteBar view={view} />
            <div class="small muted">
              own allowance ceiling: {grad ? 'not used (no allowance after graduation)' : view.ceil >= LG8_MAX ? 'none' : `${amount(exp8s(view.ceil, sh), qu)}${sh > 0 ? ` (exp8(${view.ceil}) >> ${sh})` : ''}`}
            </div>
          </div>
          <div class="chipcard">
            <div class="cardhead">
              <span class="pinid">KERNEL ROUTED</span>
            </div>
            <RouteBar view={{ ...view, buy: rt.shares[0], hold: rt.shares[1], allow: rt.shares[2], res: rt.shares[3], rel: rt.rel, wellFormed: true }} />
            <div class="small">
              allowance credited <b>{fmtUnits(r.allow, qu.decimals)}</b> {qu.symbol} · buy decided <b>{fmtUnits(r.buyDecided, ru.decimals)}</b> {unit} (executed{' '}
              {fmtUnits(r.buyExecuted, ru.decimals)}) · {grad ? 'burned' : 'tokens bought'} {approx(r.tokensOut)}
              {grad && quoteLegIn(r) > 0n && (
                <>
                  {' '}
                  · quote leg: <b>{fmtUnits(quoteLegIn(r), qu.decimals)}</b> {qu.symbol} spent on the pair, tokens to 0xdEaD
                </>
              )}
            </div>
          </div>
        </div>
        {r.clampBits === 0 ? (
          <p>
            <b>No clamp fired:</b> the envelope did not have to correct the chip in this settle.{' '}
            {isFG && 'For the Flow Governor this holds on every settle: its proofs show no clamp can fire under this envelope.'}
          </p>
        ) : (
          <ul>
            {bitsOf(CLAMPS, r.clampBits).map((c) => (
              <li key={c.name}>
                <b class="mono">{c.name}</b>: {c.what}.
              </li>
            ))}
          </ul>
        )}
        <table class="limits small">
          <tbody>
            <tr>
              <th>allowance share</th>
              <td>asked {pct256(ask.T_ALLOW)}</td>
              <td>cap {pct256(e.capT)}</td>
              <td>{grad ? 'no allowance after graduation' : ask.T_ALLOW > e.capT ? 'clipped (K2)' : 'within'}</td>
            </tr>
            {!grad && (
              <>
                <tr>
                  <th>allowance per settle</th>
                  <td>{amount((r.inflow * BigInt(Math.min(ask.T_ALLOW, e.capT))) / 256n, qu)}</td>
                  <td>ceiling {e.ceilMax >= LG8_MAX ? 'none' : amount(exp8s(e.ceilMax, sh), qu)}</td>
                  <td>{(r.clampBits & 8) !== 0 ? 'clipped (K2C)' : 'within'}</td>
                </tr>
                <tr>
                  <th>allowance for life</th>
                  <td>{amount(allowBefore + r.allow, qu)} after this settle</td>
                  <td>cap {amount((row.cumInflow * BigInt(e.allowCumBps)) / 10000n, qu)}</td>
                  <td>{(r.clampBits & 16) !== 0 ? 'clipped (K2L)' : 'within'}</td>
                </tr>
              </>
            )}
            <tr>
              <th>release</th>
              <td>asked {pct256(ask.REL)}</td>
              <td>
                max {pct256(e.relMax)}, floor {pct256(e.floorRel)}
              </td>
              <td>{(r.clampBits & 32) !== 0 ? 'clipped (K3)' : (r.clampBits & 64) !== 0 ? 'raised to the floor (K5)' : 'within'}</td>
            </tr>
          </tbody>
        </table>
        {r.flags !== 0 && (
          <p class="small">
            Record flags:{' '}
            {bitsOf(RECORD_FLAGS, r.flags)
              .map((f) => `${f.name} (${f.what})`)
              .join('; ')}
            .
          </p>
        )}
        {v2 && grad && (r.flags & (16 | 32 | 128)) !== 0 && (
          <p class="small muted">
            After graduation two legs share the buy flags (chips/INTERFACE-V2.md section 10): buy skipped and buy shrunk are the quote leg's (the {qu.symbol} pot bought
            on the pair); buy failed is the burn leg's when executed &lt; decided ({r.buyExecuted < r.buyDecided ? 'here: yes' : 'here: no'}), and the quote leg's
            otherwise.
          </p>
        )}
      </section>

      <section class="clause">
        <Pin id="03">Would a different state have routed differently?</Pin>
        {fallback ? (
          <p>Not asked for a fallback record: the chip did not answer.</p>
        ) : (
          <>
            <p class="muted">
              Lens.stateMatters steps the chip twice on this settle's inputs: from the state the kernel held, and from the all-zero state every
              chip starts in. It says yes when the shares, the release or the ceiling differ.
            </p>
            {d.stateMatters instanceof Error && <p class="warn">{d.stateMatters.message}</p>}
            <div class="pair">
              <div class="chipcard">
                <div class="cardhead">
                  <span class="pinid">WITH THE KERNEL'S STATE</span>
                </div>
                <RouteBar view={routeView(sm?.withState ?? r.outputs)} compact />
              </div>
              <div class="chipcard">
                <div class="cardhead">
                  <span class="pinid">WITH THE ZERO STATE</span>
                </div>
                <RouteBar view={routeView(sm?.withOther ?? zeroLocal!)} compact />
              </div>
            </div>
            <p>
              {sm ? (
                <b>{sm.matters ? 'Yes: the state changed the route of this settle.' : 'No: in this settle the state did not change the route.'}</b>
              ) : (
                'The Lens could not be asked; the right-hand route is the browser’s own.'
              )}{' '}
              {sm && zeroLocal && <span class="muted small">The browser's zero-state step gives {zeroLocal === sm.withOther ? 'the same outputs' : 'DIFFERENT outputs'}.</span>}
            </p>
          </>
        )}
      </section>

      <section class="clause">
        <Pin id="04">Repeat from a terminal</Pin>
        <Command label="The record:" line={`cast call ${kernel} "records(uint32)((uint32,uint40,uint16,uint8,bytes12,bytes14,bytes32,uint128,uint128,uint128,uint128,uint128,uint128,uint128))" ${n} --rpc-url ${CAST_RPC}`} />
        <Command
          label="The same step on TapeOut's evaluator (state before, stored inputs):"
          line={`cast call ${g.circuits} "step(uint256,bytes,bytes)(bytes,bytes)" ${g.chipId} ${stateBytes(row.stateBefore, g.nState)} ${r.inputs} --rpc-url ${CAST_RPC}`}
        />
        {d.kind.lens && (
          <>
            <Command label={`The Lens${v2 ? 'V2' : ''} replay on each evaluator (false = TapeOut, true = SealedVM):`} line={`cast call ${d.kind.lens} "replayOn(address,uint32,bool)((bool,bool,bool,bool,bool,bool,bool,bytes14,bytes32))" ${kernel} ${n} false --rpc-url ${CAST_RPC}`} />
            <Command line={`cast call ${d.kind.lens} "stateMatters(address,uint32)(bool,bytes14,bytes14)" ${kernel} ${n} --rpc-url ${CAST_RPC}`} />
          </>
        )}
        <nav class="pager" aria-label="Settles">
          {n > 1 && <a href={`#/k/${kernel}/${n - 1}`}>← settle {n - 1}</a>}
          <a href={`#/k/${kernel}`}>all settles</a>
          {n < d.count && <a href={`#/k/${kernel}/${n + 1}`}>settle {n + 1} →</a>}
        </nav>
      </section>
    </article>
  );
}
