// A copy button for terminal lines: "Copy" turns into "Copied" with a tick for 1.6 s, and says so to screen readers.
// The tick is the icon system's right angle (a short and a long wire, turned 45°); it scales in with the reveal ease,
// transform and opacity only (src/styles/motion.css), and simply appears under prefers-reduced-motion. The button is
// a `.btn`, so it also gets the press.

import { useEffect, useState } from 'preact/hooks';

/** Copies `text`: the Clipboard API, else a selection in a hidden field. True if it worked. */
export async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // Clipboard API unavailable (insecure context or denied): fall back to a selection.
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.cssText = 'position:fixed;opacity:0;pointer-events:none';
    document.body.append(area);
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

export function CopyButton({ text, what = 'command' }: { text: string; what?: string }) {
  const [state, setState] = useState<'idle' | 'ok' | 'fail'>('idle');
  useEffect(() => {
    if (state === 'idle') return;
    const t = setTimeout(() => setState('idle'), 1600);
    return () => clearTimeout(t);
  }, [state]);
  return (
    <>
      <button type="button" class="btn btn--secondary copy" data-state={state} aria-label={`Copy the ${what}`} onClick={() => void copyText(text).then((ok) => setState(ok ? 'ok' : 'fail'))}>
        <svg class="copy__tick" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
          <path d="M4 6.5V10.5H13.5" transform="rotate(-45 8.5 8.5)" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="square" />
        </svg>
        <span class="copy__text">{state === 'ok' ? 'Copied' : state === 'fail' ? 'Select it by hand' : 'Copy'}</span>
      </button>
      <span class="sr-only" role="status">
        {state === 'ok' ? `Copied the ${what}` : state === 'fail' ? 'Could not copy; select the text by hand' : ''}
      </span>
    </>
  );
}
