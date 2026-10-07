// The Seal: a chip's latches drawn as a square impression, from real state bits only (brand system, plan section C).
// Bit i of the state (TAP-20 bit order: bit i mod 8 of byte floor(i / 8), as @covenant/tap20 packBits) sits at row
// floor(i / side), column i mod side, where side is 8 for the Flow Governor's 64 latches and ceil(sqrt(n)) otherwise.
// The top-left corner is chamfered and carries a gold pin-1 square, next to bit 0.
//
// On-bits use the current text colour (quartz on silicon, ink on paper; `material` pins one), off-bits the same
// colour at 8%. Two optional motions, CSS only, transform and opacity only, off under prefers-reduced-motion (rules
// in src/styles/motion.css): `loading` fills the cells in level order, one diagonal per 60 ms like a wavefront, and
// `press` plays a 1.04 → 1 press each time the state changes.

import { useState } from 'preact/hooks';
import { hexToBytes, unpackBits } from '@covenant/tap20';
import type { Layout } from '../kernel/model.ts';

export interface SealCell {
  /** Bit index in the state vector. */
  i: number;
  row: number;
  col: number;
  on: boolean;
}

/** Cells per side: 8 for 64 latches, ceil(sqrt(n)) otherwise. */
export const sealSide = (n: number): number => Math.max(1, Math.ceil(Math.sqrt(n)));

/** The cells of a state given as hex (the state bytes, or a kernel's bytes32 form; read leniently, as TAP-20 does). */
export function sealCells(hex: string, n: number = 64): SealCell[] {
  let bytes: Uint8Array;
  try {
    bytes = hexToBytes(hex);
  } catch {
    bytes = new Uint8Array(0); // not hex: a cold seal, and the label still names what was given
  }
  const bits = unpackBits(bytes, n);
  const side = sealSide(n);
  return Array.from(bits, (b, i) => ({ i, row: Math.floor(i / side), col: i % side, on: b === 1 }));
}

/** The field a bit belongs to, as an index into `fields`, or -1. */
function fieldIndex(fields: Layout, i: number): number {
  return fields.findIndex(([, off, w]) => i >= off && i < off + w);
}

/** A field's value read from the cells (bit offset first, LSB-first). */
function fieldValue(cells: SealCell[], off: number, w: number): number {
  let v = 0;
  for (let k = w - 1; k >= 0; k--) v = v * 2 + (cells[off + k]?.on ? 1 : 0);
  return v;
}

// Geometry, in SVG units: a 10-unit pitch with 8-unit cells, a 12-unit margin, a 9-unit chamfer.
const PITCH = 10;
const CELL = 8;
const PAD = 12;
const CHAMFER = 9;
const STROKE = 1.5;

export interface SealProps {
  /** The state, as hex. */
  hex: string;
  /** Number of latches (default 64). */
  n?: number;
  /** Rendered width and height in CSS pixels (default 96). */
  size?: number;
  /** What the seal shows, for the accessible name ("State A"); the hex is appended. Default "Latch state". */
  label?: string;
  /** Name the bits on hover: the state's fields as (name, offset, width), e.g. FG_STATE from kernel/chip.ts. */
  fields?: Layout;
  /** Called with the field under the pointer and its value, and with null when the pointer leaves. */
  onField?: (field: { name: string; value: number } | null) => void;
  /** Pin the on-bit colour: quartz (silicon) or ink (paper). Default: the current text colour. */
  material?: 'silicon' | 'paper';
  /** Fill the cells in level order, repeatedly, while the state is not known yet. */
  loading?: boolean;
  /** Play the press (scale 1.04 → 1) when the seal appears and each time `hex` changes. */
  press?: boolean;
  class?: string;
}

const MATERIAL = { silicon: 'var(--quartz, #E8E4DA)', paper: 'var(--ink, #17150F)' } as const;

export function Seal({ hex, n = 64, size = 96, label = 'Latch state', fields, onField, material, loading = false, press = false, class: cls }: SealProps) {
  const [hot, setHot] = useState(-1);
  const cells = sealCells(hex, n);
  const side = sealSide(n);
  const W = 2 * PAD + side * PITCH - (PITCH - CELL);
  const s = STROKE / 2;
  const frame = `M${CHAMFER} ${s}H${W - s}V${W - s}H${s}V${CHAMFER}Z`;

  const pick = (f: number): void => {
    if (f === hot) return;
    setHot(f);
    if (onField && fields) onField(f < 0 ? null : { name: fields[f][0], value: fieldValue(cells, fields[f][1], fields[f][2]) });
  };
  const over = fields
    ? (e: PointerEvent): void => {
        const a = (e.target as Element).getAttribute('data-f');
        pick(a === null ? -1 : Number(a));
      }
    : undefined;

  const classes = ['seal', loading && 'seal-loading', press && !loading && 'seal-press', cls].filter(Boolean).join(' ');
  return (
    <svg
      // A new element per state, so the press animation plays again when the state changes.
      key={press ? hex : undefined}
      class={classes}
      viewBox={`0 0 ${W} ${W}`}
      width={size}
      height={size}
      role="img"
      aria-label={loading ? `${label}, loading` : `${label}, ${hex}`}
      aria-busy={loading ? 'true' : undefined}
      style={material ? { color: MATERIAL[material] } : undefined}
      onPointerOver={over}
      onPointerLeave={fields ? () => pick(-1) : undefined}
    >
      <path d={frame} fill="none" stroke="currentColor" stroke-width={STROKE} stroke-opacity=".32" stroke-linejoin="miter" />
      <rect x="6" y="6" width="4" height="4" style={{ fill: 'var(--bond, #E6B450)' }} />
      {cells.map((c) => {
        const f = fields ? fieldIndex(fields, c.i) : -1;
        const title = fields && f >= 0 ? `bit ${c.i}: ${fields[f][0]} bit ${c.i - fields[f][1]} of ${fields[f][2]}, field value ${fieldValue(cells, fields[f][1], fields[f][2])}` : undefined;
        return (
          <rect
            key={c.i}
            class={loading ? 'seal-cell' : c.on ? 'seal-cell on' : 'seal-cell off'}
            x={PAD + c.col * PITCH}
            y={PAD + c.row * PITCH}
            width={CELL}
            height={CELL}
            fill="currentColor"
            // off at 8%; an off bit of the field under the pointer shows at 32% so the whole field reads
            opacity={c.on && !loading ? undefined : f >= 0 && f === hot ? '.32' : '.08'}
            data-f={f >= 0 ? f : undefined}
            style={{
              ...(loading ? { '--d': c.row + c.col } : null),
              ...(f >= 0 && f === hot ? { stroke: 'var(--bond, #E6B450)', strokeWidth: STROKE } : null),
            }}
          >
            {title && <title>{title}</title>}
          </rect>
        );
      })}
    </svg>
  );
}
