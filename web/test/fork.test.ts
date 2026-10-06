// The kernel pages' data path against the fork fixture (web/scripts/fork-fixture.sh): every record replayed four
// ways, the local clip against the recorded amounts, the local shadow run against Lens.shadowChip, the counterfactual
// totals against the records. Runs only with COVENANT_FORK set:
//
//   COVENANT_FORK=web/.fork/deployment.json pnpm --filter web exec vitest run test/fork.test.ts

import { describe, expect, test } from 'vitest';
import { COVENANT, rpc, SIMULATION } from '../src/config.ts';
import { loadAudit, loadCounterfactual, loadNetlist, loadRecords, loadShadowChip, loadVault } from '../src/data/kernel.ts';
import { FG_KECCAK } from '../src/kernel/chip.ts';
import { route, wordOf } from '../src/kernel/model.ts';
import { chipFromBytes, glutton, replayLocal, shadowRun } from '../src/kernel/sim.ts';

const fork = SIMULATION ? describe : describe.skip;

fork('kernel pages on the fork fixture', { timeout: 300_000 }, () => {
  const K = COVENANT.kernel!;
  const L = COVENANT.lens!;

  test('vault: bound, holds its chip, a clean clone of the factory implementation', async () => {
    const v = await loadVault(rpc, K, COVENANT.kernelFactory);
    expect(v.token?.address.toLowerCase()).toBe(SIMULATION!.token.toLowerCase());
    expect(v.count).toBe(SIMULATION!.records);
    expect(v.isKernel).toBe(true);
    expect(v.ourFactory).toBe(true);
    expect(v.chipOwner?.toLowerCase()).toBe(K.toLowerCase());
    expect(v.vaultRecipient?.toLowerCase()).toBe(K.toLowerCase());
    expect(v.clone.isClone).toBe(true);
    expect(v.argsMatch).toBe(true);
    expect(v.implementation?.toLowerCase()).toBe(v.factoryImpl?.toLowerCase());
    expect(v.implScan).toMatchObject({ delegatecall: 0, callcode: 0, selfdestruct: 0, selectors: [] });
    expect(v.evaluator?.sealedMode).toBe(false);
  });

  test('every record: kernel = TapeOut replay = SealedVM replay = this simulator, and the clip port gives the recorded amounts', async () => {
    const v = await loadVault(rpc, K, COVENANT.kernelFactory);
    const nl = await loadNetlist(rpc, v.globals);
    expect(nl.keccak).toBe(FG_KECCAK);
    const chip = chipFromBytes('fg', nl.bytes);
    const rows = await loadRecords(rpc, K, 1, v.count);
    expect(rows.map((r) => r.n)).toEqual(Array.from({ length: v.count }, (_, i) => i + 1));
    let clampFree = true;
    for (const r of rows) {
      const local = replayLocal(chip.netlist, r.stateBefore, r.rec.inputs);
      expect(local.outputs, `record ${r.n}`).toBe(r.rec.outputs);
      expect(local.stateAfter32, `record ${r.n}`).toBe(r.rec.stateAfter);
      const rt = route(v.envelope, wordOf(r.rec.outputs), r.rec.inflow, r.rec.reserveBefore, r.cumInflow, r.allowPaidCum - r.rec.allow, (r.rec.flags & 64) !== 0);
      expect([rt.clamp, rt.allow, rt.buyDecided], `record ${r.n}`).toEqual([r.rec.clampBits, r.rec.allow, r.rec.buyDecided]);
      clampFree &&= r.rec.clampBits === 0;
      const a = await loadAudit(rpc, L, K, r.n);
      for (const rep of [a.replayTapeout, a.replaySealed]) {
        if (rep instanceof Error) throw rep;
        expect(rep.ok, `record ${r.n}`).toBe(true);
        expect(rep.outputs).toBe(r.rec.outputs);
      }
    }
    expect(clampFree).toBe(true); // the Flow Governor never needs the envelope
  });

  test('the Glutton shadow run: this browser = Lens.shadowChip, and the allowance stays within the envelope', async () => {
    expect(COVENANT.gluttonChipId).not.toBeNull();
    const v = await loadVault(rpc, K, COVENANT.kernelFactory);
    const rows = await loadRecords(rpc, K, 1, v.count);
    const local = shadowRun(glutton().netlist, v.envelope, rows.map((r) => ({ n: r.n, rec: r.rec, cumInflow: r.cumInflow })));
    const chain = await loadShadowChip(rpc, L, K, COVENANT.gluttonChipId!, v.count);
    expect(chain.length).toBe(local.length);
    chain.forEach((c, i) => {
      expect(c.ran).toBe(true);
      expect({ n: c.n, inputs: c.inputs, outputs: c.outputs, clampBits: c.clampBits, allow: c.allow, buyDecided: c.buyDecided, reserveAfter: c.reserveAfter }).toEqual(local[i]);
    });
    const tax = rows.reduce((s, r) => s + r.rec.inflow, 0n);
    const allow = local.reduce((s, x) => s + x.allow, 0n);
    expect(allow * 10000n <= tax * BigInt(v.envelope.allowCumBps)).toBe(true);
  });

  test('counterfactual: the chip column adds up to the records', async () => {
    const v = await loadVault(rpc, K, COVENANT.kernelFactory);
    const rows = await loadRecords(rpc, K, 1, v.count);
    const cf = await loadCounterfactual(rpc, L, K, v.count, 5); // several pages
    expect(cf!.curve.chip.inflow).toBe(rows.reduce((s, r) => s + r.rec.inflow, 0n));
    expect(cf!.curve.chip.allow).toBe(rows.reduce((s, r) => s + r.rec.allow, 0n));
    expect(cf!.curve.chip.buy).toBe(rows.reduce((s, r) => s + r.rec.buyDecided, 0n));
    const one = await loadCounterfactual(rpc, L, K, v.count, 400);
    expect(cf).toEqual(one); // paging does not change the answer
  });
});
