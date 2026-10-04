// Conformance against TAP-20's own test vectors.
// test/fixtures/tap20-vectors.json is assets/tap-20/vectors.json from
// https://github.com/TapeOutProtocol/TAPs (CC0), byte for byte.

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'vitest';
import {
  bytesToHex,
  encode,
  evaluate,
  hexToBytes,
  parse,
  refKey,
  step,
  Tap20Error,
  type Netlist,
  type Resolver,
  type Tap20ErrorCode,
} from '../src/index.ts';

interface RefVector {
  cpu: string;
  id: number;
  nIn: number;
  nOut: number;
  netlist: string;
}
interface ValidVector {
  name: string;
  nIn: number;
  nOut: number;
  nState: number;
  netlist: string;
  refs: RefVector[];
  truthTable?: { inputs: string; outputs: string }[];
  beats?: { state: string; inputs: string; newState: string; outputs: string }[];
}
interface IllFormedVector {
  name: string;
  nIn: number;
  nOut: number;
  netlist: string;
  reason: string;
  refs: RefVector[];
}
interface Vectors {
  format: string;
  valid: ValidVector[];
  illFormed: IllFormedVector[];
  packingEdgeCases: { circuit: string; cases: { case: string; inputs: string; outputs: string }[] };
}

const fixture = new URL('./fixtures/tap20-vectors.json', import.meta.url);
const raw = readFileSync(fixture);
const vectors = JSON.parse(raw.toString('utf8')) as Vectors;

// The vectors' `refs` list stands in for the chain: only these circuits exist.
function resolverFor(refs: RefVector[]): Resolver {
  const table = new Map<string, Netlist>();
  for (const r of refs) table.set(refKey(r.cpu, r.id), parse(hexToBytes(r.netlist), r.nIn, r.nOut));
  return (cpu, id) => table.get(refKey(cpu, id));
}

const hex = (b: Uint8Array): string => bytesToHex(b, false);

test('the fixture is the published vectors.json (sha-256 from TAP-20, Test Cases)', () => {
  expect(vectors.format).toBe('tap-netlist-vectors/1');
  expect(createHash('sha256').update(raw).digest('hex')).toBe(
    '1a02f5cf991c130a22dc6cc6ee93d0f8fe0720afed081665fa8b8018aefd203b',
  );
});

describe('valid netlists', () => {
  test('all five named vectors are present', () => {
    expect(vectors.valid.map((v) => v.name)).toEqual(['nand', 'constants', 'popcount8_3151', 'toggle', 'ref_with_state']);
  });

  for (const v of vectors.valid) {
    describe(v.name, () => {
      const bytes = hexToBytes(v.netlist);
      const nl = parse(bytes, v.nIn, v.nOut, resolverFor(v.refs));

      test('decodes with the stated shape and re-encodes to the same bytes', () => {
        expect(nl.nIn).toBe(v.nIn);
        expect(nl.nOut).toBe(v.nOut);
        expect(nl.nState).toBe(v.nState);
        expect(nl.n).toBe(nl.nNand + nl.nLatch + nl.nRef);
        expect(hex(encode(nl))).toBe(hex(bytes));
      });

      if (v.truthTable) {
        const table = v.truthTable;
        test(`truth table (${table.length} rows) through step and evaluate`, () => {
          for (const row of table) {
            const r = step(nl, new Uint8Array(0), hexToBytes(row.inputs));
            expect(hex(r.outputs)).toBe(row.outputs);
            expect(r.newState.length).toBe(0);
            expect(hex(evaluate(nl, hexToBytes(row.inputs)))).toBe(row.outputs);
          }
        });
      }

      if (v.beats) {
        const beats = v.beats;
        test(`${beats.length} beats, each from its stated state`, () => {
          for (const b of beats) {
            const r = step(nl, hexToBytes(b.state), hexToBytes(b.inputs));
            expect(hex(r.newState)).toBe(b.newState);
            expect(hex(r.outputs)).toBe(b.outputs);
          }
        });

        test('the beats form one run from the all-zero state', () => {
          let state: Uint8Array = new Uint8Array((v.nState + 7) >> 3);
          for (const b of beats) {
            expect(hex(state)).toBe(b.state);
            const r = step(nl, state, hexToBytes(b.inputs));
            expect(hex(r.outputs)).toBe(b.outputs);
            state = r.newState;
          }
        });

        test('evaluate refuses a circuit with state, as the contract does', () => {
          expect(() => evaluate(nl, new Uint8Array(1))).toThrow('has latch: use step');
        });
      }
    });
  }

  test('popcount8_3151 really is a population count (independent of the stored table)', () => {
    const v = vectors.valid.find((x) => x.name === 'popcount8_3151')!;
    const nl = parse(hexToBytes(v.netlist), v.nIn, v.nOut);
    expect(nl.nNand).toBe(55);
    expect(nl.byteLength).toBe(385);
    expect(nl.gateCount).toBe(55);
    for (let x = 0; x < 256; x++) {
      let ones = 0;
      for (let i = 0; i < 8; i++) ones += (x >> i) & 1;
      expect(step(nl, [], [x]).outputs[0]).toBe(ones);
    }
  });

  test('ref_with_state pins the state layout: LATCH is bit 0, the REF block is bit 1', () => {
    const v = vectors.valid.find((x) => x.name === 'ref_with_state')!;
    const nl = parse(hexToBytes(v.netlist), v.nIn, v.nOut, resolverFor(v.refs));
    expect(nl.nLatch).toBe(1);
    expect(nl.nRef).toBe(1);
    expect(nl.depth).toBe(1);
    expect(nl.gateCount).toBe(2 + nl.refs[0].sub.gateCount);
    expect(nl.stateBase[0]).toBe(0);
    expect(nl.stateBase[1]).toBe(1);
    expect(nl.refs[0].cpu).toBe('0x00000000000000000000000000000000000000aa');
    expect(nl.refs[0].id).toBe(1n);
  });
});

describe('ill-formed netlists are rejected', () => {
  // What each vector must be rejected for, in this implementation's error codes.
  const expected: Record<string, Tap20ErrorCode> = {
    unknown_opcode: 'bad-opcode',
    truncated_record: 'truncated',
    nand_forward_reference: 'future-signal',
    nOut_zero: 'pins',
    output_is_an_input: 'too-few-signals',
    more_outputs_than_elements: 'too-few-signals',
    ref_arity_mismatch: 'ref-arity',
    ref_target_not_registered: 'ref-unresolved',
  };

  test('all eight named vectors are present', () => {
    expect(vectors.illFormed.map((v) => v.name).sort()).toEqual(Object.keys(expected).sort());
  });

  for (const v of vectors.illFormed) {
    test(`${v.name} (${v.reason})`, () => {
      let caught: unknown;
      try {
        parse(hexToBytes(v.netlist), v.nIn, v.nOut, resolverFor(v.refs));
      } catch (e) {
        caught = e;
      }
      expect(caught).toBeInstanceOf(Tap20Error);
      expect((caught as Tap20Error).code).toBe(expected[v.name]);
    });
  }
});

describe('packing edge cases (TAP-20 section 5)', () => {
  const v = vectors.valid.find((x) => x.name === vectors.packingEdgeCases.circuit)!;
  const nl = parse(hexToBytes(v.netlist), v.nIn, v.nOut);
  for (const c of vectors.packingEdgeCases.cases) {
    test(c.case, () => {
      expect(hex(step(nl, new Uint8Array(0), hexToBytes(c.inputs)).outputs)).toBe(c.outputs);
    });
  }
});
