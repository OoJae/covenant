// #/hostile
// The Glutton: a chip written to take everything. Its raw demand, what one settle under the envelope lets through,
// and a shadow run over a real kernel's recorded tax: computed here with the TypeScript port of the kernel's clip,
// and, once a Glutton is taped out next to the kernel, by the Lens on chain. The same on a kernel v2 (USD₮0 quote):
// amounts in USD₮0, the chip reading them through the kernel's code shift; its shadow run once one is recorded.

import { useState } from 'preact/hooks';
import { readAll } from '@covenant/chain';
import { kernel as kernelCalls, kernelV2 as kernelV2Calls, type Envelope } from '@covenant/chain/kernel';
import { Command } from '../components/common.tsx';
import { EnvelopeWords } from '../components/EnvelopeWords.tsx';
import { Pin, RouteBar, SimBanner } from '../components/kit.tsx';
import { Segmented } from '../components/Segmented.tsx';
import { CAST_RPC, COVENANT, rpc } from '../config.ts';
import { loadRecords, loadShadowChip } from '../data/kernel.ts';
import { amount, approx, OKB_UNIT, pct256, REF_ENVELOPE, routeView, V2_REFERENCE, witness, type Unit } from '../kernel/chip.ts';
import { bitsOf, bytesOf, CLAMPS, exp8s, INPUT_FIELDS, lg8s, pack, route, wordOf, type Routed } from '../kernel/model.ts';
import { beat, flowGovernor, glutton, glutton512, shadowRun, type ShadowRow } from '../kernel/sim.ts';
import { fmtUnits } from '../format.ts';
import { useAsync } from '../router.ts';
import { PageHead } from './shared.tsx';

const OKB = 10n ** 18n;
const TAX_CHOICES: [string, bigint][] = [
  ['0.001', OKB / 1000n],
  ['0.01', OKB / 100n],
  ['0.1', OKB / 10n],
  ['1', OKB],
  ['3', 3n * OKB],
];
const RES_CHOICES: [string, bigint][] = [
  ['0', 0n],
  ['0.01', OKB / 100n],
  ['0.1', OKB / 10n],
  ['1', OKB],
];
// Kernel v2: USD₮0, 6 decimals. One $0.50 x402 call is the smallest choice.
const USD = 10n ** 6n;
const USDT0: Unit = { symbol: 'USD₮0', decimals: 6 };
const TAX_CHOICES_V2: [string, bigint][] = [
  ['0.5', USD / 2n],
  ['5', 5n * USD],
  ['50', 50n * USD],
  ['500', 500n * USD],
  ['3,000', 3000n * USD],
];
const RES_CHOICES_V2: [string, bigint][] = [
  ['0', 0n],
  ['1', USD],
  ['50', 50n * USD],
  ['500', 500n * USD],
];

type Env = Pick<Envelope, 'epochLen' | 'capT' | 'allowCumBps' | 'ceilMax' | 'relMax' | 'floorRel' | 'floorMin' | 'fallbackEpochs' | 'fbAllow'>;

export function Hostile() {
  // The flagship kernel's own envelope when there is one; until then the reference envelope it will be created with.
  const k = useAsync(async () => {
    if (!COVENANT.kernel) return null;
    const kc = kernelCalls(COVENANT.kernel);
    const [env, count] = await readAll(rpc, [kc.envelope(), kc.count()] as const);
    if (env instanceof Error || count instanceof Error) return null;
    return { env, count };
  }, []);
  // The v2 flagship kernel (USD₮0 quote), once deployments/xlayer.json records it; until then the reference envelope
  // and the reference shift it will be created with.
  const k2 = useAsync(async () => {
    if (!COVENANT.kernelV2) return null;
    const kc = kernelV2Calls(COVENANT.kernelV2);
    const [env2, count2, shift2] = await readAll(rpc, [kc.envelope(), kc.count(), kc.quoteShift()] as const);
    if (env2 instanceof Error || count2 instanceof Error || shift2 instanceof Error) return null;
    return { env: env2, count: count2, shift: shift2 };
  }, []);
  const [v2, setV2] = useState(false);
  const env: Env = (v2 ? k2.data?.env : k.data?.env) ?? REF_ENVELOPE;
  /** The kernel's code shift in bits: 0 on kernel v1. */
  const sh = v2 ? (k2.data?.shift ?? V2_REFERENCE.shift) : 0;
  const unit: Unit = v2 ? USDT0 : OKB_UNIT;
  const taxChoices = v2 ? TAX_CHOICES_V2 : TAX_CHOICES;
  const resChoices = v2 ? RES_CHOICES_V2 : RES_CHOICES;
  const gl = glutton();
  const g512 = glutton512();
  const zero12 = '0x' + '00'.repeat(12);
  const demand = beat(gl.netlist, '0x00', zero12).outputs;
  const demand512 = beat(g512.netlist, '0x00', zero12).outputs;
  const [tax, setTax] = useState(1);
  const [res, setRes] = useState(1);
  const inflow = taxChoices[tax][1];
  const reserve0 = resChoices[res][1];

  // The Flow Governor on the same settle, from a cold start: its input word is what the kernel would assemble
  // (on kernel v2 every amount code is lg8(amount << shift)).
  const fg = flowGovernor();
  const fgIn = bytesOf(pack(INPUT_FIELDS, { TAX: lg8s(inflow, sh), TAXCUM: lg8s(inflow, sh), RES: lg8s(reserve0, sh), DT: 1 }), 12);
  const fgOut = beat(fg.netlist, '0x' + '00'.repeat(8), fgIn).outputs;
  const fgWarm = beat(fg.netlist, witness.reachA.state, fgIn).outputs;
  const one = (out: string): Routed => route(env, wordOf(out), inflow, reserve0, inflow, 0n, false, sh);
  const clipped = route(REF_ENVELOPE, wordOf(demand), OKB / 100n, OKB / 100n, OKB / 100n, 0n, false);
  const refCeilV2 = exp8s(REF_ENVELOPE.ceilMax, k2.data?.shift ?? V2_REFERENCE.shift);
  const chips = [
    { name: 'Glutton', out: demand, note: 'asks 100% allowance, 100% release, no ceiling' },
    { name: 'Glutton512', out: demand512, note: 'asks 256 + 256 of 256: a malformed share group' },
    { name: 'Flow Governor, cold start', out: fgOut, note: 'the flagship chip, zero state' },
    { name: 'Flow Governor, state A', out: fgWarm, note: 'the flagship chip after four epochs (landing page)' },
  ];

  return (
    <article class="page page--hostile">
      <SimBanner />
      <PageHead
        crumbs={
          <>
            <a href="#/">Covenant</a> / hostile chip
          </>
        }
        title={
          <>
            A chip that asks for everything gets <em>the envelope's cap and nothing more</em>
          </>
        }
        lede={
          <>
            Anyone can write a chip, and a kernel cannot know what a stranger's chip will answer. So the kernel clips every answer to its envelope
            before any money moves. The Glutton (<span class="mono">chips/cells/glutton</span>, 113 NAND + 1 latch) demands the whole tax as
            allowance and the whole reserve every settle, whatever its inputs.
          </>
        }
      />

      <section class="clause">
        <Pin id="01">What it asks for, and what it gets</Pin>
        <div class="pair">
          <div class="chipcard">
            <div class="cardhead">
              <span class="pinid">GLUTTON</span>
              <span class="mono muted small">{demand}</span>
            </div>
            <RouteBar view={routeView(demand)} />
            <p class="small muted">and no ceiling on the allowance amount (CEIL = 1023)</p>
          </div>
          <div class="chipcard">
            <div class="cardhead">
              <span class="pinid">KERNEL LETS THROUGH</span>
              <span class="small muted">clamps {bitsOf(CLAMPS, clipped.clamp).map((b) => b.name).join(' + ')}</span>
            </div>
            <RouteBar view={{ ...routeView(demand), buy: clipped.shares[0], hold: clipped.shares[1], allow: clipped.shares[2], res: clipped.shares[3], rel: clipped.rel, wellFormed: true }} />
            <p class="small muted">
              and at most {amount(exp8s(REF_ENVELOPE.ceilMax, 0), OKB_UNIT)} of allowance per settle on a kernel v1, {amount(refCeilV2, USDT0)} on a kernel v2
              (USD₮0 quote), {REF_ENVELOPE.allowCumBps / 100}% of all tax for life
            </p>
          </div>
        </div>
        <details>
          <summary>The envelope in full ({(v2 ? k2.data : k.data) ? `the ${v2 ? 'v2 ' : ''}flagship kernel’s, read from the chain` : `the reference envelope of LaunchChip${v2 ? 'V2' : ''}.s.sol`})</summary>
          <EnvelopeWords e={env} unit={unit} shift={sh} />
        </details>
      </section>

      <section class="clause">
        <Pin id="02">One settle, clipped</Pin>
        <p class="muted">
          Local simulation of the kernel's clip, tested against the golden vectors (<span class="mono">chips/golden/vectors.json</span> and{' '}
          <span class="mono">vectors_v2.json</span>, the same ones the Solidity kernels pass). The chips are the real netlist bytes, stepped in your browser.
        </p>
        <div class="controls">
          <span class="label">Kernel</span>
          <Segmented
            label="Kernel"
            value={v2}
            onChange={setV2}
            options={[
              { value: false, text: 'v1, OKB quote' },
              { value: true, text: 'v2, USD₮0 quote' },
            ]}
          />
        </div>
        {v2 && (
          <p class="small muted">
            On kernel v2 the chip reads {USDT0.symbol} through a code shift of {sh} bits: every amount code is lg8(amount) + {8 * sh}, and the envelope's ceilMax{' '}
            {env.ceilMax} is read as {amount(exp8s(env.ceilMax, sh), USDT0)} per settle.
          </p>
        )}
        <div class="controls">
          <span class="label" id="tax-label">
            {v2 ? 'Inflow this settle (tax and revenue)' : 'Tax this settle'}
          </span>
          <div class="chips" role="group" aria-labelledby="tax-label">
            {taxChoices.map(([label], i) => (
              <button type="button" key={label} class="small" aria-pressed={i === tax} onClick={() => setTax(i)}>
                {label} {unit.symbol}
              </button>
            ))}
          </div>
        </div>
        <div class="controls">
          <span class="label" id="res-label">
            Reserve before
          </span>
          <div class="chips" role="group" aria-labelledby="res-label">
            {resChoices.map(([label], i) => (
              <button type="button" key={label} class="small" aria-pressed={i === res} onClick={() => setRes(i)}>
                {label} {unit.symbol}
              </button>
            ))}
          </div>
        </div>
        <div class="scroll">
          <table class="clip">
            <thead>
              <tr>
                <th>chip</th>
                <th>asked: allowance / release</th>
                <th class="num">allowance paid</th>
                <th class="num">bought and locked</th>
                <th class="num">reserve after</th>
                <th>clamps</th>
              </tr>
            </thead>
            <tbody>
              {chips.map((c) => {
                const v = routeView(c.out);
                const r = one(c.out);
                return (
                  <tr key={c.name}>
                    <td>
                      <b>{c.name}</b>
                      <div class="muted small">{c.note}</div>
                    </td>
                    <td class="mono">
                      {v.wellFormed ? pct256(v.allow) : 'malformed'} / {pct256(v.rel)}
                    </td>
                    <td class="num mono">{approx(r.allow, unit.decimals)}</td>
                    <td class="num mono">{approx(r.buyDecided, unit.decimals)}</td>
                    <td class="num mono">{approx(r.reserveAfter, unit.decimals)}</td>
                    <td class="small">
                      {r.clamp === 0 ? <span class="muted">none</span> : bitsOf(CLAMPS, r.clamp).map((b) => <div key={b.name}><b class="mono">{b.name}</b> {b.what}</div>)}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
        <p class="small">
          On a first settle of {taxChoices[tax][0]} {unit.symbol} the Glutton gets at most {pct256(env.capT)} of it, capped at {amount(one(demand).allow, unit)} here;
          the rest is bought and locked or waits in the reserve, and the reserve still leaves at {pct256(env.relMax)} per settle. Glutton512 gets
          nothing: a share group that does not sum to 256 is read as 100% reserve. Neither can make a settle revert.
        </p>
      </section>

      <ShadowSection count={k.data?.count ?? 0} env={k.data?.env ?? REF_ENVELOPE} kernel={COVENANT.kernel} lensAddr={COVENANT.lens} shift={0} unit={OKB_UNIT} pin="03" />
      {COVENANT.kernelV2 && (
        <ShadowSection count={k2.data?.count ?? 0} env={k2.data?.env ?? REF_ENVELOPE} kernel={COVENANT.kernelV2} lensAddr={COVENANT.lensV2} shift={k2.data?.shift ?? V2_REFERENCE.shift} unit={USDT0} pin="04" />
      )}
    </article>
  );
}

function ShadowSection({ count, env, kernel, lensAddr, shift, unit, pin }: { count: number; env: Env; kernel: string | null; lensAddr: string | null; shift: number; unit: Unit; pin: string }) {
  const v2 = shift > 0;
  const q = useAsync(async () => {
    if (!kernel || count === 0) return null;
    const rows = await loadRecords(rpc, kernel, 1, count, v2 ? 2 : 1);
    const local = shadowRun(glutton().netlist, env, rows.map((r) => ({ n: r.n, rec: r.rec, cumInflow: r.cumInflow })), shift);
    let chain: ShadowRow[] | Error | null = null;
    if (COVENANT.gluttonChipId !== null && lensAddr) {
      chain = await loadShadowChip(rpc, lensAddr, kernel, COVENANT.gluttonChipId, count).then(
        (steps) => steps.map((s) => ({ n: s.n, inputs: s.inputs, outputs: s.outputs, clampBits: s.clampBits, allow: s.allow, buyDecided: s.buyDecided, reserveAfter: s.reserveAfter })),
        (e: unknown) => (e instanceof Error ? e : new Error(String(e))),
      );
    }
    // only the curve regime is in the quote asset; graduated records (project tokens) are counted separately
    const curve = (r: { rec: { flags: number } }): boolean => (r.rec.flags & 64) === 0;
    const actual = rows.filter(curve).reduce((a, r) => ({ inflow: a.inflow + r.rec.inflow, allow: a.allow + r.rec.allow, buy: a.buy + r.rec.buyDecided }), { inflow: 0n, allow: 0n, buy: 0n });
    return { rows, local, chain, actual, curveCount: rows.filter(curve).length };
  }, [count, kernel, shift]);

  return (
    <section class="clause">
      <Pin id={pin}>{v2 ? "On the kernel v2 token's real inflow (USD₮0 quote)" : "On the reference token's real tax"}</Pin>
      {!kernel || count === 0 ? (
        <p class="plate idle">
          This runs the Glutton over every settle the {v2 ? 'v2 ' : ''}flagship kernel has recorded, once there is one. {kernel ? 'The kernel has no record yet.' : 'The kernel is not deployed yet.'}
        </p>
      ) : (
        <>
          <p class="muted">
            Every settle the {v2 ? 'v2 ' : ''}flagship kernel recorded, routed again as if the Glutton had been its chip: the recorded {v2 ? 'inflow (tax and revenue)' : 'tax'}, the
            Glutton's own reserve, the same envelope{v2 ? `, the same ${shift}-bit code shift` : ''}, exactly as <span class="mono">Lens{v2 ? 'V2' : ''}.shadowChip</span> computes it.
          </p>
          {q.loading && <p class="loading">Reading {count} records…</p>}
          {q.error && <p class="warn">{q.error.message}</p>}
          {q.data && <ShadowTable d={q.data} capBps={env.allowCumBps} unit={unit} />}
          {COVENANT.gluttonChipId !== null && lensAddr && (
            <Command
              label="The same shadow run on chain (the Glutton taped out next to the chip):"
              line={`cast call ${lensAddr} "shadowChip(address,uint256,uint32,uint32,(bytes32,uint256,uint256,bool))((uint32,bool,bytes12,bytes14,uint16,uint128,uint128,uint128)[],(bytes32,uint256,uint256,bool),uint32)" ${kernel} ${COVENANT.gluttonChipId} 1 ${count} "(0x${'00'.repeat(32)},0,0,false)" --rpc-url ${CAST_RPC}`}
            />
          )}
        </>
      )}
    </section>
  );
}

function ShadowTable({ d, capBps, unit }: { d: { local: ShadowRow[]; chain: ShadowRow[] | Error | null; actual: { inflow: bigint; allow: bigint; buy: bigint }; curveCount: number }; capBps: number; unit: Unit }) {
  const curveRows = d.local.slice(0, d.curveCount); // the records of the curve regime come first
  const tot = curveRows.reduce((a, s) => ({ allow: a.allow + s.allow, buy: a.buy + s.buyDecided, clamps: a.clamps | s.clampBits }), { allow: 0n, buy: 0n, clamps: 0 });
  const allClamps = d.local.reduce((c, s) => c | s.clampBits, 0);
  const end = curveRows.length ? curveRows[curveRows.length - 1].reserveAfter : 0n;
  const dd = unit.decimals;
  const chainOk = Array.isArray(d.chain) ? d.chain.length === d.local.length && d.chain.every((c, i) => c.outputs === d.local[i].outputs && c.allow === d.local[i].allow && c.buyDecided === d.local[i].buyDecided && c.clampBits === d.local[i].clampBits && c.reserveAfter === d.local[i].reserveAfter && c.inputs === d.local[i].inputs) : null;
  const share = (x: bigint): string => (d.actual.inflow > 0n ? `${(Number((x * 10000n) / d.actual.inflow) / 100).toFixed(2)}%` : '–');
  return (
    <>
      <div class="scroll">
      <table class="cmp">
        <thead>
          <tr>
            <th />
            <th class="num">allowance</th>
            <th class="num">share of {unit.symbol === 'OKB' ? 'tax' : 'inflow'}</th>
            <th class="num">bought and locked (decided)</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <th>the real chip</th>
            <td class="num mono">{approx(d.actual.allow, dd)}</td>
            <td class="num">{share(d.actual.allow)}</td>
            <td class="num mono">{approx(d.actual.buy, dd)}</td>
          </tr>
          <tr>
            <th>Glutton, shadow</th>
            <td class="num mono">{approx(tot.allow, dd)}</td>
            <td class="num">{share(tot.allow)}</td>
            <td class="num mono">{approx(tot.buy, dd)}</td>
          </tr>
        </tbody>
      </table>
      </div>
      <p class="small">
        {unit.symbol === 'OKB' ? 'Tax' : 'Inflow'} recorded on the curve: {fmtUnits(d.actual.inflow, dd)} {unit.symbol} over {d.curveCount} settles
        {d.local.length > d.curveCount ? ` (and ${d.local.length - d.curveCount} after graduation, in tokens, where no allowance is paid)` : ''}. The Glutton's reserve at the end of
        the curve: {amount(end, unit)}. Clamps that fired: {bitsOf(CLAMPS, allClamps).map((c) => c.name).join(', ') || 'none'}. The allowance share stays at or under{' '}
        {(capBps / 100).toFixed(2)}% of what arrived whatever the chip asks.
      </p>
      {d.chain === null && <p class="muted small">On chain: no Glutton is taped out on Covenant's processor, so this is the local computation only.</p>}
      {d.chain instanceof Error && <p class="warn small">Lens.shadowChip could not be asked: {d.chain.message}</p>}
      {chainOk !== null && (
        <div class={`plate silicon ${chainOk ? 'ok' : 'bad'}`}>
          <div class="verdict">
            <strong>{chainOk ? 'MATCH' : 'MISMATCH'}</strong>
            <span>Lens{unit.symbol === 'OKB' ? '' : 'V2'}.shadowChip on chain {chainOk ? 'returned the same input words, outputs, clamps and amounts' : 'disagrees with the local computation'} for all {d.local.length} settles.</span>
          </div>
        </div>
      )}
    </>
  );
}
