// Read-only checks against X Layer mainnet (chain 196). Set SKIP_LIVE=1 to skip.
// Only eth_call, eth_chainId and eth_blockNumber are used; no transaction is ever sent.

import { describe, expect, test } from 'vitest';
import { blockNumber, CallError, createRpc, factory, MULTICALL3, processor, read, readAll, transistors } from '../src/index.ts';
import { checksumAddress } from '../src/keccak.ts';

const RPC = ['https://rpc.xlayer.tech', 'https://xlayerrpc.okx.com'];
const FACTORY = '0x1f09daefa827f02cbb40967cc91b259763760761';
const LOTEGATE = '0xAa13ae45b0B2D52f210Ad7Ef12997113a0ebAF21';
const TRIVIUM = '0x933FC3AA0c387CB8B6B1D22a2Ec3E2B5eeCfDb5a';

const live = process.env.SKIP_LIVE ? describe.skip : describe;

live('X Layer mainnet, read-only', { timeout: 120_000 }, () => {
  const rpc = createRpc(RPC);
  const f = factory(FACTORY);

  test('chain id is 196 on both endpoints', async () => {
    for (const url of RPC) expect(await createRpc([url]).send('eth_chainId')).toBe('0xc4');
  });

  test('factory: cpuCount and cpuAt(0)', async () => {
    const count = await read(rpc, f.cpuCount());
    expect(count).toBeGreaterThanOrEqual(275n);
    const p0 = await read(rpc, f.cpuAt(0));
    expect(checksumAddress(p0)).toBe('0x839bdD6fa7A66416A609A735e11DE5411B98574e');
  });

  test('a processor and its transistor contract, in two multicalls', async () => {
    const p = processor(TRIVIUM);
    const [name, symbol, nextId, tr, registered, stranger] = await readAll(rpc, [
      p.name(),
      p.symbol(),
      p.nextId(),
      p.transistors(),
      f.isCPU(TRIVIUM),
      f.isCPU(MULTICALL3),
    ] as const);
    expect(name).toBe('Trivium');
    expect(symbol).toBe('CPU');
    expect(nextId).toBeGreaterThanOrEqual(1n);
    expect(registered).toBe(true);
    expect(stranger).toBe(false);
    expect(typeof tr).toBe('string');

    const t = transistors(tr as string);
    const [cap, price, minted, story, cpuName, cpuSymbol, creator] = await readAll(rpc, [
      t.supplyCap(),
      t.mintPrice(),
      t.minted(),
      t.story(),
      t.cpuName(),
      t.cpuSymbol(),
      t.creator(),
    ] as const);
    expect(typeof cap).toBe('bigint');
    expect(typeof price).toBe('bigint');
    expect(minted as bigint).toBeLessThanOrEqual(cap as bigint);
    expect(typeof story).toBe('string');
    expect(cpuName).toBe('Trivium');
    expect(cpuSymbol).toBe('CPU');
    expect(creator).toMatch(/^0x[0-9a-f]{40}$/);
  });

  test('circuit facts of the two large test circuits', async () => {
    const [a, b, ownerA, ownerB] = await readAll(rpc, [
      processor(LOTEGATE).circuitInfo(3),
      processor(TRIVIUM).circuitInfo(1),
      processor(LOTEGATE).ownerOf(3),
      processor(TRIVIUM).ownerOf(1),
    ] as const);
    expect(a).toEqual({ nIn: 133, nOut: 199, nState: 243, gateCount: 4863 });
    expect(b).toEqual({ nIn: 161, nOut: 1, nState: 288, gateCount: 3035 });
    expect(ownerA).toMatch(/^0x[0-9a-f]{40}$/);
    expect(ownerB).toMatch(/^0x[0-9a-f]{40}$/);
  });

  test('nextId is the highest existing circuit id on X Layer (not the next free one)', async () => {
    for (const cpu of [TRIVIUM, LOTEGATE]) {
      const p = processor(cpu);
      const next = await read(rpc, p.nextId());
      const [last, beyond, zero] = await readAll(rpc, [p.circuitInfo(next), p.circuitInfo(next + 1n), p.circuitInfo(0)] as const);
      expect(last).not.toBeInstanceOf(Error);
      expect(beyond).toBeInstanceOf(CallError);
      expect((beyond as CallError).message).toBe('no circuit');
      expect((zero as CallError).message).toBe('no circuit');
    }
  });

  test('every circuit of processor 0 in one HTTP request (circuitInfo + ownerOf through Multicall3)', async () => {
    const p0 = await read(rpc, f.cpuAt(0));
    const p = processor(p0);
    const next = Number(await read(rpc, p.nextId()));
    expect(next).toBeGreaterThanOrEqual(103);
    const calls = [];
    for (let id = 1; id <= next; id++) calls.push(p.circuitInfo(id), p.ownerOf(id));
    const out = await readAll(rpc, calls);
    expect(out.length).toBe(2 * next);
    expect(out.filter((x) => x instanceof Error)).toEqual([]);
    expect(out[0]).toEqual({ nIn: 2, nOut: 1, nState: 0, gateCount: 4 });
    expect(out[6]).toEqual({ nIn: 0, nOut: 1, nState: 2, gateCount: 10 });
  });

  test('netlist(3) of LoteGate is 33,312 bytes; eval on a circuit with state reverts with the documented reason', async () => {
    const p = processor(LOTEGATE);
    const hex = await read(rpc, p.netlist(3));
    expect((hex.length - 2) / 2).toBe(33312);
    const err = await read(rpc, p.eval(3, '0x')).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(CallError);
    expect((err as CallError).message).toBe('has latch: use step');
  });

  test('a circuit that does not exist reverts with "no circuit", directly and through Multicall3', async () => {
    const p = processor(TRIVIUM);
    const direct = await read(rpc, p.circuitInfo(999999)).catch((e: unknown) => e);
    expect(direct).toBeInstanceOf(CallError);
    expect((direct as CallError).message).toBe('no circuit');
    const [viaMulticall, good] = await readAll(rpc, [p.circuitInfo(999999), p.circuitInfo(1)] as const);
    expect(viaMulticall).toBeInstanceOf(CallError);
    expect((viaMulticall as CallError).message).toBe('no circuit');
    expect(good).toEqual({ nIn: 161, nOut: 1, nState: 288, gateCount: 3035 });
  });

  test('step on the all-zero state returns canonical lengths', async () => {
    const r = await read(rpc, processor(TRIVIUM).step(1, '0x', '0x'));
    expect(r.newState).toBe('0x' + '00'.repeat(36));
    expect(r.outputs).toBe('0x00');
  });

  test('getBlockNumber inside a multicall reports the block the other calls ran at', async () => {
    const head = Number(await rpc.send('eth_blockNumber'));
    const [block, name] = await readAll(rpc, [blockNumber(), processor(TRIVIUM).name()] as const);
    expect(name).toBe('Trivium');
    expect(typeof block).toBe('bigint');
    // within a couple of minutes of the head read just before (X Layer makes a block about every second)
    expect(Math.abs(Number(block) - head)).toBeLessThan(300);
  });

  test('failover: a dead first endpoint is skipped', async () => {
    const flaky = createRpc(['https://rpc.invalid.example', ...RPC], { timeout: 8000 });
    expect(await flaky.send('eth_chainId')).toBe('0xc4');
    expect(flaky.current()).not.toBe('https://rpc.invalid.example');
  });
});
