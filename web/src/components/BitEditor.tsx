// The bit editor used on the circuit page. Its cells are the Seal's cells: square, a 1 in the text colour, a 0 at
// 8% of it, bit 0 (pin 1) marked in gold. A cell that changes flips (scaleY, 200 ms) once the editor is on screen.

import { useEffect, useRef, useState } from 'preact/hooks';
import { bytesToHex, packBits, unpackBits } from '@covenant/tap20';
import { packedFromHex } from '../data/circuit.ts';
import { cleanHex } from '../format.ts';

const GRID_LIMIT = 2048;

interface BitEditorProps {
  label: string;
  /** Number of bits. */
  n: number;
  /** Packed LSB-first, exactly ceil(n / 8) bytes. */
  value: Uint8Array;
  onChange: (next: Uint8Array) => void;
  /** What one bit is called in the tooltip, e.g. "input" or "state bit". */
  noun: string;
}

/**
 * Edit a bit vector either bit by bit or as the packed hex the contracts take. Bit i is bit
 * (i mod 8) of byte floor(i / 8), so the grid shows bytes left to right with bit 0 first.
 */
export function BitEditor({ label, n, value, onChange, noun }: BitEditorProps) {
  const hex = bytesToHex(value);
  const [draft, setDraft] = useState(hex);
  const [bad, setBad] = useState(false);
  // The first render draws the cells as they are. From then on a cell whose bit changes gets a new key (its count
  // of changes), so it is a new element and its flip plays once; cells that did not change stay still.
  const bits = unpackBits(value, n);
  const gen = useRef<Uint16Array>(new Uint16Array(n));
  const prev = useRef<Uint8Array | null>(null);
  if (gen.current.length !== n) gen.current = new Uint16Array(n);
  if (prev.current && prev.current.length === n) for (let i = 0; i < n; i++) if (bits[i] !== prev.current[i]) gen.current[i]++;
  prev.current = bits;
  // A flipped cell is a new element: give it the focus its old element had, so the keyboard stays in place.
  const grid = useRef<HTMLDivElement>(null);
  const refocus = useRef<number | null>(null);
  useEffect(() => {
    setDraft(hex);
    setBad(false);
    if (refocus.current !== null) grid.current?.querySelector<HTMLElement>(`[data-i="${refocus.current}"]`)?.focus();
    refocus.current = null;
  }, [hex]);

  const commit = (text: string): void => {
    const h = cleanHex(text);
    if (h === null) return setBad(true);
    setBad(false);
    onChange(packedFromHex(h, n));
  };
  const toggle = (i: number): void => {
    const bits = unpackBits(value, n);
    bits[i] ^= 1;
    onChange(packBits(bits));
  };
  const fill = (f: (i: number) => number): void => {
    const bits = new Uint8Array(n);
    for (let i = 0; i < n; i++) bits[i] = f(i);
    onChange(packBits(bits));
  };
  const random = (): void => {
    const r = new Uint8Array(n);
    crypto.getRandomValues(r);
    fill((i) => r[i] & 1);
  };

  let ones = 0;
  for (let i = 0; i < n; i++) ones += bits[i];

  const groups: number[][] = [];
  if (n <= GRID_LIMIT) for (let i = 0; i < n; i += 8) groups.push(Array.from({ length: Math.min(8, n - i) }, (_, k) => i + k));

  return (
    <fieldset class="bits">
      <legend>
        {label} <span class="muted">{n} bits, {ones} set</span>
      </legend>
      <div class="row">
        <input
          class={`mono hex${bad ? ' bad' : ''}`}
          value={draft}
          spellcheck={false}
          autocomplete="off"
          aria-label={`${label} as packed hex`}
          aria-invalid={bad}
          onInput={(e) => setDraft((e.target as HTMLInputElement).value)}
          onChange={(e) => commit((e.target as HTMLInputElement).value)}
        />
        <button type="button" class="small" onClick={() => fill(() => 0)}>
          all 0
        </button>
        <button type="button" class="small" onClick={() => fill(() => 1)}>
          all 1
        </button>
        <button type="button" class="small" onClick={random}>
          random
        </button>
      </div>
      {bad && <div class="warn">Not hex. Use an even number of digits 0-9 a-f; bit 0 is the lowest bit of the first byte.</div>}
      {n <= GRID_LIMIT ? (
        <div
          ref={grid}
          class="bitgrid"
          onClick={(e) => {
            const t = e.target as HTMLElement;
            const i = t.dataset?.i;
            if (i === undefined) return;
            if (t === document.activeElement) refocus.current = Number(i);
            toggle(Number(i));
          }}
        >
          {groups.map((g) => (
            <span class="byte" key={g[0]}>
              {g.map((i) => {
                const on = bits[i];
                const flips = gen.current[i];
                return (
                  <button
                    type="button"
                    key={`${i}:${flips}`}
                    data-i={i}
                    class={`bit${on ? ' on' : ''}${flips ? ' flip' : ''}`}
                    aria-pressed={on === 1}
                    aria-label={`${noun} ${i}`}
                    title={`${noun} ${i}`}
                  />
                );
              })}
            </span>
          ))}
        </div>
      ) : (
        <div class="muted">Too many bits for a grid; edit the hex.</div>
      )}
    </fieldset>
  );
}
