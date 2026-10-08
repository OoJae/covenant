// #/judge
// Eight checks. Each runs in the page with free read calls and prints the terminal command that asks the same
// question, so nothing here has to be taken on trust from this site. The eighth is kernel v2 (USD₮0 quote): it says
// so plainly until deployments/xlayer.json records a v2 deployment.

import { useEffect, useState } from 'preact/hooks';
import type { ComponentChildren } from 'preact';
import { processor, read, readAll } from '@covenant/chain';
import { keccak256Hex } from '@covenant/chain/keccak';
import { erc20, kernel, kernelFactoryV2, lens, ownerOf, teamRegistry } from '@covenant/chain/kernel';
import { Command } from '../components/common.tsx';
import { Icon } from '../components/Icon.tsx';
import { Mark, SimBanner } from '../components/kit.tsx';
import { ADDR, CAST_RPC, CHAIN_LABEL, COVENANT, REPO, rpc } from '../config.ts';
import { amount, FG_KECCAK, REF_ENVELOPE, routeDiff, witness } from '../kernel/chip.ts';
import { bitsOf, CLAMPS, exp8s, inputFields, lg8, lg8s, route, wordOf } from '../kernel/model.ts';
import { loadProcessor } from '../data/processor.ts';
import { fmtInt, fmtUnits } from '../format.ts';
import { PageHead } from './shared.tsx';

interface Result {
  ok: boolean | null;
  lines: ComponentChildren[];
}

interface Check {
  title: string;
  claim: ComponentChildren;
  run: () => Promise<Result>;
  cast: { label?: string; line: string }[];
  more?: ComponentChildren;
  /** Computed in this browser only, with no chain read: its pass is counted apart from the chain checks. */
  local?: boolean;
}

const P = COVENANT.processor;
const K = COVENANT.kernel;
const K2 = COVENANT.kernelV2;
const F2 = COVENANT.kernelFactoryV2;
const R = CAST_RPC;
const ZERO = '0x0000000000000000000000000000000000000000';
const notYet = (what: string): Result => ({ ok: null, lines: [`${what} is not deployed yet; this check runs as soon as deployments/xlayer.json names it.`] });
/** Lens.Replay's seventh field (contracts/core/src/Lens.sol): the evaluator the replay used, not a check. */
const SEALED_USED = 'The first six values are the checks. The 7th, sealedUsed, names the evaluator: false means TapeOut ran the chip, not the SealedVM.';

const CHECKS: Check[] = [
  {
    title: 'The processor exists, with its supply and price disclosed',
    claim: "Covenant's TapeOut processor is registered with TapeOut's factory, and its transistor contract states a fixed supply cap and mint price.",
    run: async () => {
      if (!P) return notYet('The processor');
      const p = await loadProcessor(rpc, ADDR.factory, P);
      const storyHash = p.story === null ? null : keccak256Hex(new TextEncoder().encode(p.story));
      const storyOk = COVENANT.storyKeccak256 ? storyHash === COVENANT.storyKeccak256 : null;
      return {
        ok: p.registered === true && p.supplyCap !== null && p.mintPrice !== null,
        lines: [
          `isCPU: ${p.registered}; ${p.name} (${p.symbol}), ${p.circuits} circuit${p.circuits === 1 ? '' : 's'} taped out`,
          `supply cap ${p.supplyCap === null ? '?' : fmtInt(p.supplyCap)} transistors, ${p.minted === null ? '?' : fmtInt(p.minted)} minted, price ${p.mintPrice === null ? '?' : fmtUnits(p.mintPrice)} OKB each`,
          `story keccak256 ${storyHash?.slice(0, 18)}… ${storyOk === null ? '' : storyOk ? '= the one recorded at deployment' : '≠ the one recorded at deployment'}`,
        ],
      };
    },
    cast: [
      { line: `cast call ${ADDR.factory} "isCPU(address)(bool)" ${P ?? '<processor>'} --rpc-url ${R}` },
      { line: `cast call ${COVENANT.transistors ?? '<transistors>'} "supplyCap()(uint256)" --rpc-url ${R}` },
      { line: `cast call ${COVENANT.transistors ?? '<transistors>'} "mintPrice()(uint256)" --rpc-url ${R}` },
    ],
  },
  {
    title: 'The chip is not decorative',
    claim: 'The same input word, stepped from two states the chip reaches by itself, gives two different routes. The state is doing work.',
    run: async () => {
      const sim = await import('../kernel/sim.ts');
      const nl = sim.flowGovernor().netlist;
      const a = sim.beat(nl, witness.reachA.state, witness.x).outputs;
      const b = sim.beat(nl, witness.reachB.state, witness.x).outputs;
      const reached = sim.reach(nl, witness.reachA.inputs) === witness.reachA.state && sim.reach(nl, witness.reachB.inputs) === witness.reachB.state;
      const lines: ComponentChildren[] = [`browser: route fields that differ: ${routeDiff(a, b).join(', ') || 'none'}; both states reached from zero: ${reached}`];
      let ok = routeDiff(a, b).length > 0 && reached;
      if (P && COVENANT.chipId !== null) {
        const p = processor(P);
        const [ca, cb] = await Promise.all([read(rpc, p.step(COVENANT.chipId, witness.reachA.state, witness.x)), read(rpc, p.step(COVENANT.chipId, witness.reachB.state, witness.x))]);
        const match = ca.outputs === a && cb.outputs === b;
        ok = ok && match;
        lines.push(`${CHAIN_LABEL}, Circuits.step on chip #${COVENANT.chipId}: ${match ? 'MATCH on both' : 'MISMATCH'}`);
      } else lines.push('The Flow Governor is not taped out yet, so this ran on the local netlist only.');
      return { ok, lines };
    },
    cast: [
      { label: 'State A:', line: `cast call ${P ?? '<processor>'} "step(uint256,bytes,bytes)(bytes,bytes)" ${COVENANT.chipId ?? '<chip id>'} ${witness.reachA.state} ${witness.x} --rpc-url ${R}` },
      { label: 'State B:', line: `cast call ${P ?? '<processor>'} "step(uint256,bytes,bytes)(bytes,bytes)" ${COVENANT.chipId ?? '<chip id>'} ${witness.reachB.state} ${witness.x} --rpc-url ${R}` },
    ],
    more: (
      <>
        The landing page shows both routes side by side. The words that reach each state are in <span class="mono">chips/out/fg.witness.json</span>.
      </>
    ),
  },
  {
    title: 'The kernel holds its chip and has no admin',
    claim: 'The kernel owns its chip NFT, was made by the KernelFactory, is a fixed clone with its envelope in its bytecode, and its implementation has no owner, upgrade, pause, approve or transfer-out path.',
    run: async () => {
      if (!K) return notYet('The flagship kernel');
      const { loadVault } = await import('../data/kernel.ts');
      const v = await loadVault(rpc, K, COVENANT);
      const holds = !!v.chipOwner && v.chipOwner.toLowerCase() === K.toLowerCase();
      const clone = v.clone.isClone && !!v.factoryImpl && v.clone.implementation === v.factoryImpl.toLowerCase() && v.argsMatch;
      const s = v.implScan;
      const clean = !!s && s.selectors.length === 0 && s.delegatecall === 0 && s.selfdestruct === 0 && s.callcode === 0;
      return {
        ok: holds && v.isKernel === true && v.ourFactory && clone && clean,
        lines: [
          `ownerOf(${v.globals.chipId}) = ${v.chipOwner}: ${holds ? 'the kernel' : 'NOT the kernel'}`,
          `KernelFactory.isKernel: ${v.isKernel}; factory is the deployed one: ${v.ourFactory}`,
          `code: ERC-1167 clone of ${v.implementation} with immutable envelope: ${clone}`,
          s ? `implementation, ${fmtInt(s.bytes)} bytes: forbidden selectors ${s.selectors.join(', ') || 'none'}; DELEGATECALL ${s.delegatecall}, SELFDESTRUCT ${s.selfdestruct}` : 'implementation code not read',
        ],
      };
    },
    cast: [
      { line: `cast call ${P ?? '<processor>'} "ownerOf(uint256)(address)" ${COVENANT.chipId ?? '<chip id>'} --rpc-url ${R}` },
      { line: `cast call ${COVENANT.kernelFactory ?? '<kernel factory>'} "isKernel(address)(bool)" ${K ?? '<kernel>'} --rpc-url ${R}` },
      { label: 'Starts with 363d3d373d3d3d363d73, then the implementation, then 5af43d82803e903d91602b57fd5bf3 and the envelope:', line: `cast code ${K ?? '<kernel>'} --rpc-url ${R}` },
    ],
    more: (
      <>
        Source: <a href={`${REPO}/blob/main/contracts/core/src/Kernel.sol`}>Kernel.sol</a>, <a href={`${REPO}/blob/main/contracts/core/src/KernelFactory.sol`}>KernelFactory.sol</a>. The
        vault page repeats these checks for any kernel.
      </>
    ),
  },
  {
    title: 'Any epoch can be replayed',
    claim: 'Every settle is a record readable by eth_call. The Lens recomputes it on TapeOut and on the sealed evaluator and checks the routed amounts against the envelope.',
    run: async () => {
      if (!K || !COVENANT.lens) return notYet('The flagship kernel');
      const [count] = await readAll(rpc, [kernel(K).count()] as const);
      if (count instanceof Error) throw count;
      if (count === 0) return { ok: null, lines: ['The kernel has no settle yet. Run this again after the first epoch.'] };
      const L = lens(COVENANT.lens);
      const ns = [...new Set([1, count])];
      const reps = await Promise.all(ns.flatMap((n) => [read(rpc, L.replayOn(K, n, false)), read(rpc, L.replayOn(K, n, true))]));
      return {
        ok: reps.every((r) => r.ok),
        lines: ns.map((n, i) => (
          <>
            settle <a href={`#/k/${K}/${n}`}>#{n}</a>: TapeOut {reps[2 * i].ok ? 'ok' : 'FAILED'}, SealedVM {reps[2 * i + 1].ok ? 'ok' : 'FAILED'} (outputs, state, amounts, input word)
          </>
        )),
      };
    },
    cast: [{ label: SEALED_USED, line: `cast call ${COVENANT.lens ?? '<lens>'} "replay(address,uint32)((bool,bool,bool,bool,bool,bool,bool,bytes14,bytes32))" ${K ?? '<kernel>'} 1 --rpc-url ${R}` }],
    more: <>The audit page of each settle adds this browser's own recomputation from the netlist bytes: a three-way MATCH.</>,
  },
  {
    local: true,
    title: 'A hostile chip is clipped',
    claim: "A chip that asks for 100% of the tax as allowance and the whole reserve every settle gets the envelope's cap and nothing more.",
    run: async () => {
      const sim = await import('../kernel/sim.ts');
      const out = sim.beat(sim.glutton().netlist, '0x00', '0x' + '00'.repeat(12)).outputs;
      const r = route(REF_ENVELOPE, wordOf(out), 10n ** 16n, 10n ** 16n, 10n ** 16n, 0n);
      return {
        ok: r.allow * 256n === 10n ** 16n * 48n && r.rel === 128,
        lines: [
          `Glutton asks: allowance 256/256, release 256/256. Kernel routes, on 0.01 OKB of tax: allowance ${fmtUnits(r.allow)} OKB (48/256), release 128/256; clamps ${bitsOf(CLAMPS, r.clamp).map((c) => c.name).join(' + ')}`,
          <>
            <a href="#/hostile">The hostile chip page</a> runs it over every recorded settle{COVENANT.gluttonChipId !== null ? ' and compares with Lens.shadowChip on chain' : ''}.
          </>,
        ],
      };
    },
    cast: [{ label: 'The same clip, from the Python reference model:', line: 'chips/.venv-fg/bin/python chips/cells/glutton/demo.py -v' }],
  },
  {
    title: 'The team wallets never traded',
    claim: 'Every team wallet is listed in docs/WALLETS.md and joins the on-chain TeamRegistry once invited and declared, and none of them ever buys, sells or swaps an IGNIX token, or sends funds into a kernel.',
    run: async () => {
      if (!COVENANT.teamRegistry) return notYet('The TeamRegistry');
      const reg = teamRegistry(COVENANT.teamRegistry);
      const [count] = await readAll(rpc, [reg.count()] as const);
      if (count instanceof Error) throw count;
      const entries = await readAll(rpc, Array.from({ length: Math.min(count, 50) }, (_, i) => reg.at(i)));
      const wallets = entries.filter((e) => !(e instanceof Error)) as { wallet: string; role: string }[];
      const lines: ComponentChildren[] = wallets.map((w) => `registry: ${w.wallet} (${w.role || 'no role declared'})`);
      // docs/WALLETS.md also names the keeper and the Architect wallet; say so when the registry does not list them yet
      for (const [addr, role] of [
        [COVENANT.keeper, 'keeper'],
        [COVENANT.architectWallet, 'Architect agent wallet'],
      ] as const) {
        if (addr && !wallets.some((w) => w.wallet.toLowerCase() === addr.toLowerCase())) {
          wallets.push({ wallet: addr, role });
          lines.push(`docs/WALLETS.md: ${addr} (${role}), not declared in the registry yet`);
        }
      }
      let ok: boolean | null = null;
      for (const [k, what] of [
        [K, 'the reference token'],
        [K2, 'the kernel v2 token (USD₮0 quote)'],
      ] as const) {
        if (!k) continue;
        const [tok] = await readAll(rpc, [kernel(k).token()] as const);
        if (!(tok instanceof Error) && tok.toLowerCase() !== ZERO) {
          const bals = await readAll(rpc, wallets.map((w) => erc20(tok).balanceOf(w.wallet)));
          const none = bals.every((b) => b === 0n);
          ok = (ok ?? true) && none;
          lines.push(`none of them holds ${what}: ${none}`);
        }
      }
      if (K2) lines.push('Self-payment is forbidden too: no team wallet may pay revenue into a kernel that buys the team’s token.');
      lines.push('The full check walks every transaction these wallets ever sent; it needs an archive node, so it runs from a terminal (below).');
      return { ok, lines };
    },
    cast: [
      { line: `cast call ${COVENANT.teamRegistry ?? '<registry>'} "count()(uint256)" --rpc-url ${R}` },
      { line: `cast call ${COVENANT.teamRegistry ?? '<registry>'} "at(uint256)(address,string,uint256)" 0 --rpc-url ${R}` },
      { label: 'Every transaction of every listed wallet, classified (expected: VERDICT: CLEAN):', line: 'node tools/audit-team/audit-team.ts --deployment deployments/xlayer.json --quiet' },
    ],
    more: (
      <>
        The wallets and the rule: <a href={`${REPO}/blob/main/docs/WALLETS.md`}>docs/WALLETS.md</a>; the tool: <a href={`${REPO}/tree/main/tools/audit-team`}>tools/audit-team</a>.
      </>
    ),
  },
  {
    title: 'The proofs are about these bytes',
    claim: (
      <>
        The Flow Governor's Verilog equals its netlist bytes, and its properties hold for every 64-bit state and every 96-bit input: shares sum
        to 256, the allowance never exceeds the envelope, the release stays within it, ratchets never loosen, unused inputs are ignored, so no
        clamp can fire. Ten deliberately broken chips are each caught.
      </>
    ),
    run: async () => {
      const sim = await import('../kernel/sim.ts');
      const local = sim.flowGovernor().keccak;
      const lines: ComponentChildren[] = [`keccak256 of the bytes this site simulates: ${local.slice(0, 18)}… ${local === FG_KECCAK ? '= the bytes the proofs were run on' : '≠ the proofs'}`];
      let ok = local === FG_KECCAK;
      if (P && COVENANT.chipId !== null) {
        const nl = await read(rpc, processor(P).netlist(COVENANT.chipId));
        const h = keccak256Hex(new Uint8Array(nl.slice(2).match(/../g)!.map((b) => parseInt(b, 16))));
        ok = ok && h === FG_KECCAK;
        lines.push(`keccak256 of chip #${COVENANT.chipId}'s netlist on ${CHAIN_LABEL}: ${h.slice(0, 18)}… ${h === FG_KECCAK ? '= the same bytes' : '≠ the proven bytes'}`);
      } else lines.push('The chip is not taped out yet; once it is, this compares its on-chain netlist too.');
      lines.push('chips/out/fg.proofs.json: 98 results over 65 properties, all proved (Yosys SAT and z3; one lifetime-cap property by argument plus 200,000 random settles).');
      return { ok, lines };
    },
    cast: [
      { line: `cast call ${P ?? '<processor>'} "netlist(uint256)(bytes)" ${COVENANT.chipId ?? '<chip id>'} --rpc-url ${R} | cast keccak` },
      { label: 'Re-run the proofs and the ten mutants (Python, Yosys, z3):', line: 'make -C chips/rtl prove && make -C chips/rtl mutants' },
    ],
    more: (
      <>
        Results: <a href={`${REPO}/blob/main/chips/out/fg.proofs.json`}>chips/out/fg.proofs.json</a>; what the chip does:{' '}
        <a href={`${REPO}/blob/main/chips/model/FLOW_GOVERNOR.md`}>FLOW_GOVERNOR.md</a>.
      </>
    ),
  },
  {
    title: 'Kernel v2 reads USD₮0 through a fixed shift',
    claim: (
      <>
        A kernel v2 routes a token quoted in USD₮0 (6 decimals) with the same, unchanged Flow Governor: on the curve it shows every amount to the chip
        as lg8(amount) + 264, a 33-bit shift fixed in its code. Its factory pins USD₮0 and the shift; its records carry the shifted codes; both evaluators
        replay them; it has no owner and leaves no USD₮0 allowance behind. Tether can block it and destroy what it holds.
      </>
    ),
    run: async () => {
      if (!F2) return { ok: null, lines: ['Kernel v2 (USD₮0 quote) is built and tested on an X Layer fork but not deployed: deployments/xlayer.json has no coreV2 entry yet, so there is nothing on chain to check.'] };
      const f = kernelFactoryV2(F2);
      const [quote, shift, codeShift] = await readAll(rpc, [f.quote(), f.quoteShift(), f.codeShift()] as const);
      if (quote instanceof Error || shift instanceof Error || codeShift instanceof Error) throw quote instanceof Error ? quote : shift instanceof Error ? shift : (codeShift as Error);
      const [dec, sym, owner] = await readAll(rpc, [erc20(quote).decimals(), erc20(quote).symbol(), ownerOf(quote)] as const);
      let ok = dec === 6 && codeShift === 8 * shift;
      const unit = { symbol: typeof sym === 'string' ? sym : 'USD₮0', decimals: 6 };
      const lines: ComponentChildren[] = [
        `KernelFactoryV2: quote ${quote} (${unit.symbol}, decimals ${String(dec)}), shift ${shift} bits = ${codeShift} codes; 1 ${unit.symbol} reads as code ${lg8s(10n ** 6n, shift)} = ${lg8(10n ** 6n)} + ${8 * shift}`,
        `the reference envelope's ceilMax ${REF_ENVELOPE.ceilMax} caps the allowance at ${amount(exp8s(REF_ENVELOPE.ceilMax, shift), unit)} per settle`,
      ];
      if (!K2) {
        lines.push('No v2 kernel is recorded in deployments/xlayer.json yet.');
        return { ok: ok ? null : false, lines };
      }
      const { loadVault, loadRecords } = await import('../data/kernel.ts');
      const v = await loadVault(rpc, K2, COVENANT);
      const holds = !!v.chipOwner && v.chipOwner.toLowerCase() === K2.toLowerCase();
      const s = v.implScan;
      const clean = !!s && s.selectors.every((x) => x === 'approve(address,uint256)') && s.delegatecall === 0 && s.selfdestruct === 0 && s.callcode === 0;
      const noAllowance = v.allowanceToManager === 0n && v.allowanceToRouter === 0n;
      ok = ok && v.kind.version === 2 && v.kind.by === 'factory v2' && v.ourFactory && holds && v.clone.isClone && v.argsMatch && clean && noAllowance && v.kind.shift === shift;
      lines.push(`kernel ${K2}: KernelFactoryV2.isKernel ${v.isKernel}; holds chip #${v.globals.chipId}: ${holds}; clean clone: ${v.clone.isClone && v.argsMatch}; owner/upgrade/pause selectors: ${s ? s.selectors.filter((x) => x !== 'approve(address,uint256)').join(', ') || 'none' : '?'}; allowance left to the Manager / router: ${v.allowanceToManager} / ${v.allowanceToRouter}`);
      lines.push(`${unit.symbol}.isBlocked(kernel) = ${v.quoteBlocked}; ${unit.symbol}'s owner ${typeof owner === 'string' ? owner : '?'} can block the kernel and destroy its ${unit.symbol}`);
      if (v.count > 0) {
        const rows = await loadRecords(rpc, K2, 1, v.count, 2);
        const curve = rows.filter((r) => (r.rec.flags & 64) === 0);
        const codesOk = curve.every((r) => {
          const x = inputFields(r.rec.inputs);
          return x.TAX === lg8s(r.rec.inflow, shift) && x.TAXCUM === lg8s(r.cumInflow, shift) && x.RES === lg8s(r.rec.reserveBefore, shift);
        });
        ok = ok && codesOk;
        lines.push(`${curve.length} curve record${curve.length === 1 ? '' : 's'}: every TAX, TAXCUM and RES code is lg8(amount << ${shift}): ${codesOk}`);
        if (COVENANT.lensV2) {
          const L = lens(COVENANT.lensV2);
          const ns = [...new Set([1, v.count])];
          const reps = await Promise.all(ns.flatMap((n) => [read(rpc, L.replayOn(K2, n, false)), read(rpc, L.replayOn(K2, n, true))]));
          ok = ok && reps.every((r) => r.ok);
          ns.forEach((n, i) =>
            lines.push(
              <>
                settle <a href={`#/k/${K2}/${n}`}>#{n}</a>: LensV2 on TapeOut {reps[2 * i].ok ? 'ok' : 'FAILED'}, on the SealedVM {reps[2 * i + 1].ok ? 'ok' : 'FAILED'}
              </>,
            ),
          );
        }
      } else lines.push('The v2 kernel has no settle yet.');
      return { ok, lines };
    },
    cast: [
      { line: `cast call ${F2 ?? '<kernel factory v2>'} "quoteShift()(uint256)" --rpc-url ${R}` },
      { line: `cast call ${F2 ?? '<kernel factory v2>'} "isKernel(address)(bool)" ${K2 ?? '<kernel v2>'} --rpc-url ${R}` },
      { label: SEALED_USED, line: `cast call ${COVENANT.lensV2 ?? '<lens v2>'} "replay(address,uint32)((bool,bool,bool,bool,bool,bool,bool,bytes14,bytes32))" ${K2 ?? '<kernel v2>'} 1 --rpc-url ${R}` },
      { label: 'The shift and the routing, from the Python reference model (identities over 2,740,850 cases; kernel v1 reproduced with shift 0):', line: 'python3 chips/golden/kernel_model_v2.py' },
    ],
    more: (
      <>
        What differs from kernel v1: <a href={`${REPO}/blob/main/chips/INTERFACE-V2.md`}>chips/INTERFACE-V2.md</a>; the derivation of the shift and the tests:{' '}
        <a href={`${REPO}/blob/main/contracts/core-v2/NOTES.md`}>contracts/core-v2/NOTES.md</a>. Revenue paid to a v2 kernel is routed as tax on the curve; it is routed only
        if it is paid to the kernel, and the x402 payTo is a seller setting the operator can change.
      </>
    ),
  },
];

type Outcome = 'pass' | 'local' | 'fail' | 'none' | 'error';
const outcomeOf = (r: Result | Error, local = false): Outcome =>
  r instanceof Error ? 'error' : r.ok === true ? (local ? 'local' : 'pass') : r.ok === false ? 'fail' : 'none';

/**
 * One check as a clause: its number hangs in the gutter, the claim reads as a term of the deed, and it resolves
 * (its mark stamps in) when its reads come back. `go` is set while a run of all eight is at this check.
 */
function CheckCard({ c, i, go, onSettled }: { c: Check; i: number; go: boolean; onSettled: (i: number, o: Outcome) => void }) {
  const [state, setState] = useState<'idle' | 'running' | Result | Error>('idle');
  const [runs, setRuns] = useState(0);
  const run = (): void => {
    setState('running');
    const done = (r: Result | Error): void => {
      setState(r);
      setRuns((k) => k + 1);
      onSettled(i, outcomeOf(r, c.local));
    };
    c.run().then(done, (e: unknown) => done(e instanceof Error ? e : new Error(String(e))));
  };
  useEffect(() => {
    if (go) run();
  }, [go]);
  const res = typeof state === 'object' && !(state instanceof Error) ? state : null;
  const data = state === 'idle' || state === 'running' ? state : outcomeOf(state);
  return (
    <li class="clause judgecheck" data-state={data}>
      <span class="clause__no" aria-hidden="true">
        §{String(i + 1).padStart(2, '0')}
      </span>
      <h2 class="clause__title">{c.title}</h2>
      <p>{c.claim}</p>
      <div class="row judgecheck__run">
        <button type="button" class="small press" onClick={run} disabled={state === 'running'}>
          {state === 'running' ? 'Running…' : res || state instanceof Error ? 'Run again' : 'Run this check'}
        </button>
        {res && (
          // a new element per run, so the mark stamps in each time the check resolves
          <span key={runs} class="judgecheck__result" role="status">
            <Mark ok={res.ok} /> {res.ok === true ? (c.local ? 'passed in this browser, no chain read' : 'passed') : res.ok === false ? 'FAILED' : 'nothing to check yet'}
          </span>
        )}
        {state instanceof Error && <span class="warn">Could not read the chain: {state.message}</span>}
      </div>
      {res && (
        <ul class="jlines small">
          {res.lines.map((l, k) => (
            <li key={k}>{l}</li>
          ))}
        </ul>
      )}
      <details>
        <summary>From a terminal</summary>
        {c.cast.map((x, k) => (
          <Command key={k} label={x.label} line={x.line} />
        ))}
      </details>
      {c.more && <p class="muted small">{c.more}</p>}
    </li>
  );
}

export function Judge() {
  // A run of all eight goes in order, one check after the other, so the clauses resolve top to bottom.
  const [turn, setTurn] = useState<number | null>(null);
  const [outcomes, setOutcomes] = useState<(Outcome | undefined)[]>([]);
  const settled = (i: number, o: Outcome): void => {
    setOutcomes((list) => {
      const next = list.slice();
      next[i] = o;
      return next;
    });
    setTurn((t) => (t === i ? (i + 1 < CHECKS.length ? i + 1 : null) : t));
  };
  const count = (o: Outcome): number => outcomes.filter((x) => x === o).length;
  const ran = outcomes.filter(Boolean).length;
  return (
    <article class="page page--judge">
      <SimBanner />
      <PageHead
        crumbs={
          <>
            <a href="#/">Covenant</a> / judge guide
          </>
        }
        title={
          <>
            Eight checks, <em>five minutes</em>, no wallet
          </>
        }
        lede={
          <>
            Each check asks {CHAIN_LABEL} with free read calls from this page and shows the same question as a <span class="mono">cast</span> command for
            a node of your choice. A check whose contract is not deployed yet says so instead of passing.
          </>
        }
      >
        <p class="muted small">
          The cast lines need Foundry's cast (getfoundry.sh) and nothing else. Lines that start with node, python3, make or chips/ run at the root of a
          clone of <a href={REPO}>the repository</a>: node lines with Node 26, make and chips/ lines with the chip venv (make -C chips/rtl venv,
          Python 3.12). The team audit reads every block since 2026-10-06, so it takes longer each day (25 minutes on 2026-10-08).
        </p>
        <div class="judge-run">
          <button
            type="button"
            class="btn btn--primary press"
            disabled={turn !== null}
            onClick={() => {
              setOutcomes([]);
              setTurn(0);
            }}
          >
            {turn !== null ? `Running check ${turn + 1} of ${CHECKS.length}…` : ran > 0 ? 'Run the eight checks again' : 'Run the eight checks'}
            <span class="btn__icon">
              <Icon name="arrow-down" />
            </span>
          </button>
          {ran > 0 && (
            <p class="micro" role="status">
              {ran} of {CHECKS.length} run · {count('pass')} passed on chain
              {count('local') > 0 ? ` · ${count('local')} passed in this browser` : ''} · {count('fail')} failed · {count('none')} with nothing to check yet
              {count('error') > 0 ? ` · ${count('error')} could not read the chain` : ''}
            </p>
          )}
        </div>
      </PageHead>
      <ol class="judge">
        {CHECKS.map((c, i) => (
          <CheckCard key={c.title} c={c} i={i} go={turn === i} onSettled={settled} />
        ))}
      </ol>
      <p class="muted judge-foot">
        What these checks rest on, and what they cannot show, is on the <a href="#/trust">trust page</a>. Unaudited.
      </p>
    </article>
  );
}
