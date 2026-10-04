// Deterministic floorplan of a TAP-20 netlist.
//
// Rules (integers only; no randomness, no force layout, nothing that depends on the machine):
//   - level: constants, inputs and LATCH outputs are level 0; a NAND is 1 + max(level of its
//     inputs); a REF macro is 1 + max(level of its inputs) for each signal it produces;
//   - the logic cells of a block are sorted by (level, record index) and fill the block
//     column-major, so data flows left to right;
//   - the LATCH cells of a block form a register strip on the block's right edge, in record order;
//   - constants and inputs are pads on the die's left edge, outputs are pads on its right edge;
//   - without a block map the whole circuit is one block; with one, blocks are packed by a
//     squarified treemap in block order, area proportional to their cell count.
// `layoutHash` is the SHA-256 of every position, so two builds can be shown to agree.

import { sha256Hex } from './sha256.ts';

/** The parts of a parsed netlist the layout reads. `@covenant/tap20`'s `Netlist` satisfies it. */
export interface DieNetlist {
  nIn: number;
  nOut: number;
  /** Number of records. */
  n: number;
  nSignals: number;
  /** 0 = NAND, 1 = LATCH, 2 = REF. */
  op: Uint8Array;
  /** NAND: input a. LATCH: d. */
  a: Uint32Array;
  /** NAND: input b. REF: index into `refs`. */
  b: Uint32Array;
  /** First signal produced by each record. */
  out: Uint32Array;
  /** LATCH: its state bit. */
  stateBase: Uint32Array;
  refs: readonly { nIns: number; nOuts: number; ins: Uint32Array }[];
}

/** Names for runs of records, as emitted by the chip compiler from the Verilog hierarchy. */
export interface BlockMap {
  names: readonly string[];
  /** `count` records starting at record `first` belong to block `names[block]`. */
  runs: readonly { first: number; count: number; block: number }[];
}

/**
 * Decode a block map as the chip compiler is planned to emit it (format not frozen yet):
 * 7-byte runs of `firstRecord:u24 count:u24 blockId:u8`, big-endian,
 * with the block names supplied alongside. Throws on a length that is not a multiple of 7 or
 * a block id without a name; `layout` checks the record ranges.
 */
export function decodeBlockMap(bytes: ArrayLike<number>, names: readonly string[]): BlockMap {
  if (bytes.length % 7 !== 0) throw new RangeError('block map: length is not a multiple of 7 bytes');
  const runs: { first: number; count: number; block: number }[] = [];
  for (let p = 0; p < bytes.length; p += 7) {
    const block = bytes[p + 6];
    if (block >= names.length) throw new RangeError(`block map: block ${block} has no name`);
    runs.push({
      first: (bytes[p] << 16) | (bytes[p + 1] << 8) | bytes[p + 2],
      count: (bytes[p + 3] << 16) | (bytes[p + 4] << 8) | bytes[p + 5],
      block,
    });
  }
  return { names, runs };
}

export const KIND_CONST = 0;
export const KIND_INPUT = 1;
export const KIND_NAND = 2;
export const KIND_LATCH = 3;
export const KIND_REF = 4;

/** Target aspect of the logic area, columns : rows (3,400 cells come out as about 68 x 50). */
export const ASPECT_COLS = 68;
export const ASPECT_ROWS = 50;

const OP_NAND = 0;
const OP_LATCH = 1;

export interface Block {
  name: string;
  /** Rectangle in die cells. */
  x: number;
  y: number;
  w: number;
  h: number;
  /** Logic cells (NAND gates and REF outputs) and LATCH cells in this block. */
  logic: number;
  latches: number;
  /** First column of the register strip (equals x + w when the block has no LATCH). */
  stripX: number;
}

export interface Layout {
  /** Die size in cells, pads included. */
  cols: number;
  rows: number;
  /** Cell of every signal: constants and inputs on the left edge, then one cell per produced signal. */
  x: Uint16Array;
  y: Uint16Array;
  /** KIND_* of every signal. */
  kind: Uint8Array;
  /** Level of every signal. */
  level: Uint32Array;
  maxLevel: number;
  /** Record that produces each signal, or -1 for constants and inputs. */
  element: Int32Array;
  /** Cell of output pad j; it is driven by signal nSignals - nOut + j. */
  outX: Uint16Array;
  outY: Uint16Array;
  /** The logic area. */
  core: { x: number; y: number; w: number; h: number };
  blocks: Block[];
  /** rows * cols entries: the signal in that cell, -2 - j for output pad j, or -1 if empty. */
  grid: Int32Array;
  /** SHA-256 (hex) of the die size and every position. */
  layoutHash: string;
}

// Exact for the non-negative integers used here (far below 2^31).
const cdiv = (a: number, b: number): number => Math.floor((a + b - 1) / b);

interface Item {
  logic: number;
  latches: number;
  area: number;
}
interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

// Cells a block needs along a row of thickness `t`. `vertical`: the block is t wide and the
// result tall; otherwise it is t tall and the result wide. -1 if no length works.
function minLength(it: Item, t: number, vertical: boolean): number {
  if (!vertical) return Math.max(1, cdiv(it.logic, t) + cdiv(it.latches, t));
  if (t < (it.logic > 0 ? 1 : 0) + (it.latches > 0 ? 1 : 0)) return -1;
  let len = Math.max(1, cdiv(it.area, t));
  while (cdiv(it.logic, len) + cdiv(it.latches, len) > t) len++;
  return len;
}

// Worst aspect ratio of a treemap row, as an exact fraction: max(L^2 * rmax / s^2, s^2 / (L^2 * rmin)).
function worst(len: number, sum: number, rmin: number, rmax: number): [bigint, bigint] {
  const l2 = BigInt(len) * BigInt(len);
  const s2 = BigInt(sum) * BigInt(sum);
  const p: [bigint, bigint] = [l2 * BigInt(rmax), s2];
  const q: [bigint, bigint] = [s2, l2 * BigInt(rmin)];
  return p[0] * q[1] >= q[0] * p[1] ? p : q;
}

// Squarified treemap (Bruls, Huizing, van Wijk) on a cell grid, items kept in the given order.
// Every item gets a rectangle large enough for its cells; null if the area is too small.
function squarify(items: readonly Item[], width: number, height: number): Rect[] | null {
  const rects: Rect[] = [];
  let x = 0;
  let y = 0;
  let w = width;
  let h = height;
  let i = 0;
  while (i < items.length) {
    if (w <= 0 || h <= 0) return null;
    const vertical = w >= h; // a row is laid along the shorter side
    const side = vertical ? h : w;
    const room = vertical ? w : h;

    // Grow the row while its worst aspect ratio does not get worse.
    let j = i + 1;
    let sum = items[i].area;
    let rmin = sum;
    let rmax = sum;
    while (j < items.length) {
      const a = items[j].area;
      const before = worst(side, sum, rmin, rmax);
      const after = worst(side, sum + a, Math.min(rmin, a), Math.max(rmax, a));
      if (after[0] * before[1] > before[0] * after[1]) break;
      sum += a;
      rmin = Math.min(rmin, a);
      rmax = Math.max(rmax, a);
      j++;
    }

    // Thickness of the row: the last row takes whatever is left.
    const last = j === items.length;
    let t = last ? room : cdiv(sum, side);
    const lens: number[] = [];
    for (;;) {
      if (t > room) return null;
      lens.length = 0;
      let used = 0;
      for (let k = i; k < j && used <= side; k++) {
        const len = minLength(items[k], t, vertical);
        if (len < 0) {
          used = side + 1;
          break;
        }
        lens.push(len);
        used += len;
      }
      if (used <= side) {
        // Hand out the slack in proportion to area, then one cell at a time, so the row is full.
        let slack = side - used;
        const total = slack;
        for (let k = 0; k < lens.length; k++) {
          const extra = Math.floor((total * items[i + k].area) / sum);
          lens[k] += extra;
          slack -= extra;
        }
        for (let k = 0; slack > 0; k = (k + 1) % lens.length, slack--) lens[k]++;
        break;
      }
      if (last) return null;
      t++;
    }

    let pos = 0;
    for (let k = 0; k < lens.length; k++) {
      rects.push(vertical ? { x, y: y + pos, w: t, h: lens[k] } : { x: x + pos, y, w: lens[k], h: t });
      pos += lens[k];
    }
    if (vertical) {
      x += t;
      w -= t;
    } else {
      y += t;
      h -= t;
    }
    i = j;
  }
  return rects;
}

// Rows of a logic area holding `cells` cells at the target aspect: the least h with
// h * h * ASPECT_COLS >= cells * ASPECT_ROWS.
function rowsFor(cells: number): number {
  let h = 1;
  while (h * h * ASPECT_COLS < cells * ASPECT_ROWS) h++;
  return h;
}

export function layout(nl: DieNetlist, map?: BlockMap): Layout {
  const S = nl.nSignals;
  const n = nl.n;
  const firstProduced = 2 + nl.nIn;

  // Levels.
  const level = new Uint32Array(S);
  const kind = new Uint8Array(S);
  const element = new Int32Array(S).fill(-1);
  kind[0] = KIND_CONST;
  kind[1] = KIND_CONST;
  for (let i = 0; i < nl.nIn; i++) kind[2 + i] = KIND_INPUT;
  let maxLevel = 0;
  for (let e = 0; e < n; e++) {
    const o = nl.out[e];
    const op = nl.op[e];
    if (op === OP_NAND) {
      const la = level[nl.a[e]];
      const lb = level[nl.b[e]];
      const l = 1 + (la > lb ? la : lb);
      level[o] = l;
      kind[o] = KIND_NAND;
      element[o] = e;
      if (l > maxLevel) maxLevel = l;
    } else if (op === OP_LATCH) {
      kind[o] = KIND_LATCH;
      element[o] = e;
    } else {
      const r = nl.refs[nl.b[e]];
      let l = 0;
      for (let i = 0; i < r.nIns; i++) if (level[r.ins[i]] > l) l = level[r.ins[i]];
      l += 1;
      for (let k = 0; k < r.nOuts; k++) {
        level[o + k] = l;
        kind[o + k] = KIND_REF;
        element[o + k] = e;
      }
      if (r.nOuts > 0 && l > maxLevel) maxLevel = l;
    }
  }

  // Blocks: one per name in the map (plus one for records no run covers), or a single block.
  const blockOf = new Int32Array(n);
  const names: string[] = map ? [...map.names] : [''];
  if (map) {
    blockOf.fill(-1);
    for (const r of map.runs) {
      const ok =
        Number.isInteger(r.first) && Number.isInteger(r.count) && Number.isInteger(r.block) &&
        r.first >= 0 && r.count >= 0 && r.first + r.count <= n && r.block >= 0 && r.block < map.names.length;
      if (!ok) throw new RangeError(`block map: run {first ${r.first}, count ${r.count}, block ${r.block}} is out of range`);
      blockOf.fill(r.block, r.first, r.first + r.count);
    }
    let unmapped = false;
    for (let e = 0; e < n; e++) {
      if (blockOf[e] < 0) {
        blockOf[e] = map.names.length;
        unmapped = true;
      }
    }
    if (unmapped) names.push('(unmapped)');
  }
  const items: Item[] = names.map(() => ({ logic: 0, latches: 0, area: 0 }));
  let logicTotal = 0;
  for (let e = 0; e < n; e++) {
    const it = items[blockOf[e]];
    const op = nl.op[e];
    const cells = op === OP_NAND || op === OP_LATCH ? 1 : nl.refs[nl.b[e]].nOuts;
    if (op === OP_LATCH) it.latches += 1;
    else {
      it.logic += cells;
      logicTotal += cells;
    }
    it.area += cells;
  }

  // Block rectangles inside the logic area.
  const used = items.map((it, b) => (it.area > 0 ? b : -1)).filter((b) => b >= 0);
  const rectOf: (Rect | undefined)[] = new Array(names.length);
  const totalCells = S - firstProduced;
  let coreW = 1;
  let coreH = rowsFor(totalCells);
  let packed: Rect[] | null = null;
  if (used.length > 1) {
    const packItems = used.map((b) => items[b]);
    let w = cdiv(totalCells, coreH);
    let h = coreH;
    for (let tries = 0; tries < 10000 && !packed; tries++) {
      packed = squarify(packItems, w, h);
      if (packed) {
        coreW = w;
        coreH = h;
      } else if (w * ASPECT_ROWS <= h * ASPECT_COLS) w++;
      else h++;
    }
  }
  if (packed) {
    used.forEach((b, k) => {
      rectOf[b] = packed![k];
    });
  } else {
    // One block (no map, a map naming a single block, or a map that could not be packed).
    let logic = 0;
    let latches = 0;
    for (const it of items) {
      logic += it.logic;
      latches += it.latches;
    }
    coreW = Math.max(1, cdiv(logic, coreH) + cdiv(latches, coreH));
    const whole = { x: 0, y: 0, w: coreW, h: coreH };
    if (used.length <= 1) {
      for (const b of used) rectOf[b] = whole;
    } else {
      items.length = 0;
      items.push({ logic, latches, area: logic + latches });
      names.length = 0;
      names.push('');
      blockOf.fill(0);
      rectOf.length = 0;
      rectOf.push(whole);
    }
  }

  // Pads: constants and inputs on the left, outputs on the right, one logic row per pad row.
  const padSlot = (i: number, count: number): [col: number, row: number] =>
    count <= coreH ? [0, Math.floor(((2 * i + 1) * coreH) / (2 * count))] : [Math.floor(i / coreH), i % coreH];
  const leftCols = cdiv(firstProduced, coreH);
  const rightCols = cdiv(nl.nOut, coreH);
  const coreX = leftCols + 1;
  const cols = coreX + coreW + 1 + rightCols;
  const rows = coreH;
  if (cols > 65535 || rows > 65535) throw new RangeError('circuit is too large to lay out');

  const x = new Uint16Array(S);
  const y = new Uint16Array(S);
  for (let s = 0; s < firstProduced; s++) {
    const [c, r] = padSlot(s, firstProduced);
    x[s] = c;
    y[s] = r;
  }
  const outX = new Uint16Array(nl.nOut);
  const outY = new Uint16Array(nl.nOut);
  for (let j = 0; j < nl.nOut; j++) {
    const [c, r] = padSlot(j, nl.nOut);
    outX[j] = coreX + coreW + 1 + c;
    outY[j] = r;
  }

  // Logic cells: a stable counting sort by level over signals in index order gives
  // (level, record index) order; each block is then filled column-major from its left edge.
  const start = new Uint32Array(maxLevel + 2);
  for (let s = firstProduced; s < S; s++) if (kind[s] !== KIND_LATCH) start[level[s] + 1]++;
  for (let l = 1; l < start.length; l++) start[l] += start[l - 1];
  const sorted = new Uint32Array(logicTotal);
  for (let s = firstProduced; s < S; s++) if (kind[s] !== KIND_LATCH) sorted[start[level[s]]++] = s;
  const filled = new Uint32Array(names.length);
  for (let k = 0; k < sorted.length; k++) {
    const s = sorted[k];
    const b = blockOf[element[s]];
    const r = rectOf[b]!;
    const q = filled[b]++;
    x[s] = coreX + r.x + Math.floor(q / r.h);
    y[s] = r.y + (q % r.h);
  }
  // Register strips: LATCH cells in record order, column-major, on the block's right edge.
  const stripX = names.map((_, b) => {
    const r = rectOf[b];
    return r ? r.x + r.w - cdiv(items[b].latches, r.h) : 0;
  });
  filled.fill(0);
  for (let e = 0; e < n; e++) {
    if (nl.op[e] !== OP_LATCH) continue;
    const b = blockOf[e];
    const r = rectOf[b]!;
    const q = filled[b]++;
    const s = nl.out[e];
    x[s] = coreX + stripX[b] + Math.floor(q / r.h);
    y[s] = r.y + (q % r.h);
  }

  const blocks: Block[] = [];
  names.forEach((name, b) => {
    const r = rectOf[b];
    if (r) {
      blocks.push({ name, x: coreX + r.x, y: r.y, w: r.w, h: r.h, logic: items[b].logic, latches: items[b].latches, stripX: coreX + stripX[b] });
    }
  });

  const grid = new Int32Array(cols * rows).fill(-1);
  for (let s = 0; s < S; s++) grid[y[s] * cols + x[s]] = s;
  for (let j = 0; j < nl.nOut; j++) grid[outY[j] * cols + outX[j]] = -2 - j;

  return {
    cols,
    rows,
    x,
    y,
    kind,
    level,
    maxLevel,
    element,
    outX,
    outY,
    core: { x: coreX, y: 0, w: coreW, h: coreH },
    blocks,
    grid,
    layoutHash: hashPositions(cols, rows, x, y, outX, outY),
  };
}

// SHA-256 over: the tag, then cols, rows, signal count and output count as u32 big-endian, then
// (x, y) of every signal and of every output pad as u16 big-endian.
function hashPositions(cols: number, rows: number, x: Uint16Array, y: Uint16Array, outX: Uint16Array, outY: Uint16Array): string {
  const tag = 'covenant-dieshot-layout-v1';
  const bytes = new Uint8Array(tag.length + 16 + 4 * (x.length + outX.length));
  let p = 0;
  for (let i = 0; i < tag.length; i++) bytes[p++] = tag.charCodeAt(i);
  const u32 = (v: number): void => {
    bytes[p++] = (v >>> 24) & 255;
    bytes[p++] = (v >>> 16) & 255;
    bytes[p++] = (v >>> 8) & 255;
    bytes[p++] = v & 255;
  };
  const u16 = (v: number): void => {
    bytes[p++] = (v >>> 8) & 255;
    bytes[p++] = v & 255;
  };
  u32(cols);
  u32(rows);
  u32(x.length);
  u32(outX.length);
  for (let s = 0; s < x.length; s++) {
    u16(x[s]);
    u16(y[s]);
  }
  for (let j = 0; j < outX.length; j++) {
    u16(outX[j]);
    u16(outY[j]);
  }
  return sha256Hex(bytes);
}
