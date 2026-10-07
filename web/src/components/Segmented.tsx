// A segmented switch (its own module, so the entry script does not carry it: only on-demand pages use it).
// Styles: src/styles/components.css (.segmented).

import type { ComponentChildren } from 'preact';

/**
 * A segmented switch: one choice of a few, the chosen one under a thumb that slides with the toggle ease. Each
 * option is a button with aria-pressed, so it reads as a set of toggles.
 */
export function Segmented<T extends string | number | boolean>({
  label,
  options,
  value,
  onChange,
}: {
  label: string;
  options: { value: T; text: ComponentChildren }[];
  value: T;
  onChange: (v: T) => void;
}) {
  const i = Math.max(
    0,
    options.findIndex((o) => o.value === value),
  );
  return (
    <div class="segmented" role="group" aria-label={label} style={{ '--n': options.length, '--i': i }}>
      <span class="segmented__thumb" aria-hidden="true" />
      {options.map((o) => (
        <button type="button" key={String(o.value)} aria-pressed={o.value === value} onClick={() => onChange(o.value)}>
          {o.text}
        </button>
      ))}
    </div>
  );
}
