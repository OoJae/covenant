// Small shared pieces: addresses, copy buttons, terminal commands.

import { CopyButton } from '../motion/copy.tsx';
import { explorer } from '../config.ts';
import { shortAddress } from '../format.ts';

/** An address linking to the explorer, shortened unless `full`. */
export function Address({ value, full }: { value: string; full?: boolean }) {
  return (
    <a class="mono addr" href={explorer(value)} target="_blank" rel="noreferrer noopener" title={`${value} on OKLink`}>
      {full ? value : shortAddress(value)}
    </a>
  );
}

// The copy control is motion/copy.tsx's, everywhere: one set of words (Copy, Copied), one tick, one announcement.
export { CopyButton } from '../motion/copy.tsx';

/** A terminal command with a copy button: a silicon block, the prompt drawn by the stylesheet. */
export function Command({ label, line }: { label?: string; line: string }) {
  return (
    <div class="terminal silicon">
      {label && <div class="terminal__label">{label}</div>}
      <pre class="mono">{line}</pre>
      <CopyButton text={line} small />
    </div>
  );
}
