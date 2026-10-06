// The kernel, factory, Lens, Fab and IGNIX descriptors against viem (test-only oracle).

import { describe, expect, test } from 'vitest';
import { encodeFunctionData, encodeFunctionResult, parseAbi, toFunctionSelector, type Hex } from 'viem';
import { keccak256Hex } from '../src/keccak.ts';
import {
  beaconImpl,
  erc20,
  fab,
  fabSnapshot,
  ignix,
  kernel,
  kernelFactory,
  kernelFactoryV2,
  kernelV2,
  KERNEL_SIGNATURES,
  lens,
  multicallViews,
  SHADOW_START,
  teamRegistry,
  ownerOf,
  safe,
  tether,
} from '../src/kernel.ts';

const RECORD = 'uint32 epoch, uint40 time, uint16 clampBits, uint8 flags, bytes12 inputs, bytes14 outputs, bytes32 stateAfter, uint128 inflow, uint128 reserveBefore, uint128 allow, uint128 buyDecided, uint128 buyExecuted, uint128 tokensOut, uint128 nativeIn';
const ENVELOPE = 'address launcher, uint32 epochLen, address allowancePayee, uint16 capT, uint16 capV, uint16 allowCumBps, uint16 ceilMax, uint16 relMax, uint16 floorRel, uint16 floorMin, uint16 fallbackEpochs, uint16 fbAllow, bool buyEnabled, address sink';
const GLOBALS = 'address manager, address v2Router, address wokb, address factory, address circuits, address fab, address sealedVM, address beacon, address impl0, bytes32 impl0Hash, address snapshot, bytes32 netlistHash, uint256 chipId, uint32 nState, uint32 gateCount, uint32 netlistLen, uint256 stepFloor, uint256 sealedFloor';
const REPLAY = 'bool ok, bool ran, bool outputsMatch, bool stateMatch, bool amountsMatch, bool inputsMatch, bool sealedUsed, bytes14 outputs, bytes32 stateAfter';
const TOTALS = 'uint256 inflow, uint256 allow, uint256 buy, uint256 reserveEnd';
const STEP = 'uint32 n, bool ran, bytes12 inputs, bytes14 outputs, uint16 clampBits, uint128 allow, uint128 buyDecided, uint128 reserveAfter';
const CURVE = 'address creator, uint16 buyFeeBps, uint16 sellFeeBps, uint16 taxBuyBps, uint16 taxSellBps, address quote, uint16 snipeStartBps, uint16 snipeMins, uint64 createdAt, uint128 vQuote, uint128 vToken, uint128 sold, uint128 collected, uint128 sellable, uint128 reserve, bytes32 poolId';

const abi = parseAbi([
  `struct Record { ${RECORD}; }`.replaceAll(', ', '; '),
  `struct Envelope { ${ENVELOPE}; }`.replaceAll(', ', '; '),
  `struct Globals { ${GLOBALS}; }`.replaceAll(', ', '; '),
  `struct Replay { ${REPLAY}; }`.replaceAll(', ', '; '),
  `struct Totals { ${TOTALS}; }`.replaceAll(', ', '; '),
  'struct Counterfactual { Totals chip; uint256 chipBuyExecuted; Totals fixedSplit; Totals alwaysBuy; }',
  'struct CfCursor { uint256 reserve; uint256 allowPaid; bool grad; }',
  'struct ShadowCursor { bytes32 state; uint256 reserve; uint256 allowPaid; bool grad; }',
  `struct ShadowStep { ${STEP}; }`.replaceAll(', ', '; '),
  'struct Preflight { bool sealedModeNow; bool tapeoutRan; bool sealedRan; bool agree; uint256 tapeoutGas; uint256 sealedGas; uint256 stepFloor; uint256 sealedFloor; uint256 minSettleGas; }',
  `struct CurveToken { ${CURVE}; }`.replaceAll(', ', '; '),
  'function token() view returns (address)',
  'function vault() view returns (address)',
  'function chipId() view returns (uint256)',
  'function count() view returns (uint32)',
  'function records(uint32 n) view returns (Record)',
  'function cums(uint32 n) view returns (uint128 cumInflow, uint128 allowPaidCum)',
  'function state() view returns (bytes32)',
  'function epochNow() view returns (uint32)',
  'function lastEpoch() view returns (uint32)',
  'function lastStepEpoch() view returns (uint32)',
  'function bindTime() view returns (uint40)',
  'function reserve() view returns (uint256)',
  'function creditOf(address payee, address asset) view returns (uint256)',
  'function totalCredits(address asset) view returns (uint256)',
  'function lockedTokens() view returns (uint256)',
  'function burnedTokens() view returns (uint128)',
  'function graduated() view returns (bool)',
  'function pair() view returns (address)',
  'function envelope() view returns (Envelope)',
  'function evaluator() view returns (address vm, bool sealedMode)',
  'function minSettleGas() view returns (uint256)',
  'function globals() view returns (Globals)',
  'function cumInflow() view returns (uint128)',
  'function allowPaidCum() view returns (uint128)',
  'function tokenSupply() view returns (uint256)',
  'function isKernel(address) view returns (bool)',
  'function kernelOf(address) view returns (address)',
  'function pinsLive() view returns (bool)',
  'function kernelImpl() view returns (address)',
  'function fab() view returns (address)',
  'function impl0() view returns (address)',
  'function impl0Hash() view returns (bytes32)',
  'function beacon() view returns (address)',
  'function FACTORY() view returns (address)',
  'function replay(address kernel, uint32 n) view returns (Replay)',
  'function replayOn(address kernel, uint32 n, bool useSealed) view returns (Replay)',
  'function counterfactual(address kernel, uint32 fromN, uint32 toN) view returns (Counterfactual curve, Counterfactual graduated, CfCursor next)',
  'function counterfactualFrom(address kernel, uint32 fromN, uint32 toN, CfCursor cur) view returns (Counterfactual curve, Counterfactual graduated, CfCursor next)',
  'function stateMatters(address kernel, uint32 n) view returns (bool matters, bytes14 withState, bytes14 withZeroState)',
  'function stateMattersVs(address kernel, uint32 n, bytes32 otherState) view returns (bool matters, bytes14 withState, bytes14 withOtherState)',
  'function preflight(address kernel) view returns (Preflight)',
  'function shadowChip(address kernel, uint256 chipId, uint32 fromN, uint32 toN, ShadowCursor cur) view returns (ShadowStep[] steps, ShadowCursor next, uint32 nextN)',
  'function shadowSnapshot(address kernel, address snapshot, uint32 fromN, uint32 toN, ShadowCursor cur) view returns (ShadowStep[] steps, ShadowCursor next, uint32 nextN)',
  'function chipInfo(uint256 chipId) view returns (address snapshot, bytes32 netlistHash, uint32 nState, uint32 gateCount, address author, bytes32 manifestHash)',
  'function isChip(uint256 chipId) view returns (bool)',
  'function snapshot(uint256 chipId) view returns (bytes)',
  'function CIRCUITS() view returns (address)',
  'function vaultOf(address token) view returns (address)',
  'function tokens(address token) view returns (CurveToken)',
  'function RECIPIENT() view returns (address)',
  'function TOKEN() view returns (address)',
  'function QUOTE() view returns (address)',
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
  'function totalSupply() view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function implementation() view returns (address)',
  'function at(uint256 i) view returns (address wallet, string role, uint256 timestamp)',
  'function getCurrentBlockTimestamp() view returns (uint256)',
  'function getEthBalance(address) view returns (uint256)',
  'function owner() view returns (address)',
  'function getThreshold() view returns (uint256)',
  'function getOwners() view returns (address[])',
]);

let seed = 0x1badb002;
const rnd = (): number => {
  seed ^= seed << 13;
  seed ^= seed >>> 17;
  seed ^= seed << 5;
  return seed >>> 0;
};
const hex = (bytes: number): Hex => {
  let s = '0x';
  for (let i = 0; i < bytes; i++) s += (rnd() & 255).toString(16).padStart(2, '0');
  return s as Hex;
};
const uint = (bits: number): bigint => BigInt(hex(Math.ceil(bits / 8))) & ((1n << BigInt(bits)) - 1n);
const address = (): Hex => hex(20);
const K = '0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356';
const lower = (h: string): string => h.toLowerCase();

describe('selectors', () => {
  test('every selector is keccak256(signature)[:4], by viem and by our keccak', () => {
    for (const [name, [sig, sel]] of Object.entries(KERNEL_SIGNATURES)) {
      expect(toFunctionSelector(`function ${sig}`), name).toBe('0x' + sel);
      expect(keccak256Hex(new TextEncoder().encode(sig)).slice(2, 10), name).toBe(sel);
    }
  });
});

describe('calldata equals viem', () => {
  const k = kernel(K);
  const L = lens(K);
  test('kernel, factory, Lens, Fab, IGNIX, ERC-20', () => {
    for (let i = 0; i < 20; i++) {
      const n = Number(uint(32));
      const a = address();
      const b = address();
      const cases: [string, Hex, unknown[]][] = [
        [k.records(n).data, 'records' as never, [n]],
        [k.cums(n).data, 'cums' as never, [n]],
        [k.creditOf(a, b).data, 'creditOf' as never, [a, b]],
        [k.totalCredits(a).data, 'totalCredits' as never, [a]],
        [kernelFactory(K).isKernel(a).data, 'isKernel' as never, [a]],
        [kernelFactory(K).kernelOf(a).data, 'kernelOf' as never, [a]],
        [L.replay(a, n).data, 'replay' as never, [a, n]],
        [L.replayOn(a, n, i % 2 === 0).data, 'replayOn' as never, [a, n, i % 2 === 0]],
        [L.counterfactual(a, n, n + 1).data, 'counterfactual' as never, [a, n, n + 1]],
        [L.stateMatters(a, n).data, 'stateMatters' as never, [a, n]],
        [L.preflight(a).data, 'preflight' as never, [a]],
        [fab(K).chipInfo(BigInt(n)).data, 'chipInfo' as never, [BigInt(n)]],
        [fab(K).isChip(BigInt(n)).data, 'isChip' as never, [BigInt(n)]],
        [fabSnapshot(K, BigInt(n)).data, 'snapshot' as never, [BigInt(n)]],
        [ignix.vaultOf(K, a).data, 'vaultOf' as never, [a]],
        [ignix.tokens(K, a).data, 'tokens' as never, [a]],
        [erc20(K).balanceOf(a).data, 'balanceOf' as never, [a]],
        [teamRegistry(K).at(BigInt(n)).data, 'at' as never, [BigInt(n)]],
        [multicallViews(K).ethBalance(a).data, 'getEthBalance' as never, [a]],
      ];
      for (const [ours, fn, args] of cases) {
        expect(ours, fn).toBe(lower(encodeFunctionData({ abi, functionName: fn as never, args: args as never })));
      }
      const other = hex(32);
      expect(L.stateMattersVs(a, n, other).data).toBe(lower(encodeFunctionData({ abi, functionName: 'stateMattersVs', args: [a, n, other] })));
      const cur = { reserve: uint(128), allowPaid: uint(100), grad: i % 3 === 0 };
      expect(L.counterfactualFrom(a, 1, n, cur).data).toBe(lower(encodeFunctionData({ abi, functionName: 'counterfactualFrom', args: [a, 1, n, cur] })));
      const sc = { state: hex(32), reserve: uint(128), allowPaid: uint(64), grad: i % 2 === 1 };
      expect(L.shadowChip(a, 7n, 1, n, sc).data).toBe(lower(encodeFunctionData({ abi, functionName: 'shadowChip', args: [a, 7n, 1, n, sc] })));
      expect(L.shadowSnapshot(a, b, 1, n, sc).data).toBe(lower(encodeFunctionData({ abi, functionName: 'shadowSnapshot', args: [a, b, 1, n, sc] })));
    }
    const zero = { state: ('0x' + '00'.repeat(32)) as Hex, reserve: 0n, allowPaid: 0n, grad: false };
    expect(L.shadowChip(K, 3n, 1, 5).data).toBe(lower(encodeFunctionData({ abi, functionName: 'shadowChip', args: [K, 3n, 1, 5, zero] })));
    expect(SHADOW_START.state).toBe(zero.state);
    // the argument-free views
    for (const [ours, fn] of [
      [k.token(), 'token'],
      [k.globals(), 'globals'],
      [k.envelope(), 'envelope'],
      [k.evaluator(), 'evaluator'],
      [kernelFactory(K).pinsLive(), 'pinsLive'],
      [beaconImpl(K), 'implementation'],
      [multicallViews(K).timestamp(), 'getCurrentBlockTimestamp'],
    ] as const) {
      expect(ours.data, fn).toBe(encodeFunctionData({ abi, functionName: fn as never }));
    }
  });
});

describe('decoders equal viem', () => {
  const k = kernel(K);
  const L = lens(K);
  const enc = (fn: string, result: unknown): Hex => encodeFunctionResult({ abi, functionName: fn as never, result: result as never });

  test('records, envelope, globals', () => {
    for (let i = 0; i < 50; i++) {
      const rec = {
        epoch: Number(uint(32)),
        time: Number(uint(40)),
        clampBits: Number(uint(16)),
        flags: Number(uint(8)),
        inputs: hex(12),
        outputs: hex(14),
        stateAfter: hex(32),
        inflow: uint(128),
        reserveBefore: uint(128),
        allow: uint(128),
        buyDecided: uint(128),
        buyExecuted: uint(128),
        tokensOut: uint(128),
        nativeIn: uint(128),
      };
      expect(k.records(1).decode(enc('records', rec))).toEqual(rec);

      const env = {
        launcher: address(),
        epochLen: Number(uint(32)),
        allowancePayee: address(),
        capT: Number(uint(16)),
        capV: Number(uint(16)),
        allowCumBps: Number(uint(16)),
        ceilMax: Number(uint(16)),
        relMax: Number(uint(16)),
        floorRel: Number(uint(16)),
        floorMin: Number(uint(16)),
        fallbackEpochs: Number(uint(16)),
        fbAllow: Number(uint(16)),
        buyEnabled: i % 2 === 0,
        sink: address(),
      };
      expect(k.envelope().decode(enc('envelope', env))).toEqual(env);

      const g = {
        manager: address(),
        v2Router: address(),
        wokb: address(),
        factory: address(),
        circuits: address(),
        fab: address(),
        sealedVM: address(),
        beacon: address(),
        impl0: address(),
        impl0Hash: hex(32),
        snapshot: address(),
        netlistHash: hex(32),
        chipId: uint(256),
        nState: Number(uint(32)),
        gateCount: Number(uint(32)),
        netlistLen: Number(uint(32)),
        stepFloor: uint(64),
        sealedFloor: uint(64),
      };
      expect(k.globals().decode(enc('globals', g))).toEqual(g);

      const c = { cumInflow: uint(128), allowPaidCum: uint(128) };
      expect(k.cums(1).decode(enc('cums', [c.cumInflow, c.allowPaidCum]))).toEqual(c);
      const ev = { vm: address(), sealedMode: i % 3 === 0 };
      expect(k.evaluator().decode(enc('evaluator', [ev.vm, ev.sealedMode]))).toEqual(ev);
      const st = hex(32);
      expect(k.state().decode(enc('state', st))).toBe(st);
    }
  });

  test('Lens: replay, counterfactual, stateMatters, preflight, shadow pages of 0 to 6 steps', () => {
    for (let i = 0; i < 30; i++) {
      const b = (): boolean => (rnd() & 1) === 1;
      const rp = { ok: b(), ran: b(), outputsMatch: b(), stateMatch: b(), amountsMatch: b(), inputsMatch: b(), sealedUsed: b(), outputs: hex(14), stateAfter: hex(32) };
      expect(L.replay(K, 1).decode(enc('replay', rp))).toEqual(rp);

      const tot = () => ({ inflow: uint(128), allow: uint(128), buy: uint(128), reserveEnd: uint(128) });
      const cfv = () => ({ chip: tot(), chipBuyExecuted: uint(128), fixedSplit: tot(), alwaysBuy: tot() });
      const out = { curve: cfv(), graduated: cfv(), next: { reserve: uint(128), allowPaid: uint(128), grad: b() } };
      expect(L.counterfactual(K, 1, 2).decode(enc('counterfactual', [out.curve, out.graduated, out.next]))).toEqual(out);

      const sm = { matters: b(), withState: hex(14), withOther: hex(14) };
      expect(L.stateMatters(K, 1).decode(enc('stateMatters', [sm.matters, sm.withState, sm.withOther]))).toEqual(sm);

      const pf = { sealedModeNow: b(), tapeoutRan: b(), sealedRan: b(), agree: b(), tapeoutGas: uint(40), sealedGas: uint(40), stepFloor: uint(40), sealedFloor: uint(40), minSettleGas: uint(40) };
      expect(L.preflight(K).decode(enc('preflight', pf))).toEqual(pf);

      const steps = Array.from({ length: i % 7 }, () => ({
        n: Number(uint(32)),
        ran: b(),
        inputs: hex(12),
        outputs: hex(14),
        clampBits: Number(uint(16)),
        allow: uint(128),
        buyDecided: uint(128),
        reserveAfter: uint(128),
      }));
      const next = { state: hex(32), reserve: uint(128), allowPaid: uint(128), grad: b() };
      const nextN = Number(uint(32));
      expect(L.shadowChip(K, 1n, 1, 2).decode(enc('shadowChip', [steps, next, nextN]))).toEqual({ steps, next, nextN });
    }
  });

  test('Fab, IGNIX, team registry', () => {
    for (let i = 0; i < 20; i++) {
      const ci = { snapshot: address(), netlistHash: hex(32), nState: Number(uint(32)), gateCount: Number(uint(32)), author: address(), manifestHash: hex(32) };
      expect(fab(K).chipInfo(1n).decode(enc('chipInfo', Object.values(ci)))).toEqual(ci);
      const ct = {
        creator: address(),
        buyFeeBps: Number(uint(16)),
        sellFeeBps: Number(uint(16)),
        taxBuyBps: Number(uint(16)),
        taxSellBps: Number(uint(16)),
        quote: address(),
        snipeStartBps: Number(uint(16)),
        snipeMins: Number(uint(16)),
        createdAt: Number(uint(48)),
        vQuote: uint(128),
        vToken: uint(128),
        sold: uint(128),
        collected: uint(128),
        sellable: uint(128),
        reserve: uint(128),
        poolId: hex(32),
      };
      expect(ignix.tokens(K, K).decode(enc('tokens', ct))).toEqual(ct);
      const role = ['deployer', 'keeper', '', 'a role with a longer name than thirty-two bytes, to span words'][i % 4];
      const te = { wallet: address(), role, timestamp: uint(40) };
      expect(teamRegistry(K).at(0).decode(enc('at', [te.wallet, te.role, te.timestamp]))).toEqual(te);
      const snap = hex(i * 7);
      expect(fabSnapshot(K, 1).decode(enc('snapshot', snap))).toBe(snap);
    }
    expect(erc20(K).decimals().decode(enc('decimals', 18))).toBe(18);
    for (let n = 0; n < 7; n++) {
      const owners = Array.from({ length: n }, () => address());
      expect(safe(K).owners().decode(enc('getOwners', owners))).toEqual(owners);
    }
    expect(safe(K).threshold().decode(enc('getThreshold', 3n))).toBe(3);
    const o = address();
    expect(ownerOf(K).decode(enc('owner', o))).toBe(o);
    expect(safe(K).owners().data).toBe(encodeFunctionData({ abi, functionName: 'getOwners' }));
  });

  test('short return data throws instead of decoding', () => {
    expect(() => kernel(K).records(1).decode('0x' + '00'.repeat(32 * 13))).toThrow('too short');
    expect(() => lens(K).replay(K, 1).decode('0x')).toThrow('too short');
  });
});

// Kernel v2 (USD₮0 quote): contracts/core-v2/src/interfaces/IKernelV2.sol. RecordV2 and GlobalsV2 are separate
// structs, so they get their own ABI; every other kernel view is v1's and is checked above.
const RECORD_V2 = RECORD.replace('uint128 nativeIn', 'uint128 quoteIn');
const GLOBALS_V2 = GLOBALS.replace('address wokb', 'address quote') + ', uint256 quoteShift';
const abiV2 = parseAbi([
  `struct RecordV2 { ${RECORD_V2}; }`.replaceAll(', ', '; '),
  `struct GlobalsV2 { ${GLOBALS_V2}; }`.replaceAll(', ', '; '),
  'function records(uint32 n) view returns (RecordV2)',
  'function globals() view returns (GlobalsV2)',
  'function quote() view returns (address)',
  'function quoteShift() view returns (uint256)',
  'function codeShift() view returns (uint256)',
  'function manager() view returns (address)',
  'function v2Router() view returns (address)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function isBlocked(address) view returns (bool)',
  'function count() view returns (uint32)',
  'function isKernel(address) view returns (bool)',
]);

describe('kernel v2 (USD₮0 quote) equals viem', () => {
  const k = kernelV2(K);
  const f = kernelFactoryV2(K);
  const enc = (fn: string, result: unknown): Hex => encodeFunctionResult({ abi: abiV2, functionName: fn as never, result: result as never });
  const data = (fn: string, args: unknown[] = []): string => lower(encodeFunctionData({ abi: abiV2, functionName: fn as never, args: args as never }));

  test('calldata: records, globals, quote, quoteShift, the factory pins, allowance, isBlocked', () => {
    for (let i = 0; i < 20; i++) {
      const n = Number(uint(32));
      const a = address();
      const b = address();
      expect(k.records(n).data).toBe(data('records', [n]));
      expect(f.isKernel(a).data).toBe(data('isKernel', [a]));
      expect(erc20(K).allowance(a, b).data).toBe(data('allowance', [a, b]));
      expect(tether(K).isBlocked(a).data).toBe(data('isBlocked', [a]));
    }
    expect(k.globals().data).toBe(data('globals'));
    expect(k.quote().data).toBe(data('quote'));
    expect(k.quoteShift().data).toBe(data('quoteShift'));
    expect(k.count().data).toBe(data('count')); // inherited from kernel v1
    for (const fn of ['quote', 'quoteShift', 'codeShift', 'manager', 'v2Router'] as const) expect(f[fn]().data, fn).toBe(data(fn));
  });

  test('decoders: RecordV2, GlobalsV2, the shift, allowance, isBlocked', () => {
    for (let i = 0; i < 50; i++) {
      const rec = {
        epoch: Number(uint(32)),
        time: Number(uint(40)),
        clampBits: Number(uint(16)),
        flags: Number(uint(8)),
        inputs: hex(12),
        outputs: hex(14),
        stateAfter: hex(32),
        inflow: uint(128),
        reserveBefore: uint(128),
        allow: uint(128),
        buyDecided: uint(128),
        buyExecuted: uint(128),
        tokensOut: uint(128),
        quoteIn: uint(128),
      };
      expect(k.records(1).decode(enc('records', rec))).toEqual(rec);
      const g = {
        manager: address(),
        v2Router: address(),
        quote: address(),
        factory: address(),
        circuits: address(),
        fab: address(),
        sealedVM: address(),
        beacon: address(),
        impl0: address(),
        impl0Hash: hex(32),
        snapshot: address(),
        netlistHash: hex(32),
        chipId: uint(256),
        nState: Number(uint(32)),
        gateCount: Number(uint(32)),
        netlistLen: Number(uint(32)),
        stepFloor: uint(64),
        sealedFloor: uint(64),
        quoteShift: Number(uint(6)),
      };
      expect(k.globals().decode(enc('globals', g))).toEqual(g);
      const s = Number(uint(6));
      expect(k.quoteShift().decode(enc('quoteShift', BigInt(s)))).toBe(s);
      expect(f.codeShift().decode(enc('codeShift', BigInt(8 * s)))).toBe(8 * s);
      const a = address();
      expect(k.quote().decode(enc('quote', a))).toBe(a);
      const v = uint(256);
      expect(erc20(K).allowance(a, a).decode(enc('allowance', v))).toBe(v);
      expect(tether(K).isBlocked(a).decode(enc('isBlocked', i % 2 === 0))).toBe(i % 2 === 0);
    }
  });

  test('a v1 record or globals is too short for the v2 decoders, and the other way round they differ', () => {
    // GlobalsV2 is 19 words; a v1 globals() answer has 18
    expect(() => k.globals().decode('0x' + '00'.repeat(32 * 18))).toThrow('too short');
    expect(() => k.records(1).decode('0x' + '00'.repeat(32 * 13))).toThrow('too short');
  });
});
