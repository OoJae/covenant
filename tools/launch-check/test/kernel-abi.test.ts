// kernel-abi.ts against the Solidity it describes. Every struct layout and every function signature the tools
// use is compared with:
//   chips/INTERFACE.md                             (section 7 Envelope, section 10 Record, IKernelV1, IKernelFactoryV1)
//   contracts/core/src/interfaces/IKernelV1.sol    (Envelope, Record, IKernelV1)
//   contracts/core/src/interfaces/IKernelExt.sol   (Globals, globals())
//   contracts/core/src/KernelFactory.sol           (isKernel, kernelOf, the step gas constants)
//   tools/launch-check/sim/src/Interfaces.sol      (the copies the fork simulation compiles against)
// A missing file or a difference FAILS: the kernel changed, so re-check kernel-abi.ts and the sim copies.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  ENVELOPE_FIELDS,
  GLOBALS_FIELDS,
  KERNEL_ABI_SNAPSHOT,
  KernelAbiError,
  RECORD_FIELDS,
  SEALED_GAS,
  STEP_GAS,
  encodeStruct,
  kernel,
  kernelFactory,
  sealedFloorOf,
  selector,
  stepFloorOf,
  type Field,
} from '../kernel-abi.ts';
import { ENVELOPE, GLOBALS } from './helpers.ts';

const repo = fileURLToPath(new URL('../../../', import.meta.url));
const read = (file: string): string => readFileSync(repo + file, 'utf8'); // throws, and so fails, when a file is missing

const SOURCES = {
  doc: 'chips/INTERFACE.md',
  v1: 'contracts/core/src/interfaces/IKernelV1.sol',
  ext: 'contracts/core/src/interfaces/IKernelExt.sol',
  factory: 'contracts/core/src/KernelFactory.sol',
  sim: 'tools/launch-check/sim/src/Interfaces.sol',
} as const;

/** The fields of `struct <name> { ... }`, comments removed, as [name, type]. */
function structFields(source: string, name: string): [string, string][] {
  const m = new RegExp(`struct\\s+${name}\\s*\\{([^}]*)\\}`).exec(source);
  assert.ok(m, `struct ${name} is declared`);
  return m[1]
    .split('\n')
    .map((line) => line.replace(/\/\/.*$/, '').trim())
    .filter(Boolean)
    .map((line) => {
      const f = /^([A-Za-z0-9_]+)\s+([A-Za-z0-9_]+);$/.exec(line);
      if (!f) throw new Error(`cannot parse struct field: ${line}`);
      return [f[2], f[1]];
    });
}

/** Every `function name(params) external [view] [override] returns (types)` as "name(types) returns (types)". */
function functionSignatures(source: string): Set<string> {
  const out = new Set<string>();
  const types = (list: string): string =>
    list
      .split(',')
      .map((p) => p.trim().split(/\s+/)[0])
      .filter(Boolean)
      .join(',');
  for (const m of source.matchAll(/function\s+([A-Za-z0-9_]+)\s*\(([^)]*)\)[^;{]*?returns\s*\(([^)]*)\)/g)) {
    out.add(`${m[1]}(${types(m[2])}) returns (${types(m[3])})`);
  }
  // public mappings are getters too: mapping(address kernel => bool) public isKernel;
  for (const m of source.matchAll(/mapping\s*\(\s*([A-Za-z0-9_]+)[^=]*=>\s*([A-Za-z0-9_]+)(?:\s+[A-Za-z0-9_]+)?\s*\)\s*public\s+([A-Za-z0-9_]+)\s*;/g)) {
    out.add(`${m[3]}(${m[1]}) returns (${m[2]})`);
  }
  return out;
}

const asPairs = (fields: readonly Field[]): [string, string][] => fields.map(([n, ty]) => [n, ty]);

test('struct Envelope: INTERFACE.md section 7, IKernelV1.sol and the sim copy all match kernel-abi.ts', () => {
  for (const file of [SOURCES.doc, SOURCES.v1, SOURCES.sim]) {
    assert.deepEqual(structFields(read(file), 'Envelope'), asPairs(ENVELOPE_FIELDS), `${file}: the Envelope layout changed; re-check tools/launch-check/kernel-abi.ts`);
  }
});

test('struct Record: INTERFACE.md section 10, IKernelV1.sol and the sim copy all match kernel-abi.ts (nativeIn included)', () => {
  for (const file of [SOURCES.doc, SOURCES.v1, SOURCES.sim]) {
    assert.deepEqual(structFields(read(file), 'Record'), asPairs(RECORD_FIELDS), `${file}: the Record layout changed; re-check tools/launch-check/kernel-abi.ts`);
  }
  assert.equal(RECORD_FIELDS.at(-1)?.[0], 'nativeIn');
});

test('struct Globals: IKernelExt.sol and the sim copy match kernel-abi.ts (sealedFloor last)', () => {
  for (const file of [SOURCES.ext, SOURCES.sim]) {
    assert.deepEqual(structFields(read(file), 'Globals'), asPairs(GLOBALS_FIELDS), `${file}: the Globals layout changed; re-check tools/launch-check/kernel-abi.ts`);
  }
  assert.deepEqual(GLOBALS_FIELDS.slice(-2), [['stepFloor', 'uint256'], ['sealedFloor', 'uint256']]);
});

test('every kernel and factory function the tools call is declared, with these types, in the Solidity sources', () => {
  const k = kernel('0x00000000000000000000000000000000c0fe0001');
  const f = kernelFactory('0x00000000000000000000000000000000c0fe0005');
  const calls = [k.token(), k.vault(), k.chipId(), k.count(), k.records(1), k.envelope(), k.globals(), f.isKernel(k.token().to), f.kernelOf(k.token().to)];
  const kernelSol = functionSignatures(read(SOURCES.v1) + read(SOURCES.ext));
  const factorySol = functionSignatures(read(SOURCES.factory));
  const docSol = functionSignatures(read(SOURCES.doc));
  for (const c of calls) {
    const isFactory = c.to.endsWith('0005');
    assert.ok((isFactory ? factorySol : kernelSol).has(c.signature), `${c.signature} is declared in ${isFactory ? SOURCES.factory : SOURCES.v1 + ' / ' + SOURCES.ext}`);
    if (c.signature !== 'globals() returns (Globals)') assert.ok(docSol.has(c.signature), `${c.signature} is declared in ${SOURCES.doc} section 10`);
    assert.equal(c.data.slice(0, 10), selector(c.signature.replace(/ returns.*$/, '')));
  }
  assert.equal(selector('ownerOf(uint256)'), '0x6352211e', 'a known ERC-721 selector, as a check of the method');
  assert.equal(f.isKernel('0x00000000000000000000000000000000c0fe0001').data, selector('isKernel(address)') + '00000000000000000000000000000000000000000000000000000000c0fe0001');
  assert.equal(k.records(7).data, selector('records(uint32)') + '0'.repeat(63) + '7');
});

test('the sim interface declares the same kernel functions it calls', () => {
  const sim = functionSignatures(read(SOURCES.sim));
  for (const sig of ['chipId() returns (uint256)', 'settle() returns (uint32)', 'token() returns (address)', 'vault() returns (address)', 'count() returns (uint32)', 'records(uint32) returns (Record)', 'envelope() returns (Envelope)', 'globals() returns (Globals)', 'isKernel(address) returns (bool)', 'kernelOf(address) returns (address)', 'epochNow() returns (uint32)', 'lastEpoch() returns (uint32)', 'reserve() returns (uint256)']) {
    assert.ok(sim.has(sig), `sim/src/Interfaces.sol declares ${sig}`);
  }
  const v1 = functionSignatures(read(SOURCES.v1) + read(SOURCES.ext));
  for (const sig of sim) {
    if (/^(chipId|settle|token|vault|count|records|envelope|globals|epochNow|lastEpoch|reserve)\(/.test(sig)) assert.ok(v1.has(sig), `${sig} (sim) is the kernel's own declaration`);
  }
});

test('the step gas formulas are the KernelFactory constants', () => {
  const src = read(SOURCES.factory);
  const constant = (name: string): bigint => {
    const m = new RegExp(`uint256\\s+public\\s+constant\\s+${name}\\s*=\\s*([0-9_]+);`).exec(src);
    assert.ok(m, `${name} is declared in KernelFactory.sol`);
    return BigInt(m[1].replace(/_/g, ''));
  };
  assert.equal(constant('STEP_BASE'), STEP_GAS.base);
  assert.equal(constant('STEP_PER_GATE'), STEP_GAS.perGate);
  assert.equal(constant('STEP_PER_LATCH'), STEP_GAS.perLatch);
  assert.equal(constant('SEALED_BASE'), SEALED_GAS.base);
  assert.equal(constant('SEALED_PER_NAND'), SEALED_GAS.perNand);
  assert.equal(constant('SEALED_PER_LATCH'), SEALED_GAS.perLatch);
  assert.match(src, /g\.sealedFloor\s*=\s*SEALED_BASE \+ SEALED_PER_NAND \* uint256\(g\.gateCount - g\.nState\) \+ SEALED_PER_LATCH \* uint256\(g\.nState\);/);
  assert.equal(stepFloorOf(1800n, 16n), 200_000n + 2_600n * 1800n + 800n * 16n);
  assert.equal(sealedFloorOf(1800n, 16n), 40_000n + 200n * 1784n + 400n * 16n);
});

test('the kernel sources are still the ones this module was last compared with (informational)', (t) => {
  const changed: string[] = [];
  for (const s of KERNEL_ABI_SNAPSHOT.sources) {
    const now = createHash('sha256').update(readFileSync(repo + s.file)).digest('hex');
    if (now !== s.sha256) changed.push(`${s.file}: sha256 is now ${now}`);
  }
  // A changed file does not fail by itself: the layout and signature tests above decide whether it matters.
  if (changed.length) t.diagnostic('kernel sources changed since kernel-abi.ts was last compared (the tests above still decide): ' + changed.join('; '));
});

test('struct returns are decoded strictly', () => {
  const k = kernel('0x00000000000000000000000000000000c0fe0001');
  const env = encodeStruct(ENVELOPE_FIELDS, { ...ENVELOPE });
  assert.equal((env.length - 2) / 2, 14 * 32);
  assert.deepEqual(k.envelope().decode(env), ENVELOPE);
  const glob = encodeStruct(GLOBALS_FIELDS, { ...GLOBALS });
  assert.equal((glob.length - 2) / 2, 18 * 32);
  assert.deepEqual(k.globals().decode(glob), GLOBALS);
  assert.throws(() => k.globals().decode(glob.slice(0, -64)), /544 bytes; 576 expected/, 'a kernel without sealedFloor (interface revision 1)');

  assert.throws(() => k.envelope().decode('0x'), KernelAbiError, 'an address without code');
  assert.throws(() => k.envelope().decode(env + '00'.repeat(32)), /480 bytes; 448 expected/, 'one more word: another layout');
  assert.throws(() => k.envelope().decode(env.slice(0, -64)), /416 bytes; 448 expected/, 'one word fewer');
  // a launcher word with a bit above 160: not an address, so not this layout
  assert.throws(() => k.envelope().decode('0x01' + env.slice(4)), /does not fit address/);
  // buyEnabled = 2 is not a bool
  const boolAt = 2 + 12 * 64;
  assert.throws(() => k.envelope().decode(env.slice(0, boolAt) + '00'.repeat(31) + '02' + env.slice(boolAt + 64)), /does not fit bool/);
  assert.throws(() => k.token().decode('0x'), /0 bytes; 32 expected/);
  assert.throws(() => k.token().decode('0x' + 'ff'.repeat(32)), /does not fit address/);
  assert.equal(k.token().decode('0x' + '00'.repeat(32)), '0x' + '00'.repeat(20));
  assert.equal(k.chipId().decode('0x' + '00'.repeat(31) + '07'), 7n);

  const rec = {
    epoch: 3n,
    time: 1_791_150_000n,
    clampBits: 4n,
    flags: 16n,
    inputs: '0x' + 'ab'.repeat(12),
    outputs: '0x' + 'cd'.repeat(14),
    stateAfter: '0x' + '11'.repeat(32),
    inflow: 3n * 10n ** 16n,
    reserveBefore: 0n,
    allow: 5n,
    buyDecided: 6n,
    buyExecuted: 7n,
    tokensOut: 8n,
    nativeIn: 0n,
  };
  const r = encodeStruct(RECORD_FIELDS, rec);
  assert.equal((r.length - 2) / 2, 14 * 32);
  assert.deepEqual(k.records(1).decode(r), rec);
  // a bytes12 word with a bit set in its low 20 bytes is not a bytes12
  const inputsAt = 2 + 4 * 64;
  assert.throws(() => k.records(1).decode(r.slice(0, inputsAt + 63) + '1' + r.slice(inputsAt + 64)), /does not fit bytes12/);
  assert.throws(() => k.records(1).decode(r.slice(0, -64)), /416 bytes; 448 expected/, 'a record without nativeIn (interface revision 1)');
});
