// The fixed demo payload returned while the chip toolchain is not wired in (TAPC_CMD unset).
//
// It is a real, well-formed TAP-20 netlist of the Covenant interface-v1 shape (96 inputs, 112 outputs,
// one latch), small enough to read by hand: every output bit is a constant. It is NOT a product of the
// toolchain, carries no proofs, and is marked `stub: true` everywhere a consumer could look.

import { keccak256 } from 'viem';
import type { CompileResult } from './toolchain.ts';

const N_IN = 96;
const N_OUT = 112;

/** chips/INTERFACE.md section 5: (name, offset, width). */
const INPUT_FIELDS: ReadonlyArray<readonly [string, number, number]> = [
  ['TAX', 0, 10],
  ['TAXCUM', 10, 10],
  ['REV', 20, 10],
  ['REVCUM', 30, 10],
  ['RES', 40, 10],
  ['ESC', 50, 10],
  ['PROG', 60, 8],
  ['LOCK', 68, 8],
  ['DT', 76, 4],
  ['GRAD', 80, 1],
  ['ZERO', 81, 15],
];

/** chips/INTERFACE.md section 6: (name, offset, width). */
const OUTPUT_FIELDS: ReadonlyArray<readonly [string, number, number]> = [
  ['T_BUY', 0, 9],
  ['T_HOLD', 9, 9],
  ['T_ALLOW', 18, 9],
  ['T_RES', 27, 9],
  ['V_BUY', 36, 9],
  ['V_HOLD', 45, 9],
  ['V_ALLOW', 54, 9],
  ['V_RES', 63, 9],
  ['REL', 72, 9],
  ['CEIL', 81, 10],
  ['MODE', 91, 3],
  ['TIER', 94, 2],
  ['FLAGS', 96, 8],
  ['AUX', 104, 8],
];

/** What the stub chip outputs on every beat: half of fresh tax to buy-and-lock, half to reserve, no allowance. */
export const STUB_OUTPUTS: Readonly<Record<string, number>> = {
  T_BUY: 128,
  T_HOLD: 0,
  T_ALLOW: 0,
  T_RES: 128,
  V_BUY: 128,
  V_HOLD: 0,
  V_ALLOW: 0,
  V_RES: 128,
  REL: 2,
  CEIL: 1023,
  MODE: 0,
  TIER: 0,
  FLAGS: 0,
  AUX: 0,
};

const FIRST_LATCH = 2 + N_IN; // signal 98
const FIRST_OUTPUT = FIRST_LATCH + 1; // signal 99

function outputWord(): bigint {
  let word = 0n;
  for (const [name, offset, width] of OUTPUT_FIELDS) {
    const v = STUB_OUTPUTS[name] ?? 0;
    if (v < 0 || v >= 2 ** width) throw new Error(`stub: ${name}=${v} does not fit ${width} bits`);
    word |= BigInt(v) << BigInt(offset);
  }
  return word;
}

const u24 = (n: number): string => n.toString(16).padStart(6, '0');

/**
 * TAP-20 records (section 2): NAND = 00 a:u24 b:u24, LATCH = 01 d:u24, big-endian.
 *   record 0        LATCH whose d is its own output: one state bit that never changes
 *   records 1..112  one NAND per output bit: NAND(1,1) = 0 or NAND(0,0) = 1
 */
function buildNetlistHex(): string {
  const word = outputWord();
  let hex = `01${u24(FIRST_LATCH)}`;
  for (let bit = 0; bit < N_OUT; bit++) {
    const one = ((word >> BigInt(bit)) & 1n) === 1n;
    hex += one ? `00${u24(0)}${u24(0)}` : `00${u24(1)}${u24(1)}`;
  }
  return `0x${hex}`;
}

function bitNames(fields: ReadonlyArray<readonly [string, number, number]>, width: number, prefix: string): string[] {
  const names = Array.from({ length: width }, (_, i) => `${prefix}[${i}]`);
  for (const [name, lsb, w] of fields) {
    for (let k = 0; k < w; k++) names[lsb + k] = w === 1 ? name : `${name}[${k}]`;
  }
  return names;
}

export const STUB_NETLIST_HEX = buildNetlistHex();

const WARNING =
  'STUB OUTPUT. The chip toolchain is not configured on this server (TAPC_CMD is unset), so this is a fixed demo ' +
  'payload, not a compiled chip: the preset and params were not used and no proof was run.';

/** The stub result. `preset` and `params` are echoed so a client can see they were received. */
export function stubResult(preset: string, params: Record<string, unknown>, transistorPriceWei: bigint): CompileResult {
  const nNand = N_OUT;
  const nLatch = 1;
  const gates = nNand + nLatch;
  const inNames = bitNames(INPUT_FIELDS, N_IN, 'x');
  const outNames = bitNames(OUTPUT_FIELDS, N_OUT, 'y');
  const field = ([name, lsb, width]: readonly [string, number, number]) => ({ name, lsb, width });

  return {
    stub: true,
    netlistHex: STUB_NETLIST_HEX,
    // Same shape as the toolchain's "tapc-manifest/1", plus the stub markers.
    manifest: {
      format: 'tapc-manifest/1',
      stub: true,
      warning: WARNING,
      name: 'stub-constant-split',
      preset,
      params,
      interface: 'covenant-v1',
      standard: 'TAP-20 draft (updated 2026-09-30)',
      nIn: N_IN,
      nOut: N_OUT,
      nState: nLatch,
      nNand,
      nLatch,
      nRef: 0,
      gateCount: gates,
      signals: 2 + N_IN + gates,
      depth: 1,
      bytes: (STUB_NETLIST_HEX.length - 2) / 2,
      keccak256: keccak256(STUB_NETLIST_HEX as `0x${string}`),
      latchesFirst: true,
      layout: {
        const0: 0,
        const1: 1,
        firstInput: 2,
        firstLatch: FIRST_LATCH,
        firstNand: FIRST_OUTPUT,
        firstOutput: FIRST_OUTPUT,
        outputDuplicates: 0,
        outputBuffers: 0,
        outputConstants: N_OUT,
      },
      inputs: inNames.map((name, bit) => ({ bit, name, signal: 2 + bit })),
      outputs: outNames.map((name, bit) => ({ bit, name, signal: FIRST_OUTPUT + bit })),
      latches: [{ bit: 0, name: 'idle', record: 0, signal: FIRST_LATCH, d: FIRST_LATCH }],
      fields: {
        inputs: INPUT_FIELDS.map(field),
        outputs: OUTPUT_FIELDS.map(field),
        state: [{ name: 'idle', lsb: 0, width: 1 }],
      },
      decodedOutputs: { ...STUB_OUTPUTS },
      tapeout: { nIn: N_IN, nOut: N_OUT, burnNand: nNand, burnLatch: nLatch },
      tool: { architect: 'stub' },
    },
    proofs: [{ id: 'stub', status: 'skipped', detail: 'No proof was run: this is the fixed stub payload.' }],
    cost: {
      stub: true,
      transistors: gates,
      nNand,
      nLatch,
      unitPriceWei: transistorPriceWei.toString(),
      transistorCostWei: (BigInt(gates) * transistorPriceWei).toString(),
      currency: 'OKB',
      // Rule of thumb from the design notes: 250k + 48k + 2,300 gas per gate.
      settleGasEstimate: 250_000 + 48_000 + 2_300 * gates,
      note: 'Transistors only. TapeOut tape-out and protocol fees and gas are extra; Fab.quote(netlist) is authoritative.',
    },
  };
}
