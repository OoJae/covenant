// The site's data path, run from a terminal: for each circuit, read it from X Layer exactly as
// the circuit page does, run beats with the same simulator, ask the chain the same question
// with a free eth_call, and print MATCH or MISMATCH. Read-only; exits 1 on any mismatch.
//
//   node scripts/verify-live.ts                      the four example circuits
//   node scripts/verify-live.ts 0xProcessor 3        one circuit
//
// Beats are chained from the all-zero state with inputs from a fixed-seed generator, so every
// run asks the same questions.

import { layout } from '@covenant/dieshot';
import { byteLength } from '@covenant/tap20';
import { ADDR, EXAMPLES, rpc } from '../src/config.ts';
import { beatMethod, castLine, chainBeat, loadCircuit, localBeat, sameBeat } from '../src/data/circuit.ts';
import { isAddress } from '../src/format.ts';

const BEATS = 3;

function prng(seed: number): () => number {
  let s = seed >>> 0 || 1;
  return () => {
    s ^= s << 13;
    s >>>= 0;
    s ^= s >>> 17;
    s ^= s << 5;
    s >>>= 0;
    return s;
  };
}

// pnpm passes a literal "--" through to the script; ignore it.
const args = process.argv.slice(2).filter((a) => a !== '--');
if (args.length > 0 && !(args.length === 2 && isAddress(args[0]) && /^\d+$/.test(args[1]))) {
  console.error('usage: node scripts/verify-live.ts [0xProcessor circuitId]');
  process.exit(2);
}
const targets = args.length === 2 ? [{ processor: args[0], id: Number(args[1]), label: `${args[0]} #${args[1]}` }] : EXAMPLES;

let failures = 0;
for (const t of targets) {
  const c = await loadCircuit(rpc, ADDR.factory, t.processor, BigInt(t.id));
  const nl = c.netlist;
  const lay = layout(nl);
  console.log(`\n${t.label}  (${c.processor} #${c.id}, read at block ${c.block})`);
  console.log(`  ${nl.nIn} in, ${nl.nOut} out, ${nl.nState} state bits, ${nl.gateCount} gates (${nl.nNand} NAND, ${nl.nLatch} LATCH, ${nl.nRef} REF), ${nl.byteLength} bytes`);
  console.log(`  keccak256 ${c.keccak}`);
  console.log(`  decoded state bits and gate count equal circuitInfo: ${c.consistent ? 'yes' : 'NO'}`);
  console.log(`  layout ${lay.cols} x ${lay.rows} cells, ${lay.maxLevel} levels, layoutHash ${lay.layoutHash}`);
  for (const r of c.refs) console.log(`  REF target ${r.cpu} #${r.id}: ${r.info.gateCount} gates, ${r.info.nState} state bits`);
  if (!c.consistent) failures++;

  const rnd = prng(0xc0ffee + t.id);
  let state: Uint8Array = new Uint8Array(byteLength(nl.nState));
  for (let beat = 1; beat <= BEATS; beat++) {
    const inputs = new Uint8Array(byteLength(nl.nIn));
    for (let i = 0; i < inputs.length; i++) inputs[i] = rnd() & 255;
    if (nl.nIn & 7 && inputs.length) inputs[inputs.length - 1] &= (1 << (nl.nIn & 7)) - 1;
    const local = localBeat(nl, state, inputs);
    const chain = await chainBeat(rpc, c.processor, c.id, nl.nState, state, inputs);
    const match = sameBeat(local, chain);
    if (!match) failures++;
    console.log(`  beat ${beat}: ${match ? 'MATCH' : 'MISMATCH'}  (${beatMethod(nl.nState)} via ${new URL(rpc.current()).host})`);
    console.log(`    local outputs     ${local.outputs}`);
    console.log(`    on-chain outputs  ${chain.outputs}`);
    if (nl.nState > 0) {
      console.log(`    new state (local) ${local.newState}`);
      if (chain.newState !== local.newState) console.log(`    new state (chain) ${chain.newState}`);
    }
    if (beat === 1) console.log(`    ${castLine(c.processor, c.id, nl.nState, state, inputs, ADDR.rpc[0])}`);
    state = local.newStateBytes;
  }
}

console.log(failures === 0 ? '\nALL MATCH' : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
