// One beat of TAP-20 evaluation (TAP-20 section 4).
//
//   1. signal 0 = 0, signal 1 = 1, signal 2 + i = inputs[i];
//   2. elements in record order: NAND = 1 - (a AND b); LATCH = its bit from `state` (the value
//      stored at the previous beat); REF = one beat of the referenced circuit on its block of state;
//   3. after all elements, each LATCH's bit of the new state is s[d] from this beat;
//   4. outputs are the last nOut signals.

import { packBits, unpackBits } from './bits.ts';
import { LATCH, NAND, Tap20Error, type Netlist } from './parse.ts';

/** TAP-20 section 7.1: bound the work before evaluating an untrusted netlist. */
export interface Limits {
  /** Largest total gate count (REF sub-circuits included) to evaluate. Default 4,194,304. */
  maxGates?: number;
  /** Deepest REF nesting to evaluate. Default 16. */
  maxDepth?: number;
}

export const DEFAULT_MAX_GATES = 1 << 22;
export const DEFAULT_MAX_DEPTH = 16;

export interface Beat {
  /** New state. `step`: packed, exactly ceil(nState / 8) bytes. `stepBits`: one byte per bit. */
  newState: Uint8Array;
  /** Outputs. `step`: packed, exactly ceil(nOut / 8) bytes. `stepBits`: one byte per bit. */
  outputs: Uint8Array;
  /** Value (0 or 1) of every top-level signal in this beat, indexed by signal number. */
  signals: Uint8Array;
}

function checkLimits(nl: Netlist, limits?: Limits): void {
  const maxGates = limits?.maxGates ?? DEFAULT_MAX_GATES;
  const maxDepth = limits?.maxDepth ?? DEFAULT_MAX_DEPTH;
  if (nl.gateCount > maxGates) {
    throw new Tap20Error('limit', `circuit has ${nl.gateCount} gates, above the evaluation bound of ${maxGates}`);
  }
  if (nl.depth > maxDepth) {
    throw new Tap20Error('limit', `REF nesting depth ${nl.depth} is above the evaluation bound of ${maxDepth}`);
  }
}

// Evaluate the elements of `nl` into `s` (signals 0, 1 and the inputs already set), reading
// state bits at `base + stateBase` from `state` and writing the new ones into `next`.
function run(nl: Netlist, state: Uint8Array, base: number, s: Uint8Array, next: Uint8Array): void {
  const { op, a, b, out, stateBase, n } = nl;
  for (let e = 0; e < n; e++) {
    const o = op[e];
    if (o === NAND) {
      s[out[e]] = 1 ^ (s[a[e]] & s[b[e]]);
    } else if (o === LATCH) {
      s[out[e]] = state[base + stateBase[e]];
    } else {
      const r = nl.refs[b[e]];
      const sub = r.sub;
      const ss = new Uint8Array(sub.nSignals);
      ss[1] = 1;
      for (let i = 0; i < r.nIns; i++) ss[2 + i] = s[r.ins[i]];
      run(sub, state, base + stateBase[e], ss, next);
      const first = sub.nSignals - sub.nOut;
      const o0 = out[e];
      for (let j = 0; j < r.nOuts; j++) s[o0 + j] = ss[first + j];
    }
  }
  // The clock edge: every LATCH stores s[d] of this beat.
  const latches = nl.latches;
  for (let k = 0; k < latches.length; k++) {
    const e = latches[k];
    next[base + stateBase[e]] = s[a[e]];
  }
}

/**
 * One beat on unpacked bit vectors (one array entry per bit; anything truthy is a 1; entries
 * beyond the end read as 0). Returns unpacked `newState` and `outputs` and every signal value.
 */
export function stepBits(nl: Netlist, state: ArrayLike<number>, inputs: ArrayLike<number>, limits?: Limits): Beat {
  checkLimits(nl, limits);
  const st = new Uint8Array(nl.nState);
  const ns = Math.min(nl.nState, state.length);
  for (let i = 0; i < ns; i++) st[i] = state[i] ? 1 : 0;
  const s = new Uint8Array(nl.nSignals);
  s[1] = 1;
  const ni = Math.min(nl.nIn, inputs.length);
  for (let i = 0; i < ni; i++) s[2 + i] = inputs[i] ? 1 : 0;
  const next = new Uint8Array(nl.nState);
  run(nl, st, 0, s, next);
  return { newState: next, outputs: s.slice(nl.nSignals - nl.nOut), signals: s };
}

/**
 * One beat on packed byte strings, exactly as `Circuits.step(id, state, inputs)` computes it.
 * `state` and `inputs` are read leniently (TAP-20 section 5): missing bytes read as 0, extra
 * bytes and padding bits are ignored. `newState` and `outputs` come back canonical.
 */
export function step(nl: Netlist, state: ArrayLike<number>, inputs: ArrayLike<number>, limits?: Limits): Beat {
  const r = stepBits(nl, unpackBits(state, nl.nState), unpackBits(inputs, nl.nIn), limits);
  return { newState: packBits(r.newState), outputs: packBits(r.outputs), signals: r.signals };
}

/**
 * `Circuits.eval(id, inputs)`: the packed outputs of a combinational circuit. Like the
 * contract, it refuses a circuit with state.
 */
export function evaluate(nl: Netlist, inputs: ArrayLike<number>, limits?: Limits): Uint8Array {
  if (nl.nState > 0) throw new Error('has latch: use step');
  return step(nl, [], inputs, limits).outputs;
}
