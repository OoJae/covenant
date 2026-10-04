// The hand-written codec against viem (test-only oracle; viem is never in the production bundle).

import { describe, expect, test } from 'vitest';
import {
  decodeFunctionResult,
  encodeAbiParameters,
  encodeErrorResult,
  encodeFunctionData,
  encodeFunctionResult,
  parseAbi,
  toFunctionSelector,
  type Hex,
} from 'viem';
import {
  blockNumber,
  CallError,
  decAggregate3,
  decCircuitInfo,
  decStep,
  encAggregate3,
  factory,
  processor,
  revertReason,
  toBytes,
  toHex,
  transistors,
} from '../src/index.ts';
import { keccak256Hex } from '../src/keccak.ts';
import { SIGNATURES, type FunctionName } from '../src/signatures.ts';

const abi = parseAbi([
  'function cpuCount() view returns (uint256)',
  'function cpuAt(uint256 i) view returns (address)',
  'function isCPU(address cpu) view returns (bool)',
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function nextId() view returns (uint256)',
  'function ownerOf(uint256 id) view returns (address)',
  'function circuitInfo(uint256 id) view returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount)',
  'function netlist(uint256 id) view returns (bytes)',
  'function eval(uint256 id, bytes inputs) view returns (bytes)',
  'function step(uint256 id, bytes state, bytes inputs) view returns (bytes newState, bytes outputs)',
  'function transistors() view returns (address)',
  'function supplyCap() view returns (uint256)',
  'function mintPrice() view returns (uint256)',
  'function minted() view returns (uint256)',
  'function story() view returns (string)',
  'function cpuName() view returns (string)',
  'function cpuSymbol() view returns (string)',
  'function creator() view returns (address)',
  'struct Call3 { address target; bool allowFailure; bytes callData; }',
  'struct Result { bool success; bytes returnData; }',
  'function aggregate3(Call3[] calls) payable returns (Result[] returnData)',
]);

// Deterministic pseudo-random data (xorshift32), so a failure reproduces.
let seed = 0x9e3779b9;
const rnd = (): number => {
  seed ^= seed << 13;
  seed ^= seed >>> 17;
  seed ^= seed << 5;
  return seed >>> 0;
};
const randomHex = (bytes: number): Hex => {
  let s = '0x';
  for (let i = 0; i < bytes; i++) s += (rnd() & 255).toString(16).padStart(2, '0');
  return s as Hex;
};
const randomAddress = (): Hex => randomHex(20);

const A = '0x1f09DAeFA827f02CBb40967cc91b259763760761' as const;
const lower = (h: string): string => h.toLowerCase();

describe('selectors', () => {
  const names = Object.keys(SIGNATURES) as FunctionName[];

  for (const name of names) {
    const [sig, sel] = SIGNATURES[name];
    test(`${sig} = 0x${sel}`, () => {
      expect(toFunctionSelector('function ' + sig)).toBe('0x' + sel);
      expect(keccak256Hex(new TextEncoder().encode(sig)).slice(0, 10)).toBe('0x' + sel);
    });
  }

  test('every builder emits the selector listed for it', () => {
    const f = factory(A);
    const p = processor(A);
    const t = transistors(A);
    const built: Record<Exclude<FunctionName, 'aggregate3'>, string> = {
      getBlockNumber: blockNumber().data,
      cpuCount: f.cpuCount().data,
      cpuAt: f.cpuAt(0).data,
      isCPU: f.isCPU(A).data,
      name: p.name().data,
      symbol: p.symbol().data,
      nextId: p.nextId().data,
      ownerOf: p.ownerOf(1).data,
      circuitInfo: p.circuitInfo(1).data,
      netlist: p.netlist(1).data,
      eval: p.eval(1, '0x').data,
      step: p.step(1, '0x', '0x').data,
      transistors: p.transistors().data,
      supplyCap: t.supplyCap().data,
      mintPrice: t.mintPrice().data,
      minted: t.minted().data,
      story: t.story().data,
      cpuName: t.cpuName().data,
      cpuSymbol: t.cpuSymbol().data,
      creator: t.creator().data,
    };
    for (const [name, data] of Object.entries(built)) {
      expect(data.slice(0, 10), name).toBe('0x' + SIGNATURES[name as FunctionName][1]);
    }
    expect(encAggregate3([]).slice(0, 10)).toBe('0x' + SIGNATURES.aggregate3[1]);
    expect(Object.keys(built).length + 1).toBe(names.length);
  });

  test('TAP-20 section 6 lists the same selectors', () => {
    const tap20: Partial<Record<FunctionName, string>> = {
      nextId: '61b8ce8c',
      circuitInfo: '084d60f1',
      netlist: '3fc4be56',
      eval: '934d06ea',
      step: 'e8281a1a',
      cpuCount: 'a94da8a7',
      cpuAt: '4bc7cbbd',
    };
    for (const [name, sel] of Object.entries(tap20)) expect(SIGNATURES[name as FunctionName][1]).toBe(sel);
  });
});

describe('calldata equals viem encodeFunctionData', () => {
  test('calls without arguments', () => {
    const p = processor(A);
    const t = transistors(A);
    const f = factory(A);
    const cases: [string, { data: string; to: string }][] = [
      ['cpuCount', f.cpuCount()],
      ['name', p.name()],
      ['symbol', p.symbol()],
      ['nextId', p.nextId()],
      ['transistors', p.transistors()],
      ['supplyCap', t.supplyCap()],
      ['mintPrice', t.mintPrice()],
      ['minted', t.minted()],
      ['story', t.story()],
      ['cpuName', t.cpuName()],
      ['cpuSymbol', t.cpuSymbol()],
      ['creator', t.creator()],
    ];
    for (const [fn, c] of cases) {
      expect(c.to).toBe(A);
      expect(c.data).toBe(encodeFunctionData({ abi, functionName: fn as 'name' }));
    }
  });

  test('uint256 and address arguments', () => {
    const p = processor(A);
    const f = factory(A);
    for (const id of [0n, 1n, 3n, 255n, 256n, 2n ** 64n - 1n, 2n ** 256n - 1n]) {
      expect(f.cpuAt(id).data).toBe(encodeFunctionData({ abi, functionName: 'cpuAt', args: [id] }));
      expect(p.ownerOf(id).data).toBe(encodeFunctionData({ abi, functionName: 'ownerOf', args: [id] }));
      expect(p.circuitInfo(id).data).toBe(encodeFunctionData({ abi, functionName: 'circuitInfo', args: [id] }));
      expect(p.netlist(id).data).toBe(encodeFunctionData({ abi, functionName: 'netlist', args: [id] }));
    }
    expect(p.ownerOf(7).data).toBe(encodeFunctionData({ abi, functionName: 'ownerOf', args: [7n] }));
    for (let i = 0; i < 20; i++) {
      const a = randomAddress();
      expect(f.isCPU(a).data).toBe(encodeFunctionData({ abi, functionName: 'isCPU', args: [a] }));
    }
    // a checksummed address encodes the same as its lower-case form
    expect(f.isCPU(A).data).toBe(f.isCPU(lower(A)).data);
  });

  test('eval(uint256,bytes) for every input length 0..70', () => {
    const p = processor(A);
    for (let n = 0; n <= 70; n++) {
      const inputs = randomHex(n);
      const id = BigInt(rnd());
      expect(p.eval(id, inputs).data).toBe(encodeFunctionData({ abi, functionName: 'eval', args: [id, inputs] }));
    }
  });

  test('step(uint256,bytes,bytes) for state and input lengths 0..70', () => {
    const p = processor(A);
    for (let i = 0; i < 400; i++) {
      const state = randomHex(rnd() % 71);
      const inputs = randomHex(rnd() % 71);
      const id = BigInt(rnd() % 1000);
      expect(p.step(id, state, inputs).data).toBe(
        encodeFunctionData({ abi, functionName: 'step', args: [id, state, inputs] }),
      );
    }
    // the shapes used on the live circuits: 31/17 bytes (LoteGate #3) and 36/21 bytes (Trivium #1)
    for (const [s, x] of [[31, 17], [36, 21], [0, 0], [32, 12]]) {
      const state = randomHex(s);
      const inputs = randomHex(x);
      expect(p.step(3, state, inputs).data).toBe(encodeFunctionData({ abi, functionName: 'step', args: [3n, state, inputs] }));
    }
  });

  test('bytes arguments are accepted with or without 0x', () => {
    const p = processor(A);
    expect(p.eval(1, 'abcd').data).toBe(p.eval(1, '0xabcd').data);
    expect(p.step(1, '', '').data).toBe(p.step(1, '0x', '0x').data);
  });
});

describe('return data decodes like viem', () => {
  const p = processor(A);
  const t = transistors(A);
  const f = factory(A);

  test('uint256, address, bool', () => {
    for (const v of [0n, 1n, 275n, 67108864n, 20000000000000n, 2n ** 256n - 1n]) {
      const ret = encodeFunctionResult({ abi, functionName: 'cpuCount', result: v });
      expect(f.cpuCount().decode(ret)).toBe(v);
      expect(t.supplyCap().decode(ret)).toBe(v);
      expect(t.mintPrice().decode(ret)).toBe(v);
      expect(t.minted().decode(ret)).toBe(v);
      expect(p.nextId().decode(ret)).toBe(v);
    }
    for (let i = 0; i < 20; i++) {
      const a = randomAddress();
      const ret = encodeFunctionResult({ abi, functionName: 'cpuAt', result: a });
      expect(f.cpuAt(0).decode(ret)).toBe(a);
      expect(p.ownerOf(1).decode(ret)).toBe(a);
      expect(p.transistors().decode(ret)).toBe(a);
      expect(t.creator().decode(ret)).toBe(a);
    }
    expect(f.isCPU(A).decode(encodeFunctionResult({ abi, functionName: 'isCPU', result: true }))).toBe(true);
    expect(f.isCPU(A).decode(encodeFunctionResult({ abi, functionName: 'isCPU', result: false }))).toBe(false);
  });

  test('strings, including empty, multi-word and non-ASCII', () => {
    const long = 'Supply 67,108,864 at 0.00002 OKB. '.repeat(40);
    for (const s of ['', 'Covenant', 'CVNT', 'OnlyTestXLayer', 'x'.repeat(31), 'x'.repeat(32), 'x'.repeat(33), long, 'USD₮0 · 晶体管 · ünïcödé']) {
      const ret = encodeFunctionResult({ abi, functionName: 'story', result: s });
      expect(t.story().decode(ret)).toBe(s);
      expect(t.cpuName().decode(ret)).toBe(s);
      expect(t.cpuSymbol().decode(ret)).toBe(s);
      expect(p.name().decode(ret)).toBe(s);
      expect(p.symbol().decode(ret)).toBe(s);
    }
  });

  test('bytes of every length 0..70 and a 33 KB netlist', () => {
    for (const n of [...Array.from({ length: 71 }, (_, i) => i), 33312]) {
      const b = randomHex(n);
      const ret = encodeFunctionResult({ abi, functionName: 'netlist', result: b });
      expect(p.netlist(1).decode(ret)).toBe(b);
      expect(p.eval(1, '0x').decode(ret)).toBe(b);
    }
  });

  test('circuitInfo', () => {
    for (const info of [[133, 199, 243, 4863], [161, 1, 288, 3035], [0, 1, 2, 10], [65536, 65536, 16777216, 4294967295]] as const) {
      const ret = encodeFunctionResult({ abi, functionName: 'circuitInfo', result: info });
      expect(decCircuitInfo(ret)).toEqual({ nIn: info[0], nOut: info[1], nState: info[2], gateCount: info[3] });
      expect(p.circuitInfo(1).decode(ret)).toEqual(decCircuitInfo(ret));
    }
  });

  test('step returns (bytes newState, bytes outputs)', () => {
    for (let i = 0; i < 200; i++) {
      const newState = randomHex(rnd() % 71);
      const outputs = randomHex(rnd() % 71);
      const ret = encodeFunctionResult({ abi, functionName: 'step', result: [newState, outputs] });
      expect(decStep(ret)).toEqual({ newState, outputs });
      expect(p.step(1, '0x', '0x').decode(ret)).toEqual({ newState, outputs });
    }
  });

  test('truncated or empty return data throws instead of decoding to garbage', () => {
    expect(() => f.cpuCount().decode('0x')).toThrow('too short');
    expect(() => p.name().decode('0x')).toThrow('too short');
    expect(() => p.circuitInfo(1).decode('0x' + '00'.repeat(96))).toThrow('too short');
    const ret = encodeFunctionResult({ abi, functionName: 'netlist', result: randomHex(100) });
    expect(() => p.netlist(1).decode(ret.slice(0, ret.length - 80))).toThrow('too short');
    expect(() => decStep('0x' + '00'.repeat(31))).toThrow('too short');
  });
});

describe('Multicall3 aggregate3', () => {
  test('calldata equals viem for 0..40 random sub-calls', () => {
    for (let n = 0; n <= 40; n++) {
      const calls = Array.from({ length: n }, () => ({ to: randomAddress(), data: randomHex(rnd() % 150) }));
      for (const allowFailure of [true, false]) {
        const want = encodeFunctionData({
          abi,
          functionName: 'aggregate3',
          args: [calls.map((c) => ({ target: c.to, allowFailure, callData: c.data }))],
        });
        expect(encAggregate3(calls, allowFailure)).toBe(want);
      }
    }
  });

  test('return data decodes like viem', () => {
    for (let n = 0; n <= 40; n++) {
      const results = Array.from({ length: n }, () => ({ success: (rnd() & 1) === 1, returnData: randomHex(rnd() % 200) }));
      const ret = encodeFunctionResult({ abi, functionName: 'aggregate3', result: results });
      expect(decAggregate3(ret)).toEqual(results.map((r) => ({ success: r.success, data: r.returnData })));
      expect(decodeFunctionResult({ abi, functionName: 'aggregate3', data: ret })).toEqual(results);
    }
  });

  test('truncated aggregate3 data throws', () => {
    const ret = encodeFunctionResult({ abi, functionName: 'aggregate3', result: [{ success: true, returnData: randomHex(64) }] });
    expect(() => decAggregate3(ret.slice(0, ret.length - 40))).toThrow('too short');
    expect(() => decAggregate3('0x')).toThrow('too short');
  });
});

describe('revert data', () => {
  test('Error(string), Panic(uint256), raw and empty', () => {
    const err = encodeErrorResult({ abi: parseAbi(['error Error(string)']), errorName: 'Error', args: ['has latch: use step'] });
    expect(revertReason(err)).toBe('has latch: use step');
    expect(revertReason(encodeErrorResult({ abi: parseAbi(['error Error(string)']), errorName: 'Error', args: ['no circuit'] }))).toBe('no circuit');
    const panic = ('0x4e487b71' + encodeAbiParameters([{ type: 'uint256' }], [0x32n]).slice(2)) as Hex;
    expect(revertReason(panic)).toBe('panic 0x32');
    expect(revertReason('0xdeadbeef')).toBe('reverted with 0xdeadbeef');
    expect(revertReason('0x')).toBe('reverted');
    expect(revertReason(undefined)).toBe('reverted');
    expect(revertReason('0x08c379a0')).toBe('reverted with 0x08c379a0');
  });

  test('CallError keeps the raw data', () => {
    const e = new CallError('no circuit', '0x1234');
    expect(e).toBeInstanceOf(Error);
    expect(e.data).toBe('0x1234');
    expect(e.name).toBe('CallError');
  });
});

describe('hex helpers', () => {
  test('toBytes and toHex round trip', () => {
    for (let n = 0; n < 50; n++) {
      const h = randomHex(n);
      expect(toHex(toBytes(h))).toBe(h);
    }
    expect(Array.from(toBytes('0x00ff10'))).toEqual([0, 255, 16]);
    expect(toHex(Uint8Array.of(0, 255, 16))).toBe('0x00ff10');
    expect(toHex([])).toBe('0x');
  });
});
