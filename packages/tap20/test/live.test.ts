// The simulator against the deployed evaluator on X Layer mainnet (chain 196), read-only.
// Set SKIP_LIVE=1 to skip. Every on-chain result comes from a free eth_call to
// Circuits.step / Circuits.eval; nothing is sent.

import { describe, expect, test } from 'vitest';
import { createRpc, factory, processor, read, readAll, toBytes, toHex } from '@covenant/chain';
import { byteLength, bytesToHex, encode, evaluate, load, parse, step, type Fetcher, type Netlist } from '../src/index.ts';

const RPC = ['https://rpc.xlayer.tech', 'https://xlayerrpc.okx.com'];
const FACTORY = '0x1f09daefa827f02cbb40967cc91b259763760761';

const live = process.env.SKIP_LIVE ? describe.skip : describe;

// xorshift32 with a fixed seed: the same "random" vectors on every run.
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
function randomBits(rnd: () => number, n: number): Uint8Array {
  const out = new Uint8Array(byteLength(n));
  for (let i = 0; i < out.length; i++) out[i] = rnd() & 255;
  if (n & 7 && out.length) out[out.length - 1] &= (1 << (n & 7)) - 1;
  return out;
}

live('simulator == Circuits.step on X Layer mainnet', { timeout: 300_000 }, () => {
  const rpc = createRpc(RPC, { timeout: 45_000 });

  const big = [
    { label: 'LoteGate #3', cpu: '0xAa13ae45b0B2D52f210Ad7Ef12997113a0ebAF21', id: 3, info: { nIn: 133, nOut: 199, nState: 243, gateCount: 4863 } },
    { label: 'Trivium #1', cpu: '0x933FC3AA0c387CB8B6B1D22a2Ec3E2B5eeCfDb5a', id: 1, info: { nIn: 161, nOut: 1, nState: 288, gateCount: 3035 } },
  ];

  for (const c of big) {
    describe(c.label, () => {
      const p = processor(c.cpu);
      let nl: Netlist;
      let bytes: Uint8Array;

      test('netlist decodes; shape, state bits and gate count equal circuitInfo; re-encodes byte for byte', async () => {
        const [info, hex] = await readAll(rpc, [p.circuitInfo(c.id), p.netlist(c.id)] as const);
        expect(info).toEqual(c.info);
        bytes = toBytes(hex as string);
        nl = parse(bytes, c.info.nIn, c.info.nOut);
        expect(nl.nState).toBe(c.info.nState);
        expect(nl.gateCount).toBe(c.info.gateCount);
        expect(nl.nRef).toBe(0);
        expect(nl.nNand * 7 + nl.nLatch * 4).toBe(bytes.length);
        expect(bytesToHex(encode(nl))).toBe(bytesToHex(bytes));
      });

      test('6 random (state, inputs) pairs: new state and outputs identical to the chain', async () => {
        const rnd = prng(0xc0de0000 + c.id);
        for (let i = 0; i < 6; i++) {
          const state = randomBits(rnd, nl.nState);
          const inputs = randomBits(rnd, nl.nIn);
          const local = step(nl, state, inputs);
          const chain = await read(rpc, p.step(c.id, toHex(state), toHex(inputs)));
          expect(toHex(local.newState)).toBe(chain.newState);
          expect(toHex(local.outputs)).toBe(chain.outputs);
        }
      });

      test('a 5-beat run from the all-zero state, feeding each new state back in', async () => {
        const rnd = prng(0xbea70000 + c.id);
        let local: Uint8Array = new Uint8Array(byteLength(nl.nState));
        let chain = toHex(local);
        for (let i = 0; i < 5; i++) {
          const inputs = randomBits(rnd, nl.nIn);
          const l = step(nl, local, inputs);
          const r = await read(rpc, p.step(c.id, chain, toHex(inputs)));
          expect(toHex(l.newState)).toBe(r.newState);
          expect(toHex(l.outputs)).toBe(r.outputs);
          local = l.newState;
          chain = r.newState;
        }
      });

      test('lenient reading: empty, short and over-long byte strings read as the chain reads them', async () => {
        const rnd = prng(0x1e000000 + c.id);
        const state = randomBits(rnd, nl.nState);
        const inputs = randomBits(rnd, nl.nIn);
        const shapes: [Uint8Array, Uint8Array][] = [
          [new Uint8Array(0), new Uint8Array(0)],
          [state.subarray(0, 5), inputs.subarray(0, 3)],
          [Uint8Array.from([...state, 0xff, 0xff]), Uint8Array.from([...inputs, 0xff])],
          [state.map(() => 0xff), inputs.map(() => 0xff)], // padding bits set
        ];
        for (const [s, x] of shapes) {
          const l = step(nl, s, x);
          const r = await read(rpc, p.step(c.id, toHex(s), toHex(x)));
          expect(toHex(l.newState)).toBe(r.newState);
          expect(toHex(l.outputs)).toBe(r.outputs);
        }
      });
    });
  }

  // What a REF may point at (TAP-20 section 3, condition 6): a circuit that exists on a
  // processor registered with the factory. Three eth_calls in one Multicall3 request.
  const fetched: string[] = [];
  const fetcher: Fetcher = async (cpu, id) => {
    fetched.push(`${cpu}#${id}`);
    const p = processor(cpu);
    const [registered, info, hex] = await readAll(rpc, [factory(FACTORY).isCPU(cpu), p.circuitInfo(id), p.netlist(id)] as const);
    if (registered !== true || info instanceof Error || hex instanceof Error) return undefined;
    return { netlist: toBytes(hex), nIn: info.nIn, nOut: info.nOut };
  };

  test('small circuits on processor 0, one of them a REF into another processor: exhaustive over every state and input', async () => {
    const p0 = await read(rpc, factory(FACTORY).cpuAt(0));
    const p = processor(p0);
    const ids = [1, 2, 3, 4];
    const meta = await readAll(rpc, ids.flatMap((id) => [p.circuitInfo(id), p.netlist(id)]));
    let compared = 0;
    let refs = 0;
    for (let k = 0; k < ids.length; k++) {
      const id = ids[k];
      const info = meta[2 * k] as { nIn: number; nOut: number; nState: number; gateCount: number };
      const bytes = toBytes(meta[2 * k + 1] as string);
      const nl = await load(bytes, info.nIn, info.nOut, fetcher);
      expect(bytesToHex(encode(nl))).toBe(bytesToHex(bytes));
      expect(nl.nState).toBe(info.nState);
      expect(nl.gateCount).toBe(info.gateCount);
      refs += nl.nRef;
      expect(info.nIn + info.nState).toBeLessThanOrEqual(8);
      const calls = [];
      const want: { newState: string; outputs: string }[] = [];
      for (let s = 0; s < 1 << info.nState; s++) {
        for (let x = 0; x < 1 << info.nIn; x++) {
          const state = info.nState ? Uint8Array.of(s) : new Uint8Array(0);
          const inputs = info.nIn ? Uint8Array.of(x) : new Uint8Array(0);
          const l = step(nl, state, inputs);
          want.push({ newState: toHex(l.newState), outputs: toHex(l.outputs) });
          calls.push(p.step(id, toHex(state), toHex(inputs)));
          if (info.nState === 0) expect(toHex(evaluate(nl, inputs))).toBe(toHex(l.outputs));
        }
      }
      const got = await readAll(rpc, calls);
      expect(got).toEqual(want);
      compared += calls.length;
      if (info.nState === 0) {
        // eval() exists for circuits without state and must agree too
        const evals = await readAll(rpc, Array.from({ length: 1 << info.nIn }, (_, x) => p.eval(id, toHex(Uint8Array.of(x)))));
        expect(evals).toEqual(want.map((w) => w.outputs));
      }
    }
    expect(compared).toBeGreaterThanOrEqual(16);
    // Circuit 4 is a single REF record: its gates and its two state bits live in the target.
    expect(refs).toBe(1);
    expect(fetched).toEqual(['0xf044d395c91e77459e6b2155015e14f0dd9b349f#102']);
  });

  test('the REF target itself, stepped directly on its own processor', async () => {
    const cpu = '0xf044d395c91e77459e6b2155015e14f0dd9b349f';
    const p = processor(cpu);
    const [info, hex] = await readAll(rpc, [p.circuitInfo(102), p.netlist(102)] as const);
    expect(info).toEqual({ nIn: 0, nOut: 1, nState: 2, gateCount: 10 });
    const nl = parse(toBytes(hex as string), 0, 1);
    expect(nl.nLatch).toBe(2);
    expect(nl.nNand).toBe(8);
    const got = await readAll(rpc, [0, 1, 2, 3].map((s) => p.step(102, toHex(Uint8Array.of(s)), '0x')));
    expect(got).toEqual(
      [0, 1, 2, 3].map((s) => {
        const l = step(nl, Uint8Array.of(s), []);
        return { newState: toHex(l.newState), outputs: toHex(l.outputs) };
      }),
    );
  });

  test('a REF to an address that is not a registered processor is ill-formed', async () => {
    // one REF record pointing at Multicall3 (a contract, but not a TapeOut processor)
    const rec = new Uint8Array(31);
    rec[0] = 2;
    rec.set(toBytes('0xcA11bde05977b3631167028862bE2a173976CA11'), 1);
    rec[28] = 1; // id = 1
    rec[30] = 1; // nOuts = 1
    await expect(load(rec, 0, 1, fetcher)).rejects.toMatchObject({ code: 'ref-unresolved' });
  });
});
