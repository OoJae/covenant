// The kernel pages' data path against the fork fixture (web/scripts/fork-fixture.sh): every record replayed four
// ways, the local clip against the recorded amounts, the local shadow run against Lens.shadowChip, the counterfactual
// totals against the records; for kernel v1 and, when the fixture made one, for a kernel v2 (USD₮0 quote) whose
// records span the curve and graduation. Runs only with COVENANT_FORK set:
//
//   COVENANT_FORK=web/.fork/deployment.json pnpm --filter web exec vitest run test/fork.test.ts

import { describe, expect, test } from 'vitest';
import { COVENANT, rpc, SIMULATION } from '../src/config.ts';
import { detectKernel, loadAudit, loadCounterfactual, loadNetlist, loadRecords, loadShadowChip, loadVault, quoteLegIn } from '../src/data/kernel.ts';
import { FG_KECCAK } from '../src/kernel/chip.ts';
import { inputFields, lg8s, route, wordOf } from '../src/kernel/model.ts';
import { chipFromBytes, glutton, replayLocal, shadowRun } from '../src/kernel/sim.ts';

const fork = SIMULATION ? describe : describe.skip;

fork('kernel pages on the fork fixture', { timeout: 300_000 }, () => {
  const K = COVENANT.kernel!;
  const L = COVENANT.lens!;

  test('vault: bound, holds its chip, a clean clone of the factory implementation', async () => {
    const v = await loadVault(rpc, K, COVENANT);
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
    expect(v.kind).toMatchObject({ version: 1, by: 'factory v1', shift: 0, quote: null, quoteSymbol: 'OKB', lens: COVENANT.lens });
  });

  test('every record: kernel = TapeOut replay = SealedVM replay = this simulator, and the clip port gives the recorded amounts', async () => {
    const v = await loadVault(rpc, K, COVENANT);
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
      const a = await loadAudit(rpc, COVENANT, K, r.n);
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
    const v = await loadVault(rpc, K, COVENANT);
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
    const v = await loadVault(rpc, K, COVENANT);
    const rows = await loadRecords(rpc, K, 1, v.count);
    const cf = await loadCounterfactual(rpc, L, K, v.count, 5); // several pages
    expect(cf!.curve.chip.inflow).toBe(rows.reduce((s, r) => s + r.rec.inflow, 0n));
    expect(cf!.curve.chip.allow).toBe(rows.reduce((s, r) => s + r.rec.allow, 0n));
    expect(cf!.curve.chip.buy).toBe(rows.reduce((s, r) => s + r.rec.buyDecided, 0n));
    const one = await loadCounterfactual(rpc, L, K, v.count, 400);
    expect(cf).toEqual(one); // paging does not change the answer
  });
});

const forkV2 = SIMULATION?.v2 && COVENANT.kernelV2 ? describe : describe.skip;

forkV2('kernel v2 (USD₮0 quote) on the fork fixture', { timeout: 600_000 }, () => {
  const K = COVENANT.kernelV2!;

  test('told apart by factory: the v2 factory created it, the v1 factory did not; and the other way round for the v1 kernel', async () => {
    const k2 = await detectKernel(rpc, COVENANT, K);
    expect(k2).toMatchObject({ version: 2, by: 'factory v2', shift: 33, quoteSymbol: 'USD₮0', quoteDecimals: 6, lens: COVENANT.lensV2, factory: COVENANT.kernelFactoryV2 });
    expect(k2.quote?.toLowerCase()).toBe('0x779ded0c9e1022225f8e0630b35a9b54be713736');
    const k1 = await detectKernel(rpc, COVENANT, COVENANT.kernel!);
    expect(k1).toMatchObject({ version: 1, by: 'factory v1', shift: 0, lens: COVENANT.lens });
    // without the v2 factory in the deployment file, the v2 kernel is still recognised by its answers, with no Lens
    const shape = await detectKernel(rpc, { ...COVENANT, kernelFactoryV2: null, lensV2: null }, K);
    expect(shape).toMatchObject({ version: 2, by: 'shape', shift: 33, lens: null });
  });

  test('vault: bound to a USD₮0-quoted token, holds its chip, clean clone, only approve in its code, no allowance left, not blocked', async () => {
    const v = await loadVault(rpc, K, COVENANT);
    expect(v.kind.version).toBe(2);
    expect(v.token?.address.toLowerCase()).toBe(SIMULATION!.v2!.token.toLowerCase());
    expect(v.count).toBe(SIMULATION!.v2!.records);
    expect(v.isKernel).toBe(true);
    expect(v.ourFactory).toBe(true);
    expect(v.chipOwner?.toLowerCase()).toBe(K.toLowerCase());
    expect(v.vaultRecipient?.toLowerCase()).toBe(K.toLowerCase());
    expect(v.vaultQuote?.toLowerCase()).toBe(v.kind.quote?.toLowerCase());
    expect(v.clone.isClone).toBe(true);
    expect(v.argsMatch).toBe(true);
    expect(v.implementation?.toLowerCase()).toBe(COVENANT.kernelImplV2?.toLowerCase());
    expect(v.implScan).toMatchObject({ delegatecall: 0, callcode: 0, selfdestruct: 0, selectors: ['approve(address,uint256)'] });
    expect([v.allowanceToManager, v.allowanceToRouter, v.quoteBlocked]).toEqual([0n, 0n, false]);
    expect(v.graduated).toBe(SIMULATION!.v2!.graduatedAt !== null);
    expect(v.quoteHeld! >= (v.quoteCredits ?? 0n)).toBe(true);
  });

  test('every record: kernel = LensV2 on TapeOut = LensV2 on the SealedVM = this simulator; shifted codes and clip as recorded', async () => {
    const v = await loadVault(rpc, K, COVENANT);
    const nl = await loadNetlist(rpc, v.globals);
    expect(nl.keccak).toBe(FG_KECCAK);
    const chip = chipFromBytes('fg', nl.bytes);
    const rows = await loadRecords(rpc, K, 1, v.count, 2);
    expect(rows.map((r) => r.n)).toEqual(Array.from({ length: v.count }, (_, i) => i + 1));
    let curve = 0;
    let grad = 0;
    let quoteLeg = 0n;
    let clampFree = true;
    for (const r of rows) {
      const g = (r.rec.flags & 64) !== 0;
      const sh = g ? 0 : 33;
      const local = replayLocal(chip.netlist, r.stateBefore, r.rec.inputs);
      expect(local.outputs, `record ${r.n}`).toBe(r.rec.outputs);
      expect(local.stateAfter32, `record ${r.n}`).toBe(r.rec.stateAfter);
      const x = inputFields(r.rec.inputs);
      expect([x.TAX, x.TAXCUM, x.RES, x.GRAD], `record ${r.n}`).toEqual([lg8s(r.rec.inflow, sh), lg8s(r.cumInflow, sh), lg8s(r.rec.reserveBefore, sh), g ? 1 : 0]);
      const rt = route(v.envelope, wordOf(r.rec.outputs), r.rec.inflow, r.rec.reserveBefore, r.cumInflow, r.allowPaidCum - r.rec.allow, g, sh);
      expect([rt.clamp, rt.allow, rt.buyDecided], `record ${r.n}`).toEqual([r.rec.clampBits, r.rec.allow, r.rec.buyDecided]);
      clampFree &&= r.rec.clampBits === 0;
      const a = await loadAudit(rpc, COVENANT, K, r.n);
      expect(a.kind.version).toBe(2);
      for (const rep of [a.replayTapeout, a.replaySealed]) {
        if (rep instanceof Error) throw rep;
        expect(rep.ok, `record ${r.n}`).toBe(true);
        expect(rep.outputs).toBe(r.rec.outputs);
      }
      if (g) {
        grad++;
        quoteLeg += quoteLegIn(r.rec);
      } else curve++;
    }
    expect(curve).toBeGreaterThan(0);
    if (SIMULATION!.v2!.graduatedAt !== null) {
      expect(grad).toBeGreaterThan(0);
      expect(quoteLeg).toBeGreaterThan(0n); // revenue after graduation went through the quote leg
    }
    expect(clampFree).toBe(true); // the Flow Governor never needs the envelope, through the shift too
  });

  test('the Glutton shadow run with the shift: this browser = LensV2.shadowChip; the allowance stays within the envelope', async () => {
    expect(COVENANT.gluttonChipId).not.toBeNull();
    const v = await loadVault(rpc, K, COVENANT);
    const rows = await loadRecords(rpc, K, 1, v.count, 2);
    const local = shadowRun(glutton().netlist, v.envelope, rows.map((r) => ({ n: r.n, rec: r.rec, cumInflow: r.cumInflow })), v.kind.shift);
    const chain = await loadShadowChip(rpc, COVENANT.lensV2!, K, COVENANT.gluttonChipId!, v.count);
    expect(chain.length).toBe(local.length);
    chain.forEach((c, i) => {
      expect(c.ran).toBe(true);
      expect({ n: c.n, inputs: c.inputs, outputs: c.outputs, clampBits: c.clampBits, allow: c.allow, buyDecided: c.buyDecided, reserveAfter: c.reserveAfter }).toEqual(local[i]);
    });
    const curve = rows.filter((r) => (r.rec.flags & 64) === 0);
    const tax = curve.reduce((s, r) => s + r.rec.inflow, 0n);
    const allow = local.reduce((s, x) => s + x.allow, 0n);
    expect(allow > 0n).toBe(true);
    expect(allow * 10000n <= tax * BigInt(v.envelope.allowCumBps)).toBe(true);
    // and the per-settle ceiling, 3.932160 USD₮0, through the shift
    for (const x of local) expect(x.allow <= 3_932_160n).toBe(true);
  });

  test('counterfactual (LensV2): the chip column adds up to the records of each regime', async () => {
    const v = await loadVault(rpc, K, COVENANT);
    const rows = await loadRecords(rpc, K, 1, v.count, 2);
    const cf = await loadCounterfactual(rpc, COVENANT.lensV2!, K, v.count, 5);
    const sum = (g: boolean, f: (r: (typeof rows)[number]) => bigint): bigint => rows.filter((r) => ((r.rec.flags & 64) !== 0) === g).reduce((s, r) => s + f(r), 0n);
    expect(cf!.curve.chip.inflow).toBe(sum(false, (r) => r.rec.inflow));
    expect(cf!.curve.chip.allow).toBe(sum(false, (r) => r.rec.allow));
    expect(cf!.curve.chip.buy).toBe(sum(false, (r) => r.rec.buyDecided));
    expect(cf!.graduated.chip.inflow).toBe(sum(true, (r) => r.rec.inflow));
    const one = await loadCounterfactual(rpc, COVENANT.lensV2!, K, v.count, 400);
    expect(cf).toEqual(one);
  });

  test('the v1 Lens refuses the v2 kernel and LensV2 refuses the v1 kernel: each page asks its own', async () => {
    const { lens } = await import('@covenant/chain/kernel');
    const { read } = await import('@covenant/chain');
    await expect(read(rpc, lens(COVENANT.lens!).replay(K, 1))).rejects.toThrow();
    await expect(read(rpc, lens(COVENANT.lensV2!).replay(COVENANT.kernel!, 1))).rejects.toThrow();
  });
});
