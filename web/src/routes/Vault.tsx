// #/k/:kernel
// One kernel: what it is bound to, the limits it enforces, the chip's state drawn on its die, the epoch clock, every
// settle (records(n) by eth_call), and what a fixed split would have done with the same tax (Lens.counterfactual).

import { useEffect, useRef, useState } from 'preact/hooks';
import type { DieShot } from '@covenant/dieshot';
import type { Counterfactual } from '@covenant/chain/kernel';
import { toBytes } from '@covenant/chain';
import { Command } from '../components/common.tsx';
import { Die } from '../components/Die.tsx';
import { EnvelopeWords } from '../components/EnvelopeWords.tsx';
import { CheckRow, Pin, SimBanner, Stat } from '../components/kit.tsx';
import { CAST_RPC, CHAIN, COVENANT, REPO, rpc } from '../config.ts';
import { loadCounterfactual, loadNetlist, loadRecords, loadVault, type RecordRow, type VaultData } from '../data/kernel.ts';
import { approx, FG_KECCAK, fgModeName, fgState, FG_STATE_NOTES, pct256, routeView } from '../kernel/chip.ts';
import { bitsOf, CLAMPS, RECORD_FLAGS, stateBytes } from '../kernel/model.ts';
import { chipFromBytes, replayLocal, type Chip } from '../kernel/sim.ts';
import { fmtDuration, fmtInt, fmtTime, fmtUnits } from '../format.ts';
import { useAsync } from '../router.ts';
import { Failure, Loading } from './shared.tsx';

const PAGE = 20;
const same = (a: string | null | undefined, b: string | null | undefined): boolean => !!a && !!b && a.toLowerCase() === b.toLowerCase();

export function Vault({ kernel }: { kernel: string }) {
  const q = useAsync(() => loadVault(rpc, kernel, COVENANT.kernelFactory), [kernel]);
  if (q.loading) return <Loading what={`kernel ${kernel.slice(0, 10)}… from ${CHAIN.name}`} />;
  if (q.error || !q.data) return <Failure error={q.error} retry={q.reload} />;
  return <View key={q.data.kernel} v={q.data} reload={q.reload} />;
}

/** Chain time now, ticking once a second from the block time the page read. */
function useChainNow(v: VaultData): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);
  return (v.time ?? Math.floor(v.readAt / 1000)) + Math.floor((now - v.readAt) / 1000);
}

function View({ v, reload }: { v: VaultData; reload: () => void }) {
  const e = v.envelope;
  const g = v.globals;
  const sym = v.token?.symbol ?? 'token';
  const grad = v.graduated;
  const unit = grad ? sym : 'OKB';
  const dec = v.token?.decimals ?? 18;
  const now = useChainNow(v);
  const chip = useAsync(() => loadNetlist(rpc, g).then((n) => ({ ...n, chip: chipFromBytes(`chip ${g.chipId}`, n.bytes) })), [v.kernel]);
  const isFG = chip.data?.keccak === FG_KECCAK;

  // clock
  const bound = v.token !== null;
  const epochNow = bound ? Math.floor((now - v.bindTime) / e.epochLen) : 0;
  const nextOpen = v.bindTime + (v.lastEpoch + 1) * e.epochLen;
  const fallbackEpoch = v.lastStepEpoch + e.fallbackEpochs;

  const lifetimeCap = (v.cumInflow * BigInt(e.allowCumBps)) / 10000n;
  const supply = v.token?.totalSupply ?? v.tokenSupply;
  const lockShare = supply > 0n ? Number(((v.lockedTokens + v.burnedTokens) * 10000n) / supply) / 100 : 0;
  const progress = v.curve && v.curve.sellable > 0n ? Number((v.curve.sold * 10000n) / v.curve.sellable) / 100 : null;

  return (
    <article>
      <SimBanner />
      <p class="crumbs">
        <a href="#/">Covenant</a> / vault
      </p>
      <h1>
        {bound ? (
          <>
            {v.token!.name ?? 'Token'} <span class="mono muted">{sym}</span> vault
          </>
        ) : (
          'Kernel, not bound yet'
        )}
      </h1>
      <p class="lede">
        {bound ? (
          <>
            This kernel receives {sym}'s trading tax and, once per {fmtDuration(e.epochLen)} epoch, routes it by chip #{String(g.chipId)}
            {isFG ? ' (the Flow Governor)' : ''} inside the fixed envelope below. {v.count === 0 ? 'No settle yet.' : `${fmtInt(v.count)} settle${v.count === 1 ? '' : 's'} so far.`}
          </>
        ) : (
          <>
            This kernel holds chip #{String(g.chipId)} and waits for a token whose IGNIX vault names it as recipient. <span class="mono">bind(token)</span> succeeds
            once, for such a token only.
          </>
        )}
      </p>

      <section>
        <Pin id="01">Facts the chain proves</Pin>
        <ul class="checks">
          <CheckRow ok={v.isKernel === true && v.ourFactory} note={`KernelFactory.isKernel(kernel) on ${g.factory.slice(0, 10)}…${v.ourFactory ? ', the factory in deployments/xlayer.json' : ', NOT the factory this site knows'}`}>
            Created by Covenant's kernel factory
          </CheckRow>
          <CheckRow ok={v.clone.isClone && same(v.clone.implementation, v.factoryImpl) && v.argsMatch} note="eth_getCode: the 45-byte ERC-1167 proxy (it can only forward to one fixed address) followed by abi.encode(globals, envelope). The envelope is code, not storage.">
            Its code is a fixed clone of the factory's Kernel implementation, with the envelope written into the bytes
          </CheckRow>
          <CheckRow
            ok={v.implScan ? v.implScan.selectors.length === 0 && v.implScan.delegatecall === 0 && v.implScan.selfdestruct === 0 && v.implScan.callcode === 0 : null}
            note={
              v.implScan
                ? v.implScan.selectors.length
                  ? `found: ${v.implScan.selectors.join(', ')}`
                  : `scanned ${fmtInt(v.implScan.bytes)} bytes of ${v.implementation?.slice(0, 10)}…: no owner(), transferOwnership, upgradeTo, pause(), approve, transferFrom or safeTransferFrom selector; no DELEGATECALL or SELFDESTRUCT opcode`
                : 'implementation code could not be read'
            }
          >
            No owner, no upgrade, no pause; it cannot approve anyone or transfer the chip
          </CheckRow>
          <CheckRow ok={v.chipOwner ? same(v.chipOwner, v.kernel) : null} note={`Circuits.ownerOf(${g.chipId}) on ${g.circuits.slice(0, 10)}…`}>
            It holds its chip, #{String(g.chipId)}
          </CheckRow>
          {bound ? (
            <CheckRow ok={same(v.vaultRecipient, v.kernel) && same(v.managerVault, v.vault) && same(v.vaultToken, v.token?.address)} note={`IgnixManager.vaultOf(${sym}) = ${v.vault}; vault.RECIPIENT() = ${v.vaultRecipient ?? '?'}; the recipient is immutable in the vault`}>
              {sym}'s tax vault pays this kernel and nobody else
            </CheckRow>
          ) : (
            <CheckRow ok={null} note="no token yet">
              Bound to a token
            </CheckRow>
          )}
          <CheckRow ok={v.evaluator ? true : null} note={v.evaluator?.sealedMode ? "TapeOut's processor code or this chip's record no longer matches what the factory pinned, so settles go straight to Covenant's sealed evaluator, which computes the same function." : 'Beacon implementation, its code hash, the pin counts and the netlist hash all match the pins; the sealed evaluator answers only if TapeOut fails.'}>
            Next settle asks: <b>{v.evaluator ? (v.evaluator.sealedMode ? 'the SealedVM (fallback evaluator)' : "TapeOut's Circuits.step") : '?'}</b>
          </CheckRow>
        </ul>
      </section>

      {bound && (
        <section>
          <Pin id="02">Clock and money</Pin>
          <div class="stats">
            <Stat label="Epoch now" value={fmtInt(epochNow)} sub={`bound ${fmtTime(v.bindTime)}`} />
            <Stat
              label="Next settle"
              value={now >= nextOpen ? 'open now' : `in ${fmtDuration(nextOpen - now)}`}
              sub={now >= nextOpen ? `epoch ${v.lastEpoch + 1} or later can be settled by anyone` : `from ${fmtTime(nextOpen)}`}
            />
            <Stat
              label="Fallback word"
              value={v.lastStepEpoch + e.fallbackEpochs > epochNow ? 'not active' : 'would apply'}
              sub={`if no chip step is persisted by epoch ${fallbackEpoch} (last step: epoch ${v.lastStepEpoch})`}
            />
            <Stat label={`Reserve (${unit})`} value={<span title={fmtUnits(v.reserve, grad ? dec : 18)}>{approx(v.reserve, grad ? dec : 18)}</span>} sub="as of the last settle; leaves only by buy-and-lock" />
            <Stat label="Tax waiting in the vault" value={v.vaultOkb === null ? '?' : <span title={fmtUnits(v.vaultOkb)}>{approx(v.vaultOkb)} OKB</span>} sub="claimed by the next settle" />
            <Stat
              label="Allowance credited"
              value={<span title={fmtUnits(v.allowPaidCum)}>{approx(v.allowPaidCum)} OKB</span>}
              sub={`lifetime cap now ${approx(lifetimeCap)} OKB (${e.allowCumBps / 100}% of ${approx(v.cumInflow)} OKB of tax); unwithdrawn ${approx(v.creditOkb ?? 0n)}`}
            />
            <Stat label={`Locked + burned ${sym}`} value={approx(v.lockedTokens + v.burnedTokens, dec)} sub={`${lockShare}% of supply; bought by the kernel, can never be sold`} />
            <Stat
              label="Graduation"
              value={grad ? 'graduated' : progress === null ? '?' : `${progress}% of the curve sold`}
              sub={grad ? `pair ${v.pair}` : 'at graduation the tax unit becomes the token and the allowance ends'}
            />
          </div>
        </section>
      )}

      <section>
        <Pin id="03">The envelope, fixed at creation</Pin>
        <p class="muted">What any chip in this kernel can and cannot route. Read from <span class="mono">envelope()</span>; the same bytes are in the kernel's code.</p>
        <EnvelopeWords e={e} payeeNote={same(e.allowancePayee, COVENANT.keeperTank) ? 'the KeeperTank, which pays for settles' : undefined} />
      </section>

      <ChipSection v={v} chip={chip.data?.chip ?? null} chipErr={chip.error} source={chip.data?.source} isFG={isFG} />

      {v.count > 0 && <Counterfactuals v={v} />}

      <History v={v} isFG={isFG} />

      <section>
        <Pin id="07">Repeat from a terminal</Pin>
        <Command label="Settles so far, then any record:" line={`cast call ${v.kernel} "count()(uint32)" --rpc-url ${CAST_RPC}`} />
        <Command
          line={`cast call ${v.kernel} "records(uint32)((uint32,uint40,uint16,uint8,bytes12,bytes14,bytes32,uint128,uint128,uint128,uint128,uint128,uint128,uint128))" ${Math.max(1, v.count)} --rpc-url ${CAST_RPC}`}
        />
        <Command label="The envelope:" line={`cast call ${v.kernel} "envelope()((address,uint32,address,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,bool,address))" --rpc-url ${CAST_RPC}`} />
        <Command label="The code (a clone: starts 363d3d373d3d3d363d73 + implementation):" line={`cast code ${v.kernel} --rpc-url ${CAST_RPC}`} />
        <p class="muted small">
          Source: <a href={`${REPO}/blob/main/contracts/core/src/Kernel.sol`}>contracts/core/src/Kernel.sol</a>. Read at block {v.block?.toString() ?? '?'}.{' '}
          <button type="button" class="small" onClick={reload}>
            read again
          </button>
        </p>
      </section>
    </article>
  );
}

function ChipSection({ v, chip, chipErr, source, isFG }: { v: VaultData; chip: Chip | null; chipErr?: Error; source?: string; isFG: boolean }) {
  const g = v.globals;
  const die = useRef<DieShot | null>(null);
  const last = useAsync(() => (v.count > 0 ? loadRecords(rpc, v.kernel, v.count, v.count) : Promise.resolve([] as RecordRow[])), [v.kernel]);
  const [hover, setHover] = useState<string>('');
  const state = stateBytes(v.state, g.nState);
  const play = (): void => {
    const d = die.current;
    const r = last.data?.[0];
    if (!d || !chip) return;
    if (!r) return d.draw(null, toBytes(state));
    const b = replayLocal(chip.netlist, r.stateBefore, r.rec.inputs);
    const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
    void d.animate(null, b.signals, toBytes(stateBytes(r.stateBefore, g.nState)), toBytes(stateBytes(r.rec.stateAfter, g.nState)), still ? 0 : undefined);
  };
  useEffect(play, [chip, last.data]);
  return (
    <section>
      <Pin id="04">The chip and its state</Pin>
      <p>
        Chip #{String(g.chipId)}: {fmtInt(g.gateCount)} gates of which {g.nState} are latches; netlist {fmtInt(g.netlistLen)} bytes, keccak256{' '}
        <span class="mono">{g.netlistHash.slice(0, 18)}…</span>
        {isFG && <span class="tag ok">the Flow Governor as built and proven in chips/out</span>}
      </p>
      {chipErr && <p class="warn">{chipErr.message}</p>}
      {chip && (
        <>
          <Die maxHeight={440} netlist={chip.netlist} onReady={(d) => {
              die.current = d;
              play();
            }} onHover={(c) => setHover(c ? `signal ${c.signal}${c.output >= 0 ? `, output ${c.output}` : ''}` : '')} onPick={() => {}} label={`Die shot of chip ${g.chipId}, ${g.gateCount} gates, showing the kernel's current latch state`} />
          <div class="row">
            <button type="button" class="small" onClick={play}>
              replay the last settle on the die
            </button>
            <span class="muted small">
              {hover || `Laid out from the ${source === 'fab' ? "Fab's snapshot" : "netlist TapeOut stores"}; the register strip on the right is the state the kernel holds now.`}
            </span>
          </div>
        </>
      )}
      <div class="statebox">
        <div class="mono small">
          state() = {state}
          {v.count === 0 && ' (all zero: the chip has not been stepped)'}
        </div>
        {isFG && (
          <table class="fields">
            <tbody>
              {fgState(state).map((f) => (
                <tr key={f.name}>
                  <th class="mono">{f.name}</th>
                  <td class="num mono">{f.name === 'MODE' ? fgModeName(f.value) : f.value}</td>
                  <td class="muted">{FG_STATE_NOTES[f.name]}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </section>
  );
}

function Counterfactuals({ v }: { v: VaultData }) {
  const q = useAsync(() => (COVENANT.lens ? loadCounterfactual(rpc, COVENANT.lens, v.kernel, v.count) : Promise.resolve(null)), [v.kernel, v.count]);
  return (
    <section>
      <Pin id="05">The chip against a fixed split</Pin>
      <p class="muted">
        Lens.counterfactual replays the same recorded tax through two baselines with this kernel's envelope: the fixed split the kernel
        falls back to ({pct256(256 - v.envelope.fbAllow)} buy, {pct256(v.envelope.fbAllow)} allowance, release {pct256(v.envelope.relMax)} of the reserve each settle), and buying
        everything at once.
      </p>
      {!COVENANT.lens && <p class="warn">The Lens is not in deployments/xlayer.json.</p>}
      {q.loading && COVENANT.lens && <p class="loading">Asking the Lens…</p>}
      {q.error && <p class="warn">{q.error.message}</p>}
      {q.data && <CfChart c={q.data.curve} unit="OKB" />}
      {q.data && q.data.graduated.chip.inflow > 0n && <CfChart c={q.data.graduated} unit={v.token?.symbol ?? 'tokens'} />}
      {COVENANT.lens && <Command line={`cast call ${COVENANT.lens} "counterfactual(address,uint32,uint32)" ${v.kernel} 1 ${v.count} --rpc-url ${CAST_RPC}`} />}
    </section>
  );
}

function CfChart({ c, unit }: { c: Counterfactual; unit: string }) {
  const total = c.chip.inflow;
  const rows = [
    { name: 'This chip', buy: c.chip.buy, allow: c.chip.allow, res: c.chip.reserveEnd, note: `of which executed: ${approx(c.chipBuyExecuted)}` },
    { name: 'Fixed split', buy: c.fixedSplit.buy, allow: c.fixedSplit.allow, res: c.fixedSplit.reserveEnd, note: '' },
    { name: 'Buy everything', buy: c.alwaysBuy.buy, allow: 0n, res: 0n, note: '' },
  ];
  const max = rows.reduce((m, r) => (r.buy + r.allow + r.res > m ? r.buy + r.allow + r.res : m), total) || 1n;
  const w = (x: bigint): number => Number((x * 10000n) / max) / 100;
  return (
    <div class="cf">
      <p class="small">
        Tax that arrived: <b>{approx(total)} {unit}</b> over the recorded settles. Bars: decided buy-and-lock, allowance, and what is left in
        the reserve after the last settle.
      </p>
      {rows.map((r) => (
        <div class="cfrow" key={r.name}>
          <div class="cfname">{r.name}</div>
          <div class="bar">
            {r.buy > 0n && <span class="seg buy" style={{ width: `${w(r.buy)}%` }} title={`buy ${fmtUnits(r.buy)}`} />}
            {r.allow > 0n && <span class="seg allow" style={{ width: `${w(r.allow)}%` }} title={`allowance ${fmtUnits(r.allow)}`} />}
            {r.res > 0n && <span class="seg res" style={{ width: `${w(r.res)}%` }} title={`reserve ${fmtUnits(r.res)}`} />}
          </div>
          <div class="cfnums small mono">
            buy {approx(r.buy)} · allowance {approx(r.allow)} · reserve {approx(r.res)} {r.note && <span class="muted">· {r.note}</span>}
          </div>
        </div>
      ))}
      <p class="muted small">
        A decided buy includes releases of earlier reserve, so a row can be longer than the tax that arrived. All three run inside the same
        envelope; none of this is a forecast of future flows.
      </p>
    </div>
  );
}

function History({ v, isFG }: { v: VaultData; isFG: boolean }) {
  const [page, setPage] = useState(0);
  const to = v.count - page * PAGE;
  const from = Math.max(1, to - PAGE + 1);
  const q = useAsync(() => loadRecords(rpc, v.kernel, from, to), [v.kernel, page]);
  const grad = (r: RecordRow): boolean => (r.rec.flags & 64) !== 0;
  return (
    <section>
      <Pin id="06">Every settle</Pin>
      {v.count === 0 ? (
        <p class="plate idle">
          No settle yet.{' '}
          {v.token
            ? `The first is possible once a full epoch has passed since bind, from ${fmtTime(v.bindTime + v.envelope.epochLen)}.`
            : 'Settles start once the kernel is bound to a token.'}{' '}
          The table fills from <span class="mono">records(n)</span>, one per settle.
        </p>
      ) : (
        <>
          <p class="muted">
            Read with <span class="mono">records(n)</span> by eth_call (no logs). Shares are the chip's answer; amounts are what the kernel routed
            after the envelope. Click a number to audit that settle.
          </p>
          {q.loading && <p class="loading">Reading records {from}–{to}…</p>}
          {q.error && <p class="warn">{q.error.message}</p>}
          {q.data && (
            <div class="scroll">
              <table class="history">
                <thead>
                  <tr>
                    <th>#</th>
                    <th>time</th>
                    <th class="num">tax in</th>
                    <th>split (buy / allow / reserve)</th>
                    <th class="num">release</th>
                    <th class="num">allowance</th>
                    <th class="num">buy decided</th>
                    {isFG && <th>mode</th>}
                    <th>clamps</th>
                    <th>flags</th>
                  </tr>
                </thead>
                <tbody>
                  {[...q.data].reverse().map((r) => {
                    const o = routeView(r.rec.outputs);
                    const u = grad(r) ? (v.token?.decimals ?? 18) : 18;
                    return (
                      <tr key={r.n}>
                        <td>
                          <a href={`#/k/${v.kernel}/${r.n}`}>{r.n}</a>
                        </td>
                        <td class="small">
                          {fmtTime(r.rec.time).slice(5, 16)} <span class="muted">e{r.rec.epoch}</span>
                        </td>
                        <td class="num mono">{approx(r.rec.inflow, u)}</td>
                        <td>
                          <div class="minibar" title={`${o.buy}/${o.allow}/${o.res + o.hold} of 256`}>
                            <span class="seg buy" style={{ flex: o.buy }} />
                            <span class="seg allow" style={{ flex: o.allow }} />
                            <span class="seg res" style={{ flex: o.res + o.hold }} />
                          </div>
                        </td>
                        <td class="num mono">{pct256(o.rel)}</td>
                        <td class="num mono">{approx(r.rec.allow)}</td>
                        <td class="num mono">{approx(r.rec.buyDecided, u)}</td>
                        {isFG && <td class="small">{fgModeName(o.mode)}</td>}
                        <td class="small">{r.rec.clampBits === 0 ? <span class="muted">none</span> : bitsOf(CLAMPS, r.rec.clampBits).map((c) => c.name).join(' ')}</td>
                        <td class="small">{r.rec.flags === 0 ? <span class="muted">—</span> : bitsOf(RECORD_FLAGS, r.rec.flags).map((f) => f.name).join(', ')}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
          <div class="row">
            <button type="button" class="small" disabled={to >= v.count} onClick={() => setPage((p) => p - 1)}>
              newer
            </button>
            <span class="muted small">
              records {from}–{to} of {v.count}
            </span>
            <button type="button" class="small" disabled={from <= 1} onClick={() => setPage((p) => p + 1)}>
              older
            </button>
            <a class="small" href={`#/k/${v.kernel}/${v.count}`}>
              audit the latest settle →
            </a>
          </div>
        </>
      )}
    </section>
  );
}
