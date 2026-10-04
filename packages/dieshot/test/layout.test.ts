import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'vitest';
import { hexToBytes, parse } from '@covenant/tap20';
import { decodeBlockMap, KIND_CONST, KIND_INPUT, KIND_LATCH, KIND_NAND, KIND_REF, layout, sha256Hex, type BlockMap, type DieNetlist, type Layout } from '../src/index.ts';
import { prng, synthetic } from './helpers.ts';

// The published TAP-20 vectors (CC0), shared with the tap20 package's tests.
const vectors = JSON.parse(readFileSync(new URL('../../tap20/test/fixtures/tap20-vectors.json', import.meta.url), 'utf8')) as {
  valid: { name: string; nIn: number; nOut: number; netlist: string }[];
};
const popcount = vectors.valid.find((v) => v.name === 'popcount8_3151')!;

// Every cell of the die holds at most one thing, everything is inside the die, and the grid
// index agrees with the coordinates.
function checkGeometry(nl: DieNetlist, lay: Layout): void {
  const seen = new Set<number>();
  const put = (x: number, y: number): void => {
    expect(x).toBeGreaterThanOrEqual(0);
    expect(y).toBeGreaterThanOrEqual(0);
    expect(x).toBeLessThan(lay.cols);
    expect(y).toBeLessThan(lay.rows);
    const key = y * lay.cols + x;
    expect(seen.has(key)).toBe(false);
    seen.add(key);
  };
  for (let s = 0; s < nl.nSignals; s++) put(lay.x[s], lay.y[s]);
  for (let j = 0; j < nl.nOut; j++) put(lay.outX[j], lay.outY[j]);
  expect(seen.size).toBe(nl.nSignals + nl.nOut);
  for (let s = 0; s < nl.nSignals; s++) expect(lay.grid[lay.y[s] * lay.cols + lay.x[s]]).toBe(s);
  for (let j = 0; j < nl.nOut; j++) expect(lay.grid[lay.outY[j] * lay.cols + lay.outX[j]]).toBe(-2 - j);
  let empty = 0;
  for (const g of lay.grid) if (g === -1) empty++;
  expect(empty).toBe(lay.cols * lay.rows - nl.nSignals - nl.nOut);
}

describe('sha256', () => {
  test('known answers', () => {
    expect(sha256Hex([])).toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(sha256Hex(new TextEncoder().encode('abc'))).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });

  test('every length 0..300 against node:crypto', () => {
    const rnd = prng(7);
    for (let n = 0; n <= 300; n++) {
      const data = new Uint8Array(n);
      for (let i = 0; i < n; i++) data[i] = rnd() & 255;
      expect(sha256Hex(data)).toBe(createHash('sha256').update(data).digest('hex'));
    }
  });

  test('a 100 KB input', () => {
    const data = new Uint8Array(100_003);
    for (let i = 0; i < data.length; i++) data[i] = (i * 7 + (i >> 9)) & 255;
    expect(sha256Hex(data)).toBe(createHash('sha256').update(data).digest('hex'));
  });
});

describe('levels', () => {
  test('constants, inputs and LATCH outputs are level 0; a NAND is 1 + max(level of its inputs)', () => {
    const nl = synthetic(12, 8, 16, 600, 3);
    const lay = layout(nl);
    expect(lay.level[0]).toBe(0);
    expect(lay.level[1]).toBe(0);
    let max = 0;
    for (let s = 2; s < 2 + nl.nIn; s++) expect(lay.level[s]).toBe(0);
    for (let e = 0; e < nl.n; e++) {
      const s = nl.out[e];
      expect(lay.element[s]).toBe(e);
      if (nl.op[e] === 1) {
        expect(lay.level[s]).toBe(0);
        expect(lay.kind[s]).toBe(KIND_LATCH);
      } else {
        expect(lay.level[s]).toBe(1 + Math.max(lay.level[nl.a[e]], lay.level[nl.b[e]]));
        expect(lay.kind[s]).toBe(KIND_NAND);
        max = Math.max(max, lay.level[s]);
      }
    }
    expect(lay.maxLevel).toBe(max);
    expect(max).toBeGreaterThan(5);
    expect(lay.kind[0]).toBe(KIND_CONST);
    expect(lay.kind[2]).toBe(KIND_INPUT);
    expect(lay.element[0]).toBe(-1);
    expect(lay.element[2]).toBe(-1);
  });

  test('a small circuit by hand', () => {
    // in0 = 2, in1 = 3; g4 = NAND(2, 3) level 1; g5 = NAND(4, 4) level 2; g6 = NAND(5, 2) level 3
    const nl = parse(hexToBytes('0x00000002000003' + '00000004000004' + '00000005000002'), 2, 1);
    const lay = layout(nl);
    expect(Array.from(lay.level)).toEqual([0, 0, 0, 0, 1, 2, 3]);
    expect(lay.maxLevel).toBe(3);
  });
});

describe('single-block floorplan', () => {
  test('3,400 gates come out as about 68 x 50 cells', () => {
    const nl = synthetic(96, 112, 64, 3336, 11);
    const lay = layout(nl);
    expect(lay.core.h).toBe(50);
    expect(lay.core.w).toBe(69); // 67 columns of logic + 2 of register strip
    expect(lay.rows).toBe(50);
    // pads: 98 on the left (2 columns), a gap, the core, a gap, 112 on the right (3 columns)
    expect(lay.core.x).toBe(3);
    expect(lay.cols).toBe(2 + 1 + 69 + 1 + 3);
    expect(lay.blocks).toEqual([{ name: '', x: 3, y: 0, w: 69, h: 50, logic: 3336, latches: 64, stripX: 3 + 67 }]);
    checkGeometry(nl, lay);
  });

  test('logic cells fill column-major in (level, record index) order', () => {
    const nl = synthetic(20, 5, 30, 1500, 5);
    const lay = layout(nl);
    const logic: number[] = [];
    for (let s = 2 + nl.nIn; s < nl.nSignals; s++) if (lay.kind[s] === KIND_NAND) logic.push(s);
    logic.sort((p, q) => lay.level[p] - lay.level[q] || p - q);
    logic.forEach((s, rank) => {
      expect(lay.x[s]).toBe(lay.core.x + Math.floor(rank / lay.core.h));
      expect(lay.y[s]).toBe(rank % lay.core.h);
    });
    // so a cell is never to the left of a cell that feeds it
    for (let e = 0; e < nl.n; e++) {
      if (nl.op[e] !== 0) continue;
      for (const src of [nl.a[e], nl.b[e]]) {
        if (lay.kind[src] === KIND_NAND) expect(lay.x[src]).toBeLessThanOrEqual(lay.x[nl.out[e]]);
      }
    }
    checkGeometry(nl, lay);
  });

  test('LATCH cells form a register strip on the right edge of the logic, in record order', () => {
    const nl = synthetic(20, 5, 130, 1500, 9);
    const lay = layout(nl);
    const [b] = lay.blocks;
    expect(b.stripX).toBe(b.x + b.w - Math.ceil(130 / b.h));
    let k = 0;
    for (let e = 0; e < nl.n; e++) {
      if (nl.op[e] !== 1) continue;
      const s = nl.out[e];
      expect(lay.x[s]).toBe(b.stripX + Math.floor(k / b.h));
      expect(lay.y[s]).toBe(k % b.h);
      k++;
    }
    expect(k).toBe(130);
    for (let s = 2 + nl.nIn; s < nl.nSignals; s++) {
      if (lay.kind[s] === KIND_NAND) expect(lay.x[s]).toBeLessThan(b.stripX);
    }
  });

  test('input pads sit on the left edge and output pads on the right', () => {
    const nl = synthetic(96, 112, 64, 3336, 11);
    const lay = layout(nl);
    for (let s = 0; s < 2 + nl.nIn; s++) expect(lay.x[s]).toBeLessThan(lay.core.x - 1);
    for (let j = 0; j < nl.nOut; j++) expect(lay.outX[j]).toBeGreaterThan(lay.core.x + lay.core.w);
    // fewer pads than rows: one column, spread over the full height, in order
    const few = layout(synthetic(6, 3, 8, 3000, 2));
    const rows: number[] = [];
    for (let s = 0; s < 8; s++) {
      expect(few.x[s]).toBe(0);
      rows.push(few.y[s]);
    }
    expect([...rows].sort((p, q) => p - q)).toEqual(rows);
    expect(new Set(rows).size).toBe(8);
    expect(rows[7] - rows[0]).toBeGreaterThan(few.rows / 2);
    checkGeometry(nl, lay);
  });

  test('tiny circuits and circuits with only latches lay out', () => {
    const one = parse(hexToBytes('0x00000002000003'), 2, 1);
    checkGeometry(one, layout(one));
    const delay = parse(hexToBytes('0x01000002'), 1, 1);
    const lay = layout(delay);
    checkGeometry(delay, lay);
    expect(lay.blocks[0].latches).toBe(1);
    expect(lay.blocks[0].logic).toBe(0);
    const pop = parse(hexToBytes('0x00000002000003000000020000040000000300000400000005000006'), 2, 1);
    checkGeometry(pop, layout(pop));
  });

  test('a REF is a macro: one cell per signal it produces, one level above its inputs', () => {
    const inv = parse(hexToBytes('0x00000002000002'), 1, 1);
    const two = { ...inv, nOut: 2 };
    // signals: in0 = 2; g3 = NAND(2, 2); REF(ins = [3]) -> 4, 5; g6 = NAND(4, 5)
    const rec = [2, ...new Array<number>(19).fill(0), 0xaa, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 0, 0, 3];
    const bytes = Uint8Array.from([0, 0, 0, 2, 0, 0, 2, ...rec, 0, 0, 0, 4, 0, 0, 5]);
    const nl = parse(bytes, 1, 1, () => two);
    const lay = layout(nl);
    expect(Array.from(lay.level)).toEqual([0, 0, 0, 1, 2, 2, 3]);
    expect(lay.kind[4]).toBe(KIND_REF);
    expect(lay.kind[5]).toBe(KIND_REF);
    expect(lay.element[4]).toBe(1);
    expect(lay.element[5]).toBe(1);
    expect(lay.blocks[0].logic).toBe(4);
    checkGeometry(nl, lay);
  });
});

describe('determinism', () => {
  test('the same netlist gives the same positions and the same layoutHash', () => {
    const a = layout(synthetic(96, 112, 64, 3336, 11));
    const b = layout(synthetic(96, 112, 64, 3336, 11));
    expect(b.layoutHash).toBe(a.layoutHash);
    expect(Array.from(b.x)).toEqual(Array.from(a.x));
    expect(Array.from(b.y)).toEqual(Array.from(a.y));
    expect(a.layoutHash).toMatch(/^[0-9a-f]{64}$/);
  });

  test('a different netlist gives a different hash', () => {
    expect(layout(synthetic(96, 112, 64, 3336, 12)).layoutHash).not.toBe(layout(synthetic(96, 112, 64, 3336, 11)).layoutHash);
  });

  test('layoutHash is the SHA-256 of the documented serialisation', () => {
    const nl = synthetic(5, 3, 4, 60, 4);
    const lay = layout(nl);
    const tag = Buffer.from('covenant-dieshot-layout-v1', 'ascii');
    const body = Buffer.alloc(16 + 4 * (nl.nSignals + nl.nOut));
    let p = 0;
    for (const v of [lay.cols, lay.rows, nl.nSignals, nl.nOut]) p = body.writeUInt32BE(v, p);
    for (let s = 0; s < nl.nSignals; s++) {
      p = body.writeUInt16BE(lay.x[s], p);
      p = body.writeUInt16BE(lay.y[s], p);
    }
    for (let j = 0; j < nl.nOut; j++) {
      p = body.writeUInt16BE(lay.outX[j], p);
      p = body.writeUInt16BE(lay.outY[j], p);
    }
    expect(lay.layoutHash).toBe(createHash('sha256').update(tag).update(body).digest('hex'));
  });

  test('pinned hashes: a change to the layout rules must be deliberate', () => {
    const tiny = parse(hexToBytes('0x00000002000003'), 2, 1);
    expect(layout(tiny).layoutHash).toBe(PINNED.nand);
    expect(layout(parse(hexToBytes(popcount.netlist), popcount.nIn, popcount.nOut)).layoutHash).toBe(PINNED.popcount);
    expect(layout(synthetic(96, 112, 64, 3336, 11)).layoutHash).toBe(PINNED.chip);
    expect(layout(synthetic(96, 112, 64, 3336, 11), FOUR_BLOCKS).layoutHash).toBe(PINNED.chipBlocks);
  });
});

// A block map shaped like the Flow Governor's: the latch records, then four logic blocks.
const FOUR_BLOCKS: BlockMap = {
  names: ['log_avg', 'cooldown', 'mode_fsm', 'clamp'],
  runs: [
    { first: 0, count: 24, block: 0 },
    { first: 24, count: 8, block: 1 },
    { first: 32, count: 12, block: 2 },
    { first: 44, count: 20, block: 3 },
    { first: 64, count: 1800, block: 0 },
    { first: 1864, count: 300, block: 1 },
    { first: 2164, count: 500, block: 2 },
    { first: 2664, count: 736, block: 3 },
  ],
};

// Recorded on 2026-10-04. They change only if the layout rules or the hash serialisation change.
const PINNED = {
  nand: 'd82a0b0811e62fe678c99473831084ed895d860ef623b86208e6db491aa084c2',
  popcount: '8e34904ce7a9db878b82f8390d825f1199f0ceaaa35991b79624392ecba6c9f3',
  chip: '320d9a548f449c6c2e22b0fef549a1697e766dd9dfb5d46bc41dd825e197e5bf',
  chipBlocks: '0e36ba16584951a3aacd7eca031da08ca062300cd3e89aaa80a5caa301d5da66',
};

describe('block map (squarified treemap)', () => {
  const nl = synthetic(96, 112, 64, 3336, 11);
  const lay = layout(nl, FOUR_BLOCKS);

  test('one rectangle per named block, tiling the logic area without overlap', () => {
    expect(lay.blocks.map((b) => b.name)).toEqual(['log_avg', 'cooldown', 'mode_fsm', 'clamp']);
    const owner = new Int32Array(lay.cols * lay.rows).fill(-1);
    lay.blocks.forEach((b, i) => {
      expect(b.x).toBeGreaterThanOrEqual(lay.core.x);
      expect(b.y).toBeGreaterThanOrEqual(0);
      expect(b.x + b.w).toBeLessThanOrEqual(lay.core.x + lay.core.w);
      expect(b.y + b.h).toBeLessThanOrEqual(lay.core.h);
      for (let y = b.y; y < b.y + b.h; y++) {
        for (let x = b.x; x < b.x + b.w; x++) {
          expect(owner[y * lay.cols + x]).toBe(-1);
          owner[y * lay.cols + x] = i;
        }
      }
    });
    let covered = 0;
    for (const o of owner) if (o >= 0) covered++;
    expect(covered).toBe(lay.core.w * lay.core.h);
  });

  test('every block is large enough, and area follows cell count', () => {
    expect(lay.blocks.map((b) => [b.logic, b.latches])).toEqual([[1800, 24], [300, 8], [500, 12], [736, 20]]);
    for (const b of lay.blocks) {
      expect(Math.ceil(b.logic / b.h) + Math.ceil(b.latches / b.h)).toBeLessThanOrEqual(b.w);
      const cells = b.logic + b.latches;
      expect(b.w * b.h).toBeGreaterThanOrEqual(cells);
      expect(b.w * b.h).toBeLessThan(cells * 1.2); // slack from rounding to whole cells
    }
    // the logic area keeps roughly the 68:50 aspect, and grows only a little over the flat layout
    expect(lay.core).toEqual({ x: 3, y: 0, w: 70, h: 51 });
  });

  test('each record lies in its own block: logic column-major by (level, index), latches in the strip', () => {
    const blockOfRecord = new Int32Array(nl.n).fill(-1);
    for (const r of FOUR_BLOCKS.runs) blockOfRecord.fill(r.block, r.first, r.first + r.count);
    const perBlock: number[][] = [[], [], [], []];
    const latchRank = [0, 0, 0, 0];
    for (let e = 0; e < nl.n; e++) {
      const b = lay.blocks[blockOfRecord[e]];
      const s = nl.out[e];
      expect(lay.x[s]).toBeGreaterThanOrEqual(b.x);
      expect(lay.x[s]).toBeLessThan(b.x + b.w);
      expect(lay.y[s]).toBeGreaterThanOrEqual(b.y);
      expect(lay.y[s]).toBeLessThan(b.y + b.h);
      if (nl.op[e] === 1) {
        const k = latchRank[blockOfRecord[e]]++;
        expect(lay.x[s]).toBe(b.stripX + Math.floor(k / b.h));
        expect(lay.y[s]).toBe(b.y + (k % b.h));
      } else perBlock[blockOfRecord[e]].push(s);
    }
    perBlock.forEach((list, i) => {
      const b = lay.blocks[i];
      list.sort((p, q) => lay.level[p] - lay.level[q] || p - q);
      list.forEach((s, rank) => {
        expect(lay.x[s]).toBe(b.x + Math.floor(rank / b.h));
        expect(lay.y[s]).toBe(b.y + (rank % b.h));
      });
    });
    checkGeometry(nl, lay);
  });

  test('the map changes positions, not levels, and is deterministic', () => {
    const flat = layout(nl);
    expect(lay.layoutHash).not.toBe(flat.layoutHash);
    expect(Array.from(lay.level)).toEqual(Array.from(flat.level));
    expect(layout(nl, FOUR_BLOCKS).layoutHash).toBe(lay.layoutHash);
  });

  test('records no run covers go to an "(unmapped)" block; an empty block gets no rectangle', () => {
    const partial: BlockMap = { names: ['a', 'nothing', 'b'], runs: [{ first: 0, count: 64, block: 0 }, { first: 64, count: 1000, block: 2 }] };
    const l2 = layout(nl, partial);
    expect(l2.blocks.map((b) => b.name)).toEqual(['a', 'b', '(unmapped)']);
    expect(l2.blocks.map((b) => b.logic + b.latches)).toEqual([64, 1000, 2336]);
    checkGeometry(nl, l2);
  });

  test('a map with one block in use is the single-block layout', () => {
    const one: BlockMap = { names: ['everything'], runs: [{ first: 0, count: nl.n, block: 0 }] };
    const l1 = layout(nl, one);
    expect(l1.layoutHash).toBe(layout(nl).layoutHash);
    expect(l1.blocks[0].name).toBe('everything');
  });

  test('a run outside the netlist or naming no block is refused', () => {
    expect(() => layout(nl, { names: ['a'], runs: [{ first: 0, count: nl.n + 1, block: 0 }] })).toThrow(RangeError);
    expect(() => layout(nl, { names: ['a'], runs: [{ first: 0, count: 1, block: 1 }] })).toThrow(RangeError);
    expect(() => layout(nl, { names: ['a'], runs: [{ first: -1, count: 1, block: 0 }] })).toThrow(RangeError);
  });

  test('decodeBlockMap reads 7-byte runs (firstRecord u24, count u24, blockId u8)', () => {
    const u24 = (v: number): number[] => [(v >> 16) & 255, (v >> 8) & 255, v & 255];
    const bytes = Uint8Array.from(FOUR_BLOCKS.runs.flatMap((r) => [...u24(r.first), ...u24(r.count), r.block]));
    expect(bytes.length).toBe(7 * FOUR_BLOCKS.runs.length);
    const decoded = decodeBlockMap(bytes, FOUR_BLOCKS.names);
    expect(decoded).toEqual(FOUR_BLOCKS);
    expect(layout(nl, decoded).layoutHash).toBe(lay.layoutHash);
    expect(decodeBlockMap(new Uint8Array(0), []).runs).toEqual([]);
    expect(() => decodeBlockMap(bytes.subarray(0, 8), FOUR_BLOCKS.names)).toThrow(RangeError);
    expect(() => decodeBlockMap(bytes, ['only', 'two'])).toThrow(RangeError);
    // a 24-bit record index survives
    expect(decodeBlockMap(Uint8Array.of(0x12, 0x34, 0x56, 0xab, 0xcd, 0xef, 0), ['x']).runs[0]).toEqual({ first: 0x123456, count: 0xabcdef, block: 0 });
  });

  test('many uneven blocks still pack (40 blocks, sizes 1..400)', () => {
    const rnd = prng(99);
    const big = synthetic(40, 40, 200, 6000, 21);
    const names: string[] = [];
    const runs: { first: number; count: number; block: number }[] = [];
    let at = 0;
    while (at < big.n) {
      const count = Math.min(big.n - at, 1 + (rnd() % 400));
      runs.push({ first: at, count, block: names.length });
      names.push(`b${names.length}`);
      at += count;
    }
    const l = layout(big, { names, runs });
    expect(l.blocks.length).toBe(names.length);
    checkGeometry(big, l);
    for (const b of l.blocks) expect(Math.ceil(b.logic / b.h) + Math.ceil(b.latches / b.h)).toBeLessThanOrEqual(b.w);
  });
});

describe('scale', () => {
  test('5,000 and 20,000 gates lay out quickly', () => {
    for (const [gates, limit] of [[5000, 250], [20000, 1000]] as const) {
      const nl = synthetic(133, 199, 243, gates - 243, 31);
      const t0 = performance.now();
      const lay = layout(nl);
      const ms = performance.now() - t0;
      expect(ms).toBeLessThan(limit);
      checkGeometry(nl, lay);
    }
  });

  test('the TAP-20 popcount circuit (55 gates, on-chain bytes) lays out as 8 x 7 cells of logic', () => {
    const nl = parse(hexToBytes(popcount.netlist), popcount.nIn, popcount.nOut);
    const lay = layout(nl);
    expect(lay.core).toEqual({ x: 3, y: 0, w: 8, h: 7 });
    expect(lay.maxLevel).toBe(16);
    expect(lay.blocks[0].latches).toBe(0);
    expect(lay.blocks[0].stripX).toBe(lay.blocks[0].x + lay.blocks[0].w);
    checkGeometry(nl, lay);
  });
});
