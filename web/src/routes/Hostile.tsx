// #/hostile
// The Glutton: a chip written to take everything. Its raw demand, what one settle under the envelope lets through,
// and a shadow run over a real kernel's recorded tax: computed here with the TypeScript port of the kernel's clip,
// and, once a Glutton is taped out next to the kernel, by the Lens on chain.

import { useState } from 'preact/hooks';
import { readAll } from '@covenant/chain';
import { kernel as kernelCalls, type Envelope } from '@covenant/chain/kernel';
import { Command } from '../components/common.tsx';
import { EnvelopeWords } from '../components/EnvelopeWords.tsx';
import { Pin, RouteBar, SimBanner } from '../components/kit.tsx';
import { CAST_RPC, COVENANT, rpc } from '../config.ts';
import { loadRecords, loadShadowChip } from '../data/kernel.ts';
import { approx, okb, pct256, REF_ENVELOPE, routeView, witness } from '../kernel/chip.ts';
import { bitsOf, bytesOf, CLAMPS, exp8, INPUT_FIELDS, lg8, pack, route, wordOf, type Routed } from '../kernel/model.ts';
import { beat, flowGovernor, glutton, glutton512, shadowRun, type ShadowRow } from '../kernel/sim.ts';
import { fmtUnits } from '../format.ts';
import { useAsync } from '../router.ts';

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
  const env: Env = k.data?.env ?? REF_ENVELOPE;
  const gl = glutton();
  const g512 = glutton512();
  const zero12 = '0x' + '00'.repeat(12);
  const demand = beat(gl.netlist, '0x00', zero12).outputs;
  const demand512 = beat(g512.netlist, '0x00', zero12).outputs;
  const [tax, setTax] = useState(1);
  const [res, setRes] = useState(1);
  const inflow = TAX_CHOICES[tax][1];
  const reserve0 = RES_CHOICES[res][1];

  // The Flow Governor on the same settle, from a cold start: its input word is what the kernel would assemble.
  const fg = flowGovernor();
  const fgIn = bytesOf(pack(INPUT_FIELDS, { TAX: lg8(inflow), TAXCUM: lg8(inflow), RES: lg8(reserve0), DT: 1 }), 12);
  const fgOut = beat(fg.netlist, '0x' + '00'.repeat(8), fgIn).outputs;
  const fgWarm = beat(fg.netlist, witness.reachA.state, fgIn).outputs;
  const one = (out: string): Routed => route(env, wordOf(out), inflow, reserve0, inflow, 0n, false);
  const clipped = route(env, wordOf(demand), OKB / 100n, OKB / 100n, OKB / 100n, 0n, false);
  const chips = [
    { name: 'Glutton', out: demand, note: 'asks 100% allowance, 100% release, no ceiling' },
    { name: 'Glutton512', out: demand512, note: 'asks 256 + 256 of 256: a malformed share group' },
    { name: 'Flow Governor, cold start', out: fgOut, note: 'the flagship chip, zero state' },
    { name: 'Flow Governor, state A', out: fgWarm, note: 'the flagship chip after four epochs (landing page)' },
  ];

  return (
    <article>
      <SimBanner />
      <p class="crumbs">
        <a href="#/">Covenant</a> / hostile chip
      </p>
      <h1>A chip that asks for everything gets the envelope's cap and nothing more</h1>
      <p class="lede">
        Anyone can write a chip, and a kernel cannot know what a stranger's chip will answer. So the kernel clips every answer to its
        envelope before any money moves. The Glutton (<span class="mono">chips/cells/glutton</span>, 113 NAND + 1 latch) demands the whole
        tax as allowance and the whole reserve every settle, whatever its inputs.
      </p>

      <section>
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
            <p class="small muted">and at most {okb(exp8(env.ceilMax))} of allowance per settle, {env.allowCumBps / 100}% of all tax for life</p>
          </div>
        </div>
        <details>
          <summary>The envelope in full ({k.data ? 'the flagship kernel’s, read from the chain' : 'the reference envelope of LaunchChip.s.sol'})</summary>
          <EnvelopeWords e={env} />
        </details>
      </section>

      <section>
        <Pin id="02">One settle, clipped</Pin>
        <p class="muted">
          Local simulation of the kernel's clip, tested against the golden vectors (<span class="mono">chips/golden/vectors.json</span>, the same
          ones the Solidity kernel passes). The chips are the real netlist bytes, stepped in your browser.
        </p>
        <div class="row">
          <span>Tax this settle:</span>
          {TAX_CHOICES.map(([label], i) => (
            <button type="button" key={label} class={`small${i === tax ? ' on' : ''}`} aria-pressed={i === tax} onClick={() => setTax(i)}>
              {label} OKB
            </button>
          ))}
        </div>
        <div class="row">
          <span>Reserve before:</span>
          {RES_CHOICES.map(([label], i) => (
            <button type="button" key={label} class={`small${i === res ? ' on' : ''}`} aria-pressed={i === res} onClick={() => setRes(i)}>
              {label} OKB
            </button>
          ))}
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
                    <td class="num mono">{approx(r.allow)}</td>
                    <td class="num mono">{approx(r.buyDecided)}</td>
                    <td class="num mono">{approx(r.reserveAfter)}</td>
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
          On a first settle of {TAX_CHOICES[tax][0]} OKB the Glutton gets at most {pct256(env.capT)} of it, capped at {approx(one(demand).allow)} OKB here; the rest is
          bought and locked or waits in the reserve, and the reserve still leaves at {pct256(env.relMax)} per settle. Glutton512 gets nothing:
          a share group that does not sum to 256 is read as 100% reserve. Neither can make a settle revert.
        </p>
      </section>

      <ShadowSection count={k.data?.count ?? 0} env={env} />
    </article>
  );
}

function ShadowSection({ count, env }: { count: number; env: Env }) {
  const q = useAsync(async () => {
    if (!COVENANT.kernel || count === 0) return null;
    const rows = await loadRecords(rpc, COVENANT.kernel, 1, count);
    const local = shadowRun(glutton().netlist, env, rows.map((r) => ({ n: r.n, rec: r.rec, cumInflow: r.cumInflow })));
    let chain: ShadowRow[] | Error | null = null;
    if (COVENANT.gluttonChipId !== null && COVENANT.lens) {
      chain = await loadShadowChip(rpc, COVENANT.lens, COVENANT.kernel, COVENANT.gluttonChipId, count).then(
        (steps) => steps.map((s) => ({ n: s.n, inputs: s.inputs, outputs: s.outputs, clampBits: s.clampBits, allow: s.allow, buyDecided: s.buyDecided, reserveAfter: s.reserveAfter })),
        (e: unknown) => (e instanceof Error ? e : new Error(String(e))),
      );
    }
    const actual = rows.reduce((a, r) => ({ inflow: a.inflow + r.rec.inflow, allow: a.allow + r.rec.allow, buy: a.buy + r.rec.buyDecided }), { inflow: 0n, allow: 0n, buy: 0n });
    return { rows, local, chain, actual };
  }, [count]);

  return (
    <section>
      <Pin id="03">On the reference token's real tax</Pin>
      {!COVENANT.kernel || count === 0 ? (
        <p class="plate idle">
          This runs the Glutton over every settle the flagship kernel has recorded, once there is one. {COVENANT.kernel ? 'The kernel has no record yet.' : 'The kernel is not deployed yet.'}
        </p>
      ) : (
        <>
          <p class="muted">
            Every settle the flagship kernel recorded, routed again as if the Glutton had been its chip: the recorded tax, the Glutton's own
            reserve, the same envelope, exactly as <span class="mono">Lens.shadowChip</span> computes it.
          </p>
          {q.loading && <p class="loading">Reading {count} records…</p>}
          {q.error && <p class="warn">{q.error.message}</p>}
          {q.data && <ShadowTable d={q.data} capBps={env.allowCumBps} />}
          {COVENANT.gluttonChipId !== null && COVENANT.lens && (
            <Command
              label="The same shadow run on chain (the Glutton taped out next to the chip):"
              line={`cast call ${COVENANT.lens} "shadowChip(address,uint256,uint32,uint32,(bytes32,uint256,uint256,bool))((uint32,bool,bytes12,bytes14,uint16,uint128,uint128,uint128)[],(bytes32,uint256,uint256,bool),uint32)" ${COVENANT.kernel} ${COVENANT.gluttonChipId} 1 ${count} "(0x${'00'.repeat(32)},0,0,false)" --rpc-url ${CAST_RPC}`}
            />
          )}
        </>
      )}
    </section>
  );
}

function ShadowTable({ d, capBps }: { d: { local: ShadowRow[]; chain: ShadowRow[] | Error | null; actual: { inflow: bigint; allow: bigint; buy: bigint } }; capBps: number }) {
  const tot = d.local.reduce((a, s) => ({ allow: a.allow + s.allow, buy: a.buy + s.buyDecided, clamps: a.clamps | s.clampBits }), { allow: 0n, buy: 0n, clamps: 0 });
  const end = d.local.length ? d.local[d.local.length - 1].reserveAfter : 0n;
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
            <th class="num">share of tax</th>
            <th class="num">bought and locked (decided)</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <th>the real chip</th>
            <td class="num mono">{approx(d.actual.allow)}</td>
            <td class="num">{share(d.actual.allow)}</td>
            <td class="num mono">{approx(d.actual.buy)}</td>
          </tr>
          <tr>
            <th>Glutton, shadow</th>
            <td class="num mono">{approx(tot.allow)}</td>
            <td class="num">{share(tot.allow)}</td>
            <td class="num mono">{approx(tot.buy)}</td>
          </tr>
        </tbody>
      </table>
      </div>
      <p class="small">
        Tax recorded: {fmtUnits(d.actual.inflow)} OKB over {d.local.length} settles. The Glutton's reserve at the end: {approx(end)} OKB. Clamps that
        fired: {bitsOf(CLAMPS, tot.clamps).map((c) => c.name).join(', ') || 'none'}. The allowance share stays at or under {(capBps / 100).toFixed(2)}% of the tax
        that arrived whatever the chip asks.
      </p>
      {d.chain === null && <p class="muted small">On chain: no Glutton is taped out on Covenant's processor, so this is the local computation only.</p>}
      {d.chain instanceof Error && <p class="warn small">Lens.shadowChip could not be asked: {d.chain.message}</p>}
      {chainOk !== null && (
        <div class={`plate ${chainOk ? 'ok' : 'bad'}`}>
          <div class="verdict">
            <strong>{chainOk ? 'MATCH' : 'MISMATCH'}</strong>
            <span>Lens.shadowChip on chain {chainOk ? 'returned the same input words, outputs, clamps and amounts' : 'disagrees with the local computation'} for all {d.local.length} settles.</span>
          </div>
        </div>
      )}
    </>
  );
}
