// The kernel pages' checks from a terminal: the landing page's two-state demonstration on the flagship chip, then
// every settle record of a kernel recomputed four ways (record, Lens on TapeOut, Lens on the SealedVM, this site's
// TAP-20 simulator) with the routed amounts recomputed by the TypeScript clip. Read-only; exits 1 on any mismatch.
// A v2 kernel (USD₮0 quote) is recognised by its factory; its records go through the clip with the code shift and
// its input codes are checked against lg8(amount << shift).
//
//   node scripts/verify-kernel.ts               the flagship kernel of deployments/xlayer.json (and the v2 one, if recorded)
//   node scripts/verify-kernel.ts 0xKernel      another kernel of either factory
//   node scripts/verify-kernel.ts --last 20     record 1 and the last 20 of each kernel, not every record (about
//                                               1.5 s per record over the public RPC; each kernel gains 96 a day)

import { readFileSync } from 'node:fs';
import { processor, read, toBytes } from '@covenant/chain';
import { parse, step } from '@covenant/tap20';
import { COVENANT, rpc } from '../src/config.ts';
import { loadAudit, loadNetlist, loadRecords, loadVault, type RecordRow } from '../src/data/kernel.ts';
import { routeDiff } from '../src/kernel/chip.ts';
import { inputFields, lg8s, route, stateBytes, stateWord32, wordOf } from '../src/kernel/model.ts';
import { isAddress } from '../src/format.ts';

const hex = (b: Uint8Array): string => '0x' + Buffer.from(b).toString('hex');
const args = process.argv.slice(2).filter((a) => a !== '--');
// --last N (or --last=N): check record 1 and the last N records of each kernel. Without it, every record.
let last: number | null = null;
const at = args.findIndex((a) => a === '--last' || a.startsWith('--last='));
if (at >= 0) {
  const [flag] = args.splice(at, 1);
  const value = flag.includes('=') ? flag.slice(flag.indexOf('=') + 1) : (args.splice(at, 1)[0] ?? '');
  last = /^[1-9]\d{0,8}$/.test(value) ? Number(value) : NaN;
}
const KS = args[0] ? [args[0]] : [COVENANT.kernel, COVENANT.kernelV2].filter((k): k is string => !!k);
if (Number.isNaN(last) || KS.length === 0 || !KS.every(isAddress) || (!COVENANT.lens && !COVENANT.lensV2)) {
  console.error('usage: node scripts/verify-kernel.ts [0xKernel] [--last N]  (needs a kernel and its Lens in deployments/xlayer.json; N is a whole number from 1)');
  process.exit(2);
}
let bad = 0;
const say = (ok: boolean, what: string): void => {
  if (!ok) bad++;
  console.log(`${ok ? 'MATCH   ' : 'MISMATCH'} ${what}`);
};

// 1. Same inputs, two states, two routes: on chain and here.
const w = JSON.parse(readFileSync(new URL('../../chips/out/fg.witness.json', import.meta.url), 'utf8'));
const fg = parse(toBytes(readFileSync(new URL('../../chips/out/fg.hex', import.meta.url), 'utf8').trim()), 96, 112);
if (COVENANT.processor && COVENANT.chipId !== null) {
  for (const s of [w.reachA.state, w.reachB.state]) {
    const chain = await read(rpc, processor(COVENANT.processor).step(COVENANT.chipId, s, w.x));
    const local = step(fg, toBytes(s), toBytes(w.x));
    say(chain.outputs === hex(local.outputs) && chain.newState === hex(local.newState), `chip #${COVENANT.chipId} step from ${s}: outputs ${chain.outputs}`);
  }
  console.log(`         route fields that differ between the two states: ${routeDiff(w.outA.y, w.outB.y).join(', ')}`);
}

// 2. Every record of each kernel.
for (const K of KS) {
  const v = await loadVault(rpc, K, COVENANT);
  const s0 = v.kind.version === 2 ? `kernel v2 (${v.kind.quoteSymbol} quote, shift ${v.kind.shift} bits)` : 'kernel v1 (OKB quote)';
  // kernel v2 approves its own buys (approve is expected in its code); every other forbidden selector is not
  const forbidden = v.implScan?.selectors.filter((x) => v.kind.version === 1 || x !== 'approve(address,uint256)') ?? null;
  console.log(`${s0} ${v.kernel} (by ${v.kind.by}): ${v.count} records, token ${v.token?.address ?? 'none'}, clone ${v.clone.isClone && v.argsMatch}, implementation clean ${forbidden?.length === 0 && v.implScan?.delegatecall === 0}`);
  const nl = await loadNetlist(rpc, v.globals);
  const chip = parse(nl.bytes, 96, 112);
  // With --last N: record 1 and the last N. loadRecords also reads the record before a range, for the state its
  // first record was stepped from, so each row is checked exactly as in a full run.
  const from = last === null ? 1 : Math.max(1, v.count - last + 1);
  const ranges = from > 2 ? [[1, 1], [from, v.count]] : [[1, v.count]];
  if (last !== null) console.log(`         --last ${last}: checking ${from > 2 ? v.count - from + 2 : v.count} of ${v.count} records${from > 2 ? ` (1 and ${from} to ${v.count})` : ''}`);
  const rows: RecordRow[] = [];
  for (const [a, b] of ranges) rows.push(...(await loadRecords(rpc, K, a, b, v.kind.version)));
  for (const r of rows) {
    const grad = (r.rec.flags & 64) !== 0;
    const sh = grad ? 0 : v.kind.shift;
    const b = step(chip, toBytes(stateBytes(r.stateBefore, v.globals.nState)), toBytes(r.rec.inputs));
    const localOk = (r.rec.flags & 1) !== 0 || (hex(b.outputs) === r.rec.outputs && stateWord32(hex(b.newState)) === r.rec.stateAfter);
    const rt = route(v.envelope, wordOf(r.rec.outputs), r.rec.inflow, r.rec.reserveBefore, r.cumInflow, r.allowPaidCum - r.rec.allow, grad, sh);
    const x = inputFields(r.rec.inputs);
    const codesOk = x.TAX === lg8s(r.rec.inflow, sh) && x.TAXCUM === lg8s(r.cumInflow, sh) && x.RES === lg8s(r.rec.reserveBefore, sh);
    const amountsOk = rt.clamp === r.rec.clampBits && rt.allow === r.rec.allow && rt.buyDecided === r.rec.buyDecided && codesOk;
    const a = await loadAudit(rpc, COVENANT, K, r.n);
    const lensOk = [a.replayTapeout, a.replaySealed].every((x) => !(x instanceof Error) && x.ok);
    say(localOk && amountsOk && lensOk, `record ${r.n} (epoch ${r.rec.epoch}): browser ${localOk}, clip ${amountsOk}, Lens TapeOut+SealedVM ${lensOk}, clamps ${r.rec.clampBits}, flags ${r.rec.flags}`);
  }
}
console.log(bad ? `${bad} MISMATCH` : 'all MATCH');
process.exit(bad ? 1 : 0);
