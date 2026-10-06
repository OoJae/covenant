// The site's data path against X Layer mainnet, without a browser: the same functions the
// pages call. Read-only (eth_call). Set SKIP_LIVE=1 to skip.

import { describe, expect, test } from 'vitest';
import { layout } from '@covenant/dieshot';
import { byteLength } from '@covenant/tap20';
import { ADDR, EXAMPLES, rpc } from '../src/config.ts';
import { chainBeat, loadCircuit, localBeat, sameBeat } from '../src/data/circuit.ts';
import { loadCircuits, loadProcessor } from '../src/data/processor.ts';

const TRIVIUM = '0x933FC3AA0c387CB8B6B1D22a2Ec3E2B5eeCfDb5a';
const LOTEGATE = '0xAa13ae45b0B2D52f210Ad7Ef12997113a0ebAF21';
const P0 = '0x839bdD6fa7A66416A609A735e11DE5411B98574e';

const live = process.env.SKIP_LIVE ? describe.skip : describe;

live('data path on X Layer mainnet', { timeout: 180_000 }, () => {
  test('processor page: Trivium', async () => {
    const p = await loadProcessor(rpc, ADDR.factory, TRIVIUM.toLowerCase());
    expect(p.address).toBe(TRIVIUM); // shown in EIP-55 form whatever the route said
    expect(p.name).toBe('Trivium');
    expect(p.symbol).toBe('CPU');
    expect(p.registered).toBe(true);
    expect(p.circuits).toBeGreaterThanOrEqual(1);
    expect(p.transistors).toMatch(/^0x[0-9a-fA-F]{40}$/);
    expect(p.creator).toMatch(/^0x[0-9a-fA-F]{40}$/);
    expect(typeof p.supplyCap).toBe('bigint');
    expect(typeof p.mintPrice).toBe('bigint');
    expect(p.minted!).toBeLessThanOrEqual(p.supplyCap!);
    expect(typeof p.story).toBe('string');
    expect(p.cpuName).toBe('Trivium');
    expect(p.block!).toBeGreaterThan(72_000_000n);
  });

  test('processor page: an address that is not a processor is refused with a readable message', async () => {
    await expect(loadProcessor(rpc, ADDR.factory, '0xcA11bde05977b3631167028862bE2a173976CA11')).rejects.toThrow('does not answer like a TapeOut processor');
    await expect(loadProcessor(rpc, ADDR.factory, '0x000000000000000000000000000000000000dEaD')).rejects.toThrow('does not answer like a TapeOut processor');
  });

  test('circuit list: all of processor 0, asking for more ids than exist', async () => {
    const p = await loadProcessor(rpc, ADDR.factory, P0);
    expect(p.circuits).toBeGreaterThanOrEqual(103);
    const rows = await loadCircuits(rpc, P0, 1, p.circuits + 5);
    expect(rows.length).toBe(p.circuits); // ids past the last one are dropped, not shown as errors
    expect(rows[0]).toMatchObject({ id: 1, info: { nIn: 2, nOut: 1, nState: 0, gateCount: 4 } });
    expect(rows[3]).toMatchObject({ id: 4, info: { nIn: 0, nOut: 1, nState: 2, gateCount: 10 } });
    for (const r of rows) expect(r.owner).toMatch(/^0x[0-9a-fA-F]{40}$/);
  });

  test('circuit page: a circuit that does not exist is refused with the chain\'s reason', async () => {
    await expect(loadCircuit(rpc, ADDR.factory, TRIVIUM, 999n)).rejects.toThrow('no circuit');
  });

  for (const [label, cpu, id, want] of [
    ['Trivium #1', TRIVIUM, 1n, { gates: 3035, state: 288, bytes: 20381, keccak: '0x68c5f5d81225f000849f0ae9aaf594753a8a124f78dadc590a053811ea783960', layoutHash: 'b060dce833f3dfa593985762a0a27d8311fc6e19a9557bad273c6b3be744f834' }],
    ['LoteGate #3', LOTEGATE, 3n, { gates: 4863, state: 243, bytes: 33312, keccak: '0x0478369b8e75c51870734f6d64712c071d97640b4d9457595bdf3a5bff474f53', layoutHash: '9c581dd87d710d6eef7940bcfe33671331c946d89608a83923792a49ef8b5ea2' }],
  ] as const) {
    test(`circuit page: ${label} loads, hashes as recorded, and three chained beats MATCH`, async () => {
      const c = await loadCircuit(rpc, ADDR.factory, cpu, id);
      expect(c.processor).toBe(cpu);
      expect(c.registered).toBe(true);
      expect(c.consistent).toBe(true);
      expect(c.netlist.gateCount).toBe(want.gates);
      expect(c.netlist.nState).toBe(want.state);
      expect(c.bytes.length).toBe(want.bytes);
      // Stored netlists have no setter: these are the values read on 2026-10-04. A change here
      // means TapeOut's contracts were upgraded, which is worth knowing.
      expect(c.keccak).toBe(want.keccak);
      // The floorplan is a pure function of the bytes: the same hash the browser showed.
      expect(layout(c.netlist).layoutHash).toBe(want.layoutHash);

      let state: Uint8Array = new Uint8Array(byteLength(c.netlist.nState));
      let seed = 0x5eed0000 + Number(id);
      for (let beat = 0; beat < 3; beat++) {
        const inputs = new Uint8Array(byteLength(c.netlist.nIn));
        for (let i = 0; i < inputs.length; i++) {
          seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
          inputs[i] = seed >>> 24;
        }
        const local = localBeat(c.netlist, state, inputs);
        const chain = await chainBeat(rpc, c.processor, c.id, c.netlist.nState, state, inputs);
        expect(chain).toEqual({ newState: local.newState, outputs: local.outputs });
        expect(sameBeat(local, chain)).toBe(true);
        state = local.newStateBytes;
      }
    });
  }

  test('circuit page: a combinational circuit is checked with eval, over its whole truth table', async () => {
    const c = await loadCircuit(rpc, ADDR.factory, P0, 1n);
    expect(c.netlist.nState).toBe(0);
    const outs: string[] = [];
    for (let x = 0; x < 4; x++) {
      const local = localBeat(c.netlist, new Uint8Array(0), Uint8Array.of(x));
      const chain = await chainBeat(rpc, c.processor, c.id, 0, new Uint8Array(0), Uint8Array.of(x));
      expect(sameBeat(local, chain)).toBe(true);
      expect(chain.newState).toBe('0x');
      outs.push(chain.outputs);
    }
    expect(outs).toEqual(['0x00', '0x01', '0x01', '0x00']); // it is an XOR
  });

  test('circuit page: a REF circuit loads its target from another processor and MATCHES over its state cycle', async () => {
    const c = await loadCircuit(rpc, ADDR.factory, P0, 4n);
    expect(c.netlist.nRef).toBe(1);
    expect(c.consistent).toBe(true);
    expect(c.refs.map((r) => `${r.cpu.toLowerCase()}#${r.id}`)).toEqual(['0xf044d395c91e77459e6b2155015e14f0dd9b349f#102']);
    expect(c.refs[0].info).toEqual({ nIn: 0, nOut: 1, nState: 2, gateCount: 10 });
    let state: Uint8Array = new Uint8Array(1);
    const seen: string[] = [];
    for (let beat = 0; beat < 4; beat++) {
      const local = localBeat(c.netlist, state, new Uint8Array(0));
      const chain = await chainBeat(rpc, c.processor, c.id, c.netlist.nState, state, new Uint8Array(0));
      expect(sameBeat(local, chain)).toBe(true);
      seen.push(`${local.outputs}/${local.newState}`);
      state = local.newStateBytes;
    }
    // same inputs (none), different states, different outputs: 0 -> 1 -> 2 -> 0
    expect(seen).toEqual(['0x01/0x01', '0x00/0x02', '0x00/0x00', '0x01/0x01']);
  });

  test("Covenant's deployment as deployments/xlayer.json records it: processor, probe, Fab, factory, Lens", async () => {
    const { processor } = await import('@covenant/chain');
    const { fab, kernelFactory, lens } = await import('@covenant/chain/kernel');
    const { readAll } = await import('@covenant/chain');
    const { COVENANT } = await import('../src/config.ts');
    const p = await loadProcessor(rpc, ADDR.factory, COVENANT.processor!);
    expect(p.registered).toBe(true);
    expect(p.name).toBe('Covenant');
    expect(p.transistors).toBe(COVENANT.transistors);
    const [owner] = await readAll(rpc, [processor(COVENANT.processor!).ownerOf(COVENANT.probeCircuitId!)] as const);
    expect(owner).toMatch(/^0x[0-9a-fA-F]{40}$/);
    if (COVENANT.kernelFactory && COVENANT.lens && COVENANT.fab) {
      const [pins, fabOf, lensFactory, fabCircuits] = await readAll(rpc, [
        kernelFactory(COVENANT.kernelFactory).pinsLive(),
        kernelFactory(COVENANT.kernelFactory).fab(),
        lens(COVENANT.lens).factory(),
        fab(COVENANT.fab).circuits(),
      ] as const);
      expect(typeof pins).toBe('boolean'); // false only if TapeOut was upgraded since the pins were taken
      expect(String(fabOf).toLowerCase()).toBe(COVENANT.fab.toLowerCase());
      expect(String(lensFactory).toLowerCase()).toBe(COVENANT.kernelFactory.toLowerCase());
      expect(String(fabCircuits).toLowerCase()).toBe(COVENANT.processor!.toLowerCase());
    }
  });

  test('every example on the landing page opens', async () => {
    for (const x of EXAMPLES) {
      const c = await loadCircuit(rpc, ADDR.factory, x.processor, BigInt(x.id));
      expect(c.consistent).toBe(true);
      expect(c.registered).toBe(true);
    }
  });
});
