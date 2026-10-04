// The die shot: a canvas that fits its container, follows the colour scheme, and reports the
// cell under the pointer.

import { useEffect, useRef } from 'preact/hooks';
import { createDieShot, THEME_DARK, THEME_LIGHT, type DieShot, type Picked } from '@covenant/dieshot';
import type { Netlist } from '@covenant/tap20';

/** Tallest the canvas may get, in CSS pixels. */
const MAX_HEIGHT = 700;

interface DieProps {
  netlist: Netlist;
  /** Called with the renderer once it exists, and with null when it is torn down. */
  onReady: (die: DieShot | null) => void;
  onHover: (cell: Picked | null) => void;
  onPick: (cell: Picked) => void;
}

export function Die({ netlist, onReady, onHover, onPick }: DieProps) {
  const wrap = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const die = useRef<DieShot | null>(null);
  const last = useRef<string>('');

  useEffect(() => {
    const el = canvas.current!;
    const box = wrap.current!;
    const scheme = matchMedia('(prefers-color-scheme: dark)');
    const d = createDieShot(el, netlist, { theme: scheme.matches ? THEME_DARK : THEME_LIGHT, maxScale: 8 });
    die.current = d;
    // As wide as the container allows, but never taller than MAX_HEIGHT.
    const fit = (): void => d.resize(Math.min(box.clientWidth, (d.width * MAX_HEIGHT) / d.height));
    fit();
    const observer = new ResizeObserver(fit);
    observer.observe(box);
    const onScheme = (): void => d.setTheme(scheme.matches ? THEME_DARK : THEME_LIGHT);
    scheme.addEventListener('change', onScheme);
    onReady(d);
    return () => {
      observer.disconnect();
      scheme.removeEventListener('change', onScheme);
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
    <div class="die" ref={wrap}>
      <canvas
        ref={canvas}
        role="img"
        aria-label={`Die shot of the circuit: ${netlist.gateCount} gates laid out from the netlist bytes`}
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
