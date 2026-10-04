// The bit editor used on the circuit page.

import { useEffect, useState } from 'preact/hooks';
import { bytesToHex, getBit, packBits, unpackBits } from '@covenant/tap20';
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
  useEffect(() => {
    setDraft(hex);
    setBad(false);
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
  for (let i = 0; i < n; i++) ones += getBit(value, i);

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
        <button type="button" class="small" onClick={() => fill(() => 0)}>all 0</button>
        <button type="button" class="small" onClick={() => fill(() => 1)}>all 1</button>
        <button type="button" class="small" onClick={random}>random</button>
      </div>
      {bad && <div class="warn">Not hex. Use an even number of digits 0-9 a-f; bit 0 is the lowest bit of the first byte.</div>}
      {n <= GRID_LIMIT ? (
        <div
          class="bitgrid"
          onClick={(e) => {
            const i = (e.target as HTMLElement).dataset?.i;
            if (i !== undefined) toggle(Number(i));
          }}
        >
          {groups.map((g) => (
            <span class="byte" key={g[0]}>
              {g.map((i) => (
                <button
                  type="button"
                  key={i}
                  data-i={i}
                  class={getBit(value, i) ? 'bit on' : 'bit'}
                  aria-pressed={getBit(value, i) === 1}
                  title={`${noun} ${i}`}
                />
              ))}
            </span>
          ))}
        </div>
      ) : (
        <div class="muted">Too many bits for a grid; edit the hex.</div>
      )}
    </fieldset>
  );
}
