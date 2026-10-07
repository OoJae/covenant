// The die shot: a canvas that fits its container and reports the cell under the pointer. The die is always drawn
// on silicon (brand system: silicon is everything the chip computes), with a theme built here from the brand
// tokens, so @covenant/dieshot keeps its own two themes untouched.

import { useEffect, useRef } from 'preact/hooks';
import { createDieShot, type DieShot, type Picked, type Theme } from '@covenant/dieshot';
import type { Netlist } from '@covenant/tap20';

/** Tallest the canvas may get, in CSS pixels. */
const MAX_HEIGHT = 700;

// The raw palette of src/styles/tokens.css, read from the page when it is there (one source of truth), with the
// same values as fallbacks for a page without the stylesheet.
const FALLBACK: Record<string, string> = {
  '--wafer': '#0b0d10',
  '--wafer-2': '#12161b',
  '--quartz': '#e8e4da',
  '--quartz-2': '#8e949c',
  '--bond': '#e6b450',
  '--route-res-si': '#3fd3c0',
  '--route-allow-si': '#7aa7ff',
};

function token(name: string): string {
  const v = typeof getComputedStyle === 'function' ? getComputedStyle(document.documentElement).getPropertyValue(name).trim() : '';
  return /^#[0-9a-f]{6}$/i.test(v) ? v : FALLBACK[name];
}

const alpha = (hex: string, a: number): string =>
  `rgba(${parseInt(hex.slice(1, 3), 16)},${parseInt(hex.slice(3, 5), 16)},${parseInt(hex.slice(5, 7), 16)},${a})`;

/**
 * The die on silicon: logic that holds 1 in Bond gold, latches that hold 1 in quartz (the Seal's colour: memory),
 * cells that hold 0 at quartz 8% (as the Seal's off cells), wires in quartz and the state loop in gold (both at the
 * renderer's 8% alpha), lit pads in the reserve route's hue. The renderer draws every lit pad in one colour, so
 * output pads cannot take one route hue each without a change to the package.
 */
export function siliconDieTheme(): Theme {
  const quartz = token('--quartz');
  return {
    bg: token('--wafer'),
    core: token('--wafer-2'),
    strip: token('--wafer-2'),
    wire: quartz,
    feedback: token('--bond'),
    off: alpha(quartz, 0.08),
    on: token('--bond'),
    latchOff: alpha(quartz, 0.12),
    latchOn: quartz,
    padOff: alpha(quartz, 0.1),
    padOn: token('--route-res-si'),
    pulse: quartz,
    outline: alpha(quartz, 0.16),
    label: token('--quartz-2'),
    select: token('--route-allow-si'),
  };
}

interface DieProps {
  netlist: Netlist;
  /** Called with the renderer once it exists, and with null when it is torn down. */
  onReady: (die: DieShot | null) => void;
  onHover: (cell: Picked | null) => void;
  onPick: (cell: Picked) => void;
  label?: string;
  /** Tallest the canvas may get, in CSS pixels (default 700). */
  maxHeight?: number;
}

export function Die({ netlist, onReady, onHover, onPick, label, maxHeight = MAX_HEIGHT }: DieProps) {
  const wrap = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const die = useRef<DieShot | null>(null);
  const last = useRef<string>('');

  useEffect(() => {
    const el = canvas.current!;
    const box = wrap.current!;
    const d = createDieShot(el, netlist, { theme: siliconDieTheme(), maxScale: 8 });
    die.current = d;
    // As wide as the container allows, but never taller than maxHeight.
    const fit = (): void => d.resize(Math.min(box.clientWidth, (d.width * maxHeight) / d.height));
    fit();
    const observer = new ResizeObserver(fit);
    observer.observe(box);
    onReady(d);
    return () => {
      observer.disconnect();
      onReady(null);
      d.destroy();
      die.current = null;
    };
  }, [netlist]);

  const at = (e: MouseEvent): Picked | null => {
    const d = die.current;
    if (!d) return null;
    const r = canvas.current!.getBoundingClientRect();
    return d.pick(e.clientX - r.left, e.clientY - r.top);
  };

  return (
    <div class="die silicon" ref={wrap}>
      <canvas
        ref={canvas}
        role="img"
        aria-label={label ?? `Die shot of the circuit: ${netlist.gateCount} gates laid out from the netlist bytes`}
        onPointerMove={(e) => {
          const cell = at(e);
          const key = cell ? `${cell.signal}/${cell.output}` : '';
          if (key === last.current) return;
          last.current = key;
          die.current?.select(cell ? cell.signal : -1, cell ? cell.output : -1);
          onHover(cell);
        }}
        onPointerLeave={() => {
          last.current = '';
          die.current?.select(-1);
          onHover(null);
        }}
        onClick={(e) => {
          const cell = at(e);
          if (cell) onPick(cell);
        }}
      />
    </div>
  );
}
