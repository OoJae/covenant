// Motion tokens (brand system, plan section C) and the two questions every animation asks first: does the reader
// allow motion, and is the pointer a fine one. The CSS side of the same tokens is in src/styles/motion.css.

export const EASE_REVEAL = 'cubic-bezier(.16,1,.3,1)';
export const EASE_TOGGLE = 'cubic-bezier(.65,0,.35,1)';

/** Durations in milliseconds. */
export const DUR = { micro: 240, toggle: 320, reveal: 900, page: 1100 } as const;
/** Stagger between steps in level order, like the wavefront, in milliseconds. */
export const STAGGER = 60;

const query = (q: string): MediaQueryList | null => (typeof matchMedia === 'function' ? matchMedia(q) : null);

/** False under prefers-reduced-motion, and when there is no window to ask (tests, a server). */
export function motionAllowed(): boolean {
  const m = query('(prefers-reduced-motion: reduce)');
  return m !== null && !m.matches;
}

/** A mouse or a trackpad, not a finger. */
export function finePointer(): boolean {
  return query('(pointer: fine)')?.matches ?? false;
}

/** Calls `cb` whenever the reduced-motion setting changes; returns the unsubscribe function. */
export function onMotionChange(cb: (allowed: boolean) => void): () => void {
  const m = query('(prefers-reduced-motion: reduce)');
  if (!m) return () => {};
  const on = (): void => cb(!m.matches);
  m.addEventListener('change', on);
  return () => m.removeEventListener('change', on);
}
