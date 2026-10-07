// #/c/:processor/:id
// Reads a circuit's netlist from X Layer, draws it, runs one beat in the browser and checks
// the result against the chain's own evaluator with a free eth_call.

import { useEffect, useRef, useState } from 'preact/hooks';
import { KIND_CONST, KIND_INPUT, KIND_LATCH, KIND_NAND, type DieShot, type Picked } from '@covenant/dieshot';
import { byteLength, bytesToHex, getBit, packBits, unpackBits, type Netlist } from '@covenant/tap20';
import { BitEditor } from '../components/BitEditor.tsx';
import { Address, Command, CopyButton } from '../components/common.tsx';
import { Die } from '../components/Die.tsx';
import { Icon } from '../components/Icon.tsx';
import { ADDR, CHAIN, rpc } from '../config.ts';
import { beatMethod, castFacts, castLine, chainBeat, loadCircuit, localBeat, sameBeat, type BeatResult, type CircuitData } from '../data/circuit.ts';
import { fmtInt, shortHex } from '../format.ts';
import { useAsync } from '../router.ts';
import { pageStyles } from '../styles/pages.ts';
import { Failure, Loading, PageHead } from './shared.tsx';

// The bench's rules (.bench, .beat-plate) are in pages.css, added when this chunk loads.
pageStyles();

type Status = 'checking' | 'match' | 'mismatch' | 'unverified';

interface Beat {
  n: number;
  /** What went in. */
  state: Uint8Array;
  inputs: Uint8Array;
  /** What this page computed, and what the chain returned. */
  local: BeatResult;
  chain: BeatResult | null;
  status: Status;
  error?: string;
  endpoint?: string;
}

export function Circuit({ processor, id }: { processor: string; id: string }) {
  const q = useAsync(() => loadCircuit(rpc, ADDR.factory, processor, BigInt(id)), [processor, id]);
  if (q.loading) return <Loading page what={`circuit ${id} from ${CHAIN.name}`} />;
  if (q.error || !q.data) return <Failure page error={q.error} retry={q.reload} />;
  // The key remounts the bench when another circuit is opened, so no state carries over.
  return <Bench key={`${q.data.processor}/${q.data.id}`} c={q.data} />;
}

// Cost of one evaluation on X Layer: about 2,340 gas per gate by `cast estimate` on the two
// large example circuits; rounded up here.
const GAS_PER_GATE = 2350;
const CALL_GAS_CAP = 50_000_000;

function Bench({ c }: { c: CircuitData }) {
  const nl = c.netlist;
  const [inputs, setInputs] = useState<Uint8Array>(() => new Uint8Array(byteLength(nl.nIn)));
  const [state, setState] = useState<Uint8Array>(() => new Uint8Array(byteLength(nl.nState)));
  const [beats, setBeats] = useState<Beat[]>([]);
  const [hover, setHover] = useState<Picked | null>(null);
  const [facts, setFacts] = useState<{ layoutHash: string; levels: number; cols: number; rows: number } | null>(null);
  const die = useRef<DieShot | null>(null);
  const signals = useRef<Uint8Array | null>(null);
  const playing = useRef(0); // id of the beat being animated, 0 when the picture is still
  const count = useRef(0);
  const latest = useRef({ inputs, state });
  latest.current = { inputs, state };

  // Keep the still picture in step with the editors, except while a beat is playing.
  useEffect(() => {
    if (!playing.current) die.current?.draw(signals.current, state, inputs);
  }, [inputs, state]);

  const clock = (): void => {
    // Read through the ref, and advance it at once, so two presses in the same tick still chain.
    const before = latest.current.state;
    const x = latest.current.inputs;
    const local = localBeat(nl, before, x);
    latest.current = { inputs: x, state: local.newStateBytes };
    const n = ++count.current;
    setBeats((list) => [{ n, state: before, inputs: x, local, chain: null, status: 'checking' as Status }, ...list].slice(0, 12));

    const previous = signals.current;
    signals.current = local.signals;
    const d = die.current;
    if (d) {
      playing.current = n;
      const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
      void d.animate(previous, local.signals, before, local.newStateBytes, still ? 0 : undefined).then(() => {
        if (playing.current !== n) return; // a later beat took over
        playing.current = 0;
        die.current?.draw(signals.current, latest.current.state, latest.current.inputs);
      });
    }
    setState(local.newStateBytes);

    const settle = (patch: Partial<Beat>): void => setBeats((list) => list.map((b) => (b.n === n ? { ...b, ...patch } : b)));
    chainBeat(rpc, c.processor, c.id, nl.nState, before, x).then(
      (chain) => settle({ chain, status: sameBeat(local, chain) ? 'match' : 'mismatch', endpoint: rpc.current() }),
      (e: unknown) => settle({ status: 'unverified', error: e instanceof Error ? e.message : String(e) }),
    );
  };

  const flip = (bytes: Uint8Array, n: number, i: number): Uint8Array => {
    const bits = unpackBits(bytes, n);
    bits[i] ^= 1;
    return packBits(bits);
  };
  const pick = (cell: Picked): void => {
    const lay = die.current?.layout;
    if (!lay || cell.output >= 0) return;
    const kind = lay.kind[cell.signal];
    if (kind === KIND_INPUT) setInputs(flip(inputs, nl.nIn, cell.signal - 2));
    else if (kind === KIND_LATCH) setState(flip(state, nl.nState, nl.stateBase[lay.element[cell.signal]]));
  };

  const shown = beats[0];
  const method = beatMethod(nl.nState);
  const tooBig = nl.gateCount * GAS_PER_GATE > CALL_GAS_CAP;

  return (
    <article class="page page--circuit">
      <PageHead
        crumbs={
          <>
            <a href="#/">Covenant</a> / <a href={`#/p/${c.processor}`}>processor{c.processorName ? ` ${c.processorName}` : ''}</a> / circuit {c.id.toString()}
          </>
        }
        title={
          <>
            {c.processorName || 'Circuit'} <em>#{c.id.toString()}</em>
          </>
        }
        lede={`${fmtInt(nl.gateCount)} gates, read from ${CHAIN.name} as ${fmtInt(nl.byteLength)} bytes. Everything below is computed in your browser from those bytes; the chain is asked only to confirm.`}
      />

      <section class="clause">
        <h2 class="clause__title">Facts</h2>
        <dl class="facts">
          <dt>Pins</dt>
          <dd>
            {fmtInt(nl.nIn)} in, {fmtInt(nl.nOut)} out
          </dd>
          <dt>State bits</dt>
          <dd>{nl.nState === 0 ? 'none (combinational)' : fmtInt(nl.nState)}</dd>
          <dt>Gates</dt>
          <dd>
            {fmtInt(nl.gateCount)} <span class="muted">({fmtInt(nl.nNand)} NAND + {fmtInt(nl.nLatch)} LATCH in this netlist{nl.nRef > 0 ? `, the rest inside ${nl.nRef} REF record${nl.nRef > 1 ? 's' : ''}` : ''})</span>
          </dd>
          <dt>Netlist</dt>
          <dd>{fmtInt(nl.byteLength)} bytes</dd>
          <dt>keccak256</dt>
          <dd class="mono">{c.keccak}</dd>
          <dt>Processor</dt>
          <dd>
            <Address value={c.processor} full />{' '}
            {c.registered === true && <span class="tag ok">registered with the TapeOut factory</span>}
            {c.registered === false && <span class="tag bad">not registered with the TapeOut factory</span>}
          </dd>
          <dt>Owner</dt>
          <dd>{c.owner ? <Address value={c.owner} full /> : 'unknown'}</dd>
          {c.block !== null && (
            <>
              <dt>Read at block</dt>
              <dd>{fmtInt(c.block)}</dd>
            </>
          )}
          {facts && (
            <>
              <dt>Logic depth</dt>
              <dd>
                {fmtInt(facts.levels)} level{facts.levels === 1 ? '' : 's'}
              </dd>
              <dt>Die</dt>
              <dd>
                {facts.cols} x {facts.rows} cells, pads included
              </dd>
              <dt>Layout hash</dt>
              <dd class="mono">{facts.layoutHash}</dd>
            </>
          )}
          <dt>Decoded here</dt>
          <dd>
            {c.consistent ? (
              <span class="tag ok">state bits and gate count equal circuitInfo</span>
            ) : (
              <span class="tag bad">
                decoded {nl.nState} state bits and {nl.gateCount} gates, but circuitInfo says {c.info.nState} and {c.info.gateCount}
              </span>
            )}
          </dd>
        </dl>
        {c.refs.length > 0 && (
          <p>
            This netlist uses REF. Referenced circuits, each fetched and checked the same way:{' '}
            {c.refs.map((r, i) => (
              <span key={`${r.cpu}/${r.id}`}>
                {i > 0 && ', '}
                <a href={`#/c/${r.cpu}/${r.id}`}>
                  <span class="mono">{r.cpu.slice(0, 10)}…</span> #{r.id.toString()}
                </a>{' '}
                ({fmtInt(r.info.gateCount)} gates)
              </span>
            ))}
            .
          </p>
        )}
      </section>

      <section class="clause band silicon bench">
        <h2 class="clause__title">Die shot</h2>
        <Die
          netlist={nl}
          onReady={(d) => {
            die.current = d;
            if (d) {
              setFacts({ layoutHash: d.layout.layoutHash, levels: d.layout.maxLevel, cols: d.layout.cols, rows: d.layout.rows });
              d.draw(signals.current, latest.current.state, latest.current.inputs);
            }
          }}
          onHover={setHover}
          onPick={pick}
        />
        <p class="hover mono" aria-live="off">
          {hover ? describe(nl, die.current, hover, signals.current, state, inputs) : 'Tap or point at a cell to read it. Tap or click an input pad or a register cell to flip it.'}
        </p>
        <ul class="legend">
          <li><i class="k pad" /> pads: inputs on the left, outputs on the right</li>
          <li><i class="k logic" /> NAND gate, lit when its output is 1</li>
          <li><i class="k latch" /> register strip: one cell per LATCH</li>
          <li><i class="k wire" /> wires; the state loop is drawn in a second colour</li>
        </ul>
        <p class="muted">
          Columns follow logic depth: a gate sits one level after the deepest signal it reads, so a beat sweeps left to right and ends
          at the register strip. The placement uses integers only, so the same bytes always give the same picture.
        </p>
      </section>

      <section class="clause band silicon bench">
        <h2 class="clause__title">Run one beat</h2>
        {nl.nIn > 0 ? (
          <BitEditor label="Inputs" noun="input" n={nl.nIn} value={inputs} onChange={setInputs} />
        ) : (
          <p class="muted">This circuit has no inputs: it is driven only by its state.</p>
        )}
        {nl.nState > 0 ? (
          <BitEditor label="State" noun="state bit" n={nl.nState} value={state} onChange={setState} />
        ) : (
          <p class="muted">This circuit has no state: its outputs depend on the inputs alone.</p>
        )}
        <div class="row">
          <button type="button" class="btn btn--primary press" onClick={clock}>
            Clock: run one beat
            <span class="btn__icon">
              <Icon name="arrow-right" />
            </span>
          </button>
          <span class="muted">
            Runs here, then asks the chain the same question with a free <span class="mono">{method}</span> call.
            {nl.nState > 0 && ' The new state becomes the state for the next beat.'}
          </span>
        </div>
        {tooBig && (
          <p class="warn">
            At about {fmtInt(GAS_PER_GATE)} gas per gate this circuit needs more than the {fmtInt(CALL_GAS_CAP)} gas a free call may use, so
            the chain may refuse the check.
          </p>
        )}

        {shown ? <Plate key={shown.n} beat={shown} nState={nl.nState} method={method} /> : <div class="plate idle">No beat run yet.</div>}

        <Command
          label={shown ? `The same check from a terminal (beat ${shown.n}; needs Foundry's cast):` : "What the check will ask the chain (needs Foundry's cast):"}
          line={castLine(c.processor, c.id, nl.nState, shown ? shown.state : state, shown ? shown.inputs : inputs, ADDR.rpc[0])}
        />
        <details>
          <summary>Commands for the facts above</summary>
          {castFacts(c.processor, c.id, ADDR.rpc[0]).map((f) => (
            <Command key={f.label} label={f.label} line={f.line} />
          ))}
        </details>
      </section>

      {beats.length > 0 && (
        <section class="clause">
          <h2 class="clause__title">Beats on this page</h2>
          <div class="scroll" tabIndex={0} role="region" aria-label="Beats on this page">
            <table>
              <thead>
                <tr>
                  <th>#</th>
                  <th>inputs</th>
                  {nl.nState > 0 && <th>state in</th>}
                  <th>outputs</th>
                  {nl.nState > 0 && <th>state out</th>}
                  <th>chain</th>
                  <th>
                    <span class="sr-only">actions</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {beats.map((b) => (
                  <tr key={b.n}>
                    <td>{b.n}</td>
                    <td class="mono">{shortHex(bytesToHex(b.inputs))}</td>
                    {nl.nState > 0 && <td class="mono">{shortHex(bytesToHex(b.state))}</td>}
                    <td class="mono">{shortHex(b.local.outputs)}</td>
                    {nl.nState > 0 && <td class="mono">{shortHex(b.local.newState)}</td>}
                    <td>
                      <span class={`tag ${TAG[b.status]}`}>{TITLE[b.status]}</span>
                    </td>
                    <td>
                      <button
                        type="button"
                        class="small press"
                        title="Put this beat's inputs and starting state back into the editors"
                        onClick={() => {
                          setInputs(b.inputs);
                          setState(b.state);
                        }}
                      >
                        load
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p class="muted">Kept in this tab only (the latest 12). Nothing is sent anywhere except the read calls to the RPC endpoint.</p>
        </section>
      )}
    </article>
  );
}

const TITLE: Record<Status, string> = { checking: 'CHECKING', match: 'MATCH', mismatch: 'MISMATCH', unverified: 'NOT CHECKED' };
const TAG: Record<Status, string> = { checking: 'wait', match: 'ok', mismatch: 'bad', unverified: 'warn' };

function Plate({ beat, nState, method }: { beat: Beat; nState: number; method: string }) {
  const chain = beat.chain;
  const statesAgree = chain !== null && chain.newState === beat.local.newState;
  return (
    <div class={`plate silicon beat-plate ${TAG[beat.status]}`} role="status">
      <div class="verdict">
        {/* a new element per status, so the verdict stamps in when the chain answers */}
        <strong key={beat.status}>{TITLE[beat.status]}</strong>
        <span>
          beat {beat.n}
          {beat.status === 'match' && `: your browser and the chain's ${method}() agree bit for bit`}
          {beat.status === 'mismatch' && `: your browser and the chain's ${method}() disagree`}
          {beat.status === 'checking' && `: asking the chain (${method} by eth_call)`}
          {beat.status === 'unverified' && ': the chain could not be asked, so nothing is confirmed'}
        </span>
      </div>
      <dl class="hexes">
        <dt>local outputs</dt>
        <dd class="mono">{beat.local.outputs}</dd>
        <dt>on-chain outputs</dt>
        <dd class="mono">{chain ? chain.outputs : beat.status === 'checking' ? '…' : 'not available'}</dd>
        {nState > 0 &&
          (statesAgree || chain === null ? (
            <>
              <dt>new state{statesAgree ? ' (local = on-chain)' : ' (local)'}</dt>
              <dd class="mono">{beat.local.newState}</dd>
            </>
          ) : (
            <>
              <dt>new state (local)</dt>
              <dd class="mono">{beat.local.newState}</dd>
              <dt>new state (on-chain)</dt>
              <dd class="mono">{chain.newState}</dd>
            </>
          ))}
      </dl>
      {beat.error && <p class="mono">RPC: {beat.error}</p>}
      <details>
        <summary>What went in</summary>
        <dl class="hexes">
          <dt>inputs</dt>
          <dd class="mono">
            {bytesToHex(beat.inputs)} <CopyButton text={bytesToHex(beat.inputs)} what="input bytes" small />
          </dd>
          {nState > 0 && (
            <>
              <dt>state</dt>
              <dd class="mono">
                {bytesToHex(beat.state)} <CopyButton text={bytesToHex(beat.state)} what="state bytes" small />
              </dd>
            </>
          )}
          {beat.endpoint && (
            <>
              <dt>answered by</dt>
              <dd class="mono">{beat.endpoint}</dd>
            </>
          )}
        </dl>
      </details>
    </div>
  );
}

// One line of text for the cell under the pointer.
function describe(nl: Netlist, die: DieShot | null, cell: Picked, signals: Uint8Array | null, state: Uint8Array, inputs: Uint8Array): string {
  if (!die) return '';
  const lay = die.layout;
  const s = cell.signal;
  const value = signals ? `; value ${signals[s]} in the last beat` : '';
  if (cell.output >= 0) return `output ${cell.output}, driven by signal ${s}${value}`;
  const kind = lay.kind[s];
  if (kind === KIND_CONST) return `constant ${s} (signal ${s})`;
  if (kind === KIND_INPUT) return `input ${s - 2} (signal ${s}), set to ${getBit(inputs, s - 2)}. Click to flip.`;
  const e = lay.element[s];
  if (kind === KIND_LATCH) {
    const bit = nl.stateBase[e];
    return `LATCH, record ${e}: state bit ${bit} (signal ${s}), holds ${getBit(state, bit)}; at the clock edge it stores signal ${nl.a[e]}. Click to flip.`;
  }
  if (kind === KIND_NAND) {
    return `signal ${s} = NAND(signal ${nl.a[e]}, signal ${nl.b[e]}); record ${e}, level ${lay.level[s]}${value}`;
  }
  const r = nl.refs[nl.b[e]];
  return `signal ${s}: output ${s - nl.out[e]} of a REF to ${r.cpu.slice(0, 10)}… #${r.id}; record ${e}, level ${lay.level[s]}${value}`;
}
