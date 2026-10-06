// #/judge
// Seven checks. Each runs in the page with free read calls and prints the terminal command that asks the same
// question, so nothing here has to be taken on trust from this site.

import { useState } from 'preact/hooks';
import type { ComponentChildren } from 'preact';
import { processor, read, readAll } from '@covenant/chain';
import { keccak256Hex } from '@covenant/chain/keccak';
import { erc20, kernel, lens, teamRegistry } from '@covenant/chain/kernel';
import { Command } from '../components/common.tsx';
import { Mark, SimBanner } from '../components/kit.tsx';
import { ADDR, CAST_RPC, CHAIN_LABEL, COVENANT, REPO, rpc } from '../config.ts';
import { FG_KECCAK, REF_ENVELOPE, routeDiff, witness } from '../kernel/chip.ts';
import { bitsOf, CLAMPS, route, wordOf } from '../kernel/model.ts';
import { loadProcessor } from '../data/processor.ts';
import { fmtInt, fmtUnits } from '../format.ts';

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
}

const P = COVENANT.processor;
const K = COVENANT.kernel;
const R = CAST_RPC;
const ZERO = '0x0000000000000000000000000000000000000000';
const notYet = (what: string): Result => ({ ok: null, lines: [`${what} is not deployed yet; this check runs as soon as deployments/xlayer.json names it.`] });

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
      const v = await loadVault(rpc, K, COVENANT.kernelFactory);
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
    cast: [{ line: `cast call ${COVENANT.lens ?? '<lens>'} "replay(address,uint32)((bool,bool,bool,bool,bool,bool,bool,bytes14,bytes32))" ${K ?? '<kernel>'} 1 --rpc-url ${R}` }],
    more: <>The audit page of each settle adds this browser's own recomputation from the netlist bytes: a three-way MATCH.</>,
  },
  {
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
    claim: 'Every team wallet is listed on chain in the TeamRegistry, and none of them ever buys, sells or swaps an IGNIX token, or sends funds into a kernel.',
    run: async () => {
      if (!COVENANT.teamRegistry) return notYet('The TeamRegistry');
      const reg = teamRegistry(COVENANT.teamRegistry);
      const [count] = await readAll(rpc, [reg.count()] as const);
      if (count instanceof Error) throw count;
      const entries = await readAll(rpc, Array.from({ length: Math.min(count, 50) }, (_, i) => reg.at(i)));
      const wallets = entries.filter((e) => !(e instanceof Error)) as { wallet: string; role: string }[];
      const lines: ComponentChildren[] = wallets.map((w) => `registry: ${w.wallet} (${w.role || 'no role declared'})`);
      // docs/WALLETS.md also names the keeper; say so when the registry does not list it yet
      if (COVENANT.keeper && !wallets.some((w) => w.wallet.toLowerCase() === COVENANT.keeper!.toLowerCase())) {
        wallets.push({ wallet: COVENANT.keeper, role: 'keeper' });
        lines.push(`docs/WALLETS.md: ${COVENANT.keeper} (keeper), not declared in the registry yet`);
      }
      let ok: boolean | null = null;
      if (K) {
        const [tok] = await readAll(rpc, [kernel(K).token()] as const);
        if (!(tok instanceof Error) && tok.toLowerCase() !== ZERO) {
          const bals = await readAll(rpc, wallets.map((w) => erc20(tok).balanceOf(w.wallet)));
          ok = bals.every((b) => b === 0n);
          lines.push(`none of them holds the reference token: ${ok}`);
        }
      }
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
];

function CheckCard({ c, i }: { c: Check; i: number }) {
  const [state, setState] = useState<'idle' | 'running' | Result | Error>('idle');
  const run = (): void => {
    setState('running');
    c.run().then(setState, (e: unknown) => setState(e instanceof Error ? e : new Error(String(e))));
  };
  const res = typeof state === 'object' && !(state instanceof Error) ? state : null;
  return (
    <li class="judgecheck">
      <div class="jhead">
        <span class="jnum">{i + 1}</span>
        <div>
          <h3>{c.title}</h3>
          <p>{c.claim}</p>
        </div>
      </div>
      <div class="row">
        <button type="button" class="primary small" onClick={run} disabled={state === 'running'}>
          {state === 'running' ? 'running…' : res || state instanceof Error ? 'run again' : 'run in this page'}
        </button>
        {res && (
          <span>
            <Mark ok={res.ok} /> {res.ok === true ? 'passed' : res.ok === false ? 'FAILED' : 'nothing to check yet'}
          </span>
        )}
        {state instanceof Error && <span class="warn">could not read the chain: {state.message}</span>}
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
  return (
    <article>
      <SimBanner />
      <p class="crumbs">
        <a href="#/">Covenant</a> / judge guide
      </p>
      <h1>Seven checks, five minutes, no wallet</h1>
      <p class="lede">
        Each check asks {CHAIN_LABEL} with free read calls from this page and shows the same question as a{' '}
        <span class="mono">cast</span> command for a node of your choice. A check whose contract is not deployed yet says so instead of
        passing.
      </p>
      <ol class="judge">
        {CHECKS.map((c, i) => (
          <CheckCard key={c.title} c={c} i={i} />
        ))}
      </ol>
      <p class="muted">
        What these checks rest on, and what they cannot show, is on the <a href="#/trust">trust page</a>. Unaudited.
      </p>
    </article>
  );
}
