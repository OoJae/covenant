// Small shared pieces: addresses, copy buttons, terminal commands.

import { useEffect, useState } from 'preact/hooks';
import { explorer } from '../config.ts';
import { shortAddress } from '../format.ts';

/** An address linking to the explorer, shortened unless `full`. */
export function Address({ value, full }: { value: string; full?: boolean }) {
  return (
    <a class="mono" href={explorer(value)} target="_blank" rel="noreferrer noopener" title={`${value} on OKLink`}>
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
    <button type="button" class="small" onClick={() => void copyText(text).then((ok) => setState(ok ? 'ok' : 'fail'))}>
      {state === 'ok' ? 'copied' : state === 'fail' ? 'select and copy by hand' : label}
    </button>
  );
}

/** A terminal command with a copy button. */
export function Command({ label, line }: { label?: string; line: string }) {
  return (
    <div class="command">
      {label && <div class="muted">{label}</div>}
      <pre class="mono">{line}</pre>
      <CopyButton text={line} />
    </div>
  );
}
