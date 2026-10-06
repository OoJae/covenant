// Light, dark, or the system's choice. The choice is a data-theme attribute on <html> (the stylesheet keys off it)
// and is remembered in localStorage when the browser allows it. The die shot listens through onThemeChange.

import { useEffect, useState } from 'preact/hooks';

type Choice = 'system' | 'light' | 'dark';
const KEY = 'covenant-theme';
const media = (): MediaQueryList | null => (typeof matchMedia === 'function' ? matchMedia('(prefers-color-scheme: dark)') : null);
const listeners = new Set<() => void>();

function stored(): Choice {
  try {
    const v = localStorage.getItem(KEY);
    return v === 'light' || v === 'dark' ? v : 'system';
  } catch {
    return 'system';
  }
}

function apply(c: Choice): void {
  if (typeof document === 'undefined') return;
  if (c === 'system') document.documentElement.removeAttribute('data-theme');
  else document.documentElement.setAttribute('data-theme', c);
  for (const f of listeners) f();
}

/** Whether the page is dark right now. */
export function isDark(): boolean {
  const attr = typeof document === 'undefined' ? null : document.documentElement.getAttribute('data-theme');
  if (attr === 'dark') return true;
  if (attr === 'light') return false;
  return media()?.matches ?? true;
}

/** Calls `f` whenever the page switches between light and dark. Returns the unsubscribe function. */
export function onThemeChange(f: () => void): () => void {
  listeners.add(f);
  const m = media();
  m?.addEventListener('change', f);
  return () => {
    listeners.delete(f);
    m?.removeEventListener('change', f);
  };
}

apply(stored());

export function ThemeToggle() {
  const [choice, setChoice] = useState<Choice>(stored);
  useEffect(() => apply(choice), [choice]);
  const next: Record<Choice, Choice> = { system: 'dark', dark: 'light', light: 'system' };
  return (
    <button
      type="button"
      class="themebtn"
      title={`Theme: ${choice}. Click for ${next[choice]}.`}
      aria-label={`Colour theme: ${choice}`}
      onClick={() => {
        const c = next[choice];
        setChoice(c);
        try {
          if (c === 'system') localStorage.removeItem(KEY);
          else localStorage.setItem(KEY, c);
        } catch {
          // storage blocked: the choice lasts for this page view
        }
      }}
    >
      {choice === 'system' ? '◐' : choice === 'dark' ? '●' : '○'}
    </button>
  );
}
