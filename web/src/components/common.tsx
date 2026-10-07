// Small shared pieces: addresses, copy buttons, terminal commands.

import { useEffect, useState } from 'preact/hooks';
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

async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // Clipboard API unavailable (insecure context or denied): fall back to a selection.
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    let done = false;
    try {
      done = document.execCommand('copy');
    } catch {
      done = false;
    }
    area.remove();
    return done;
  }
}

export function CopyButton({ text, label = 'copy' }: { text: string; label?: string }) {
  const [state, setState] = useState<'idle' | 'ok' | 'fail'>('idle');
  useEffect(() => {
    if (state === 'idle') return;
    const t = setTimeout(() => setState('idle'), 1500);
    return () => clearTimeout(t);
  }, [state]);
  return (
    <button type="button" class="small copy press" data-state={state} onClick={() => void copyText(text).then((ok) => setState(ok ? 'ok' : 'fail'))}>
      <span aria-live="polite">
        {/* a new span per state, so the label rises in again each time it changes */}
        <span key={state} class="copy__label">
          {state === 'ok' ? 'copied' : state === 'fail' ? 'select and copy by hand' : label}
        </span>
      </span>
    </button>
  );
}

/** A terminal command with a copy button: a silicon block, the prompt drawn by the stylesheet. */
export function Command({ label, line }: { label?: string; line: string }) {
  return (
    <div class="terminal silicon">
      {label && <div class="terminal__label">{label}</div>}
      <pre class="mono">{line}</pre>
      <CopyButton text={line} />
    </div>
  );
}
