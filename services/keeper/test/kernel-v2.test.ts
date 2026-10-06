// Kernel v2 (USD₮0 quote, contracts/core-v2): the keeper settles it with the same ABI, the same gas rule and the same
// KeeperTank path as kernel v1. These tests compare the keeper's ABI with both kernels' Solidity sources and check the
// gas limits it would sign for v2 kernels. The end-to-end run (the keeper in dry-run mode, then a tank settle, against
// a real v2 kernel on a fork) is part of `REHEARSE=1 node --test tools/launch-check/test/rehearsal-v2.test.ts`.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { toEventSelector, toFunctionSelector } from 'viem';
import { CALLDATA, kernelAbi, knownErrorName } from '../src/abi.ts';
import { loadConfig } from '../src/config.ts';
import { gasLimitFor } from '../src/tx.ts';

const repo = fileURLToPath(new URL('../../../', import.meta.url));
const read = (file: string): string => readFileSync(repo + file, 'utf8');
const V1 = 'contracts/core/src/interfaces/IKernelV1.sol';
const V2 = 'contracts/core-v2/src/interfaces/IKernelV2.sol';
const KERNEL_V1 = 'contracts/core/src/Kernel.sol';
const KERNEL_V2 = 'contracts/core-v2/src/KernelV2.sol';
const TANK_MIN = 'contracts/issuance/src/interfaces/IKernelMin.sol';

const strip = (src: string): string => src.replace(/\/\/[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, '');
const types = (list: string): string =>
  list
    .split(',')
    .map((p) => p.trim().split(/\s+/)[0])
    .filter(Boolean)
    .join(',');

/** "name(types) returns (types)" for each function declared in `src`. */
function functions(src: string): Set<string> {
  const out = new Set<string>();
  for (const m of strip(src).matchAll(/function\s+([A-Za-z0-9_]+)\s*\(([^)]*)\)[^;{]*?returns\s*\(([^)]*)\)/g)) {
    out.add(`${m[1]}(${types(m[2] ?? '')}) returns (${types(m[3] ?? '')})`);
  }
  return out;
}

/** The canonical signature of `event <name>(...)` declared in `src`, indexed markers removed. */
function eventSignature(src: string, name: string): string {
  const m = new RegExp(`event\\s+${name}\\s*\\(([^)]*)\\)`).exec(strip(src));
  assert.ok(m, `event ${name} is declared`);
  return `${name}(${types((m[1] ?? '').replace(/\bindexed\b/g, ''))})`;
}

test('the five kernel functions the keeper calls are declared, with these types, by kernel v1 and kernel v2', () => {
  const v1 = functions(read(V1));
  const v2 = functions(read(V2));
  // chipId() and settle(): IKernelMin, which both IKernelV1 and IKernelV2 inherit; the tank calls the same two
  for (const src of [read(V1), read(TANK_MIN)]) {
    const min = functions(/interface IKernelMin\s*\{[\s\S]*?\n\}/.exec(src)?.[0] ?? '');
    assert.ok(min.has('chipId() returns (uint256)') && min.has('settle() returns (uint32)'), 'IKernelMin declares chipId() and settle()');
  }
  assert.match(read(V2), /interface IKernelV2 is IKernelMin/);
  assert.match(read(V2), /import \{IKernelMin, Envelope\} from "core\/interfaces\/IKernelV1\.sol";/, 'IKernelV2 uses kernel v1\'s IKernelMin');
  for (const sig of ['epochNow() returns (uint32)', 'lastEpoch() returns (uint32)', 'minSettleGas() returns (uint256)']) {
    assert.ok(v1.has(sig), `${V1} declares ${sig}`);
    assert.ok(v2.has(sig), `${V2} declares ${sig}`);
  }
  // the keeper's calldata is those functions' selectors
  assert.equal(CALLDATA.chipId, toFunctionSelector('chipId()'));
  assert.equal(CALLDATA.settle, toFunctionSelector('settle()'));
  assert.equal(CALLDATA.epochNow, toFunctionSelector('epochNow()'));
  assert.equal(CALLDATA.lastEpoch, toFunctionSelector('lastEpoch()'));
  assert.equal(CALLDATA.minSettleGas, toFunctionSelector('minSettleGas()'));
});

test('the Settled event the keeper decodes is declared identically by kernel v1 and kernel v2', () => {
  const keeper = kernelAbi.find((x) => x.type === 'event' && x.name === 'Settled');
  assert.ok(keeper);
  const sig1 = eventSignature(read(V1), 'Settled');
  const sig2 = eventSignature(read(V2), 'Settled');
  assert.equal(sig2, sig1);
  assert.equal(toEventSelector(keeper), toEventSelector(sig1));
  assert.equal(sig1, 'Settled(uint32,uint32,bytes12,bytes14,uint16,uint8,bytes32,uint128,uint128,uint128,uint128,uint128)');
});

test('every error kernel v1 and kernel v2 declare is logged by name', () => {
  for (const file of [KERNEL_V1, KERNEL_V2]) {
    const errors = [...strip(read(file)).matchAll(/\berror\s+([A-Za-z0-9_]+)\s*\(([^)]*)\)\s*;/g)].map((m) => `${m[1]}(${types(m[2] ?? '')})`);
    assert.ok(errors.length >= 10, `${file}: errors found`);
    for (const e of errors) assert.equal(knownErrorName(toFunctionSelector(e)), e, `${file}: ${e} is named`);
  }
});

/** KernelV2.minSettleGas(), recomputed from the constants in KernelV2.sol (each one read from the source). */
function minSettleGasV2(gateCount: bigint, nState: bigint): bigint {
  const src = read(KERNEL_V2);
  const c = (name: string): bigint => {
    const m = new RegExp(`uint256\\s+internal\\s+constant\\s+${name}\\s*=\\s*([0-9_]+);`).exec(src);
    assert.ok(m, `${name} is declared in KernelV2.sol`);
    return BigInt((m[1] ?? '0').replace(/_/g, ''));
  };
  // the public wrapper and the private formula, as written in KernelV2.sol
  assert.match(src, /uint256 m = _minSettleGas\(g\.stepFloor, g\.sealedFloor\) \+ 40_000;\s*m = m \+ m \/ 63 \+ 5_000;\s*m = m \+ m \/ 63 \+ 5_000;\s*return m \+ 30_000;/);
  assert.match(src, /return G_SELF \+ 2 \* _withMargin\(G_CLAIM\) \+ N_VIEWS \* _withMargin\(G_VIEW\) \+ _withMargin\(G_NETLIST\)\s*\+ _withMargin\(stepFloor\) \+ _withMargin\(sealedFloor\) \+ \(curveLeg > gradLegs \? curveLeg : gradLegs\);/);
  const margin = c('CALL_MARGIN');
  const wm = (g: bigint): bigint => g + g / 63n + margin;
  const stepFloor = 200_000n + 2_600n * gateCount + 800n * nState; // KernelFactoryV2: STEP_BASE, STEP_PER_GATE, STEP_PER_LATCH
  const sealedFloor = 40_000n + 200n * (gateCount - nState) + 400n * nState; // SEALED_BASE, SEALED_PER_NAND, SEALED_PER_LATCH
  const approvals = 2n * wm(c('G_APPROVE'));
  const curveLeg = wm(c('G_BUY')) + approvals;
  const gradLegs = wm(c('G_TRANSFER')) + wm(c('G_SWAP')) + approvals;
  const inner = c('G_SELF') + 2n * wm(c('G_CLAIM')) + c('N_VIEWS') * wm(c('G_VIEW')) + wm(c('G_NETLIST')) + wm(stepFloor) + wm(sealedFloor) + (curveLeg > gradLegs ? curveLeg : gradLegs);
  let m = inner + 40_000n;
  m = m + m / 63n + 5_000n;
  m = m + m / 63n + 5_000n;
  return m + 30_000n;
}

test('gas: the keeper signs a v2 settle for every chip KernelFactoryV2 accepts, under the default MAX_GAS_LIMIT', () => {
  const factory = read('contracts/core-v2/src/KernelFactoryV2.sol');
  assert.match(factory, /STEP_BASE = 200_000;[\s\S]*STEP_PER_GATE = 2_600;[\s\S]*STEP_PER_LATCH = 800;[\s\S]*SEALED_BASE = 40_000;[\s\S]*SEALED_PER_NAND = 200;[\s\S]*SEALED_PER_LATCH = 400;/);
  const maxGates = BigInt((/MAX_GATES = ([0-9_]+);/.exec(factory)?.[1] ?? '0').replace(/_/g, ''));
  assert.equal(maxGates, 3400n);
  // the Flow Governor (1,888 NAND + 64 LATCH): 11,814,581 on the fork (contracts/core-v2/NOTES.md section 4)
  const fg = minSettleGasV2(1952n, 64n);
  assert.ok(fg >= 11_814_580n && fg <= 11_814_582n, `Flow Governor minSettleGas ${fg}`);
  const cfg = loadConfig({ KERNELS: '0x00000000000000000000000000000000c0fe0011', DRY_RUN: '1' }, []);
  assert.equal(cfg.maxGasLimit, 30_000_000n);
  // the largest chip KernelFactoryV2 accepts: 3,400 gates, 256 latches
  const worst = minSettleGasV2(maxGates, 256n);
  for (const [name, m] of [['Flow Governor', fg], ['3,400 gates, 256 latches', worst]] as const) {
    // the estimate through the tank adds the tank's overhead and, once per chip, the netlist scan: 2M is generous
    const limit = gasLimitFor(m + 2_000_000n, m);
    assert.ok(limit >= (m * 110n) / 100n, `${name}: the limit covers minSettleGas * 1.1`);
    assert.ok(limit <= cfg.maxGasLimit, `${name}: gas limit ${limit} is within MAX_GAS_LIMIT ${cfg.maxGasLimit}`);
  }
  assert.ok(worst < 17_000_000n, `worst case ${worst}`);
});
