// The CTA press (plan section D): an element with class `press` sinks to scale .97 and 1 px down over 120 ms while
// held, and comes back over 350 ms with the reveal ease; a square gold impression grows from the point that was
// pressed (from the centre when a key pressed it) and fades. One set of listeners on the document serves every
// `.press` element, present or future. The styles are in src/styles/motion.css; under prefers-reduced-motion they
// do nothing and no impression is drawn.

import { motionAllowed } from './prefs.ts';

const SELECTOR = '.press';

/**
 * Where the impression goes, in the element's own pixels: a square centred on the pressed point (x, y), large
 * enough that at full size it covers the whole w × h element.
 */
export function impressionBox(w: number, h: number, x: number, y: number): { left: number; top: number; side: number } {
  const side = 2 * Math.max(x, w - x, y, h - y);
  return { left: x - side / 2, top: y - side / 2, side };
}

function pressable(t: EventTarget | null): HTMLElement | null {
  const el = t instanceof Element ? t.closest<HTMLElement>(SELECTOR) : null;
  if (!el || el.matches(':disabled, [aria-disabled="true"]')) return null;
  return el;
}

/** Draws one impression on `el` at (x, y) in its own pixels; it removes itself when its animation ends. */
export function impress(el: HTMLElement, x?: number, y?: number): void {
  if (!motionAllowed()) return;
  const w = el.offsetWidth;
  const h = el.offsetHeight;
  const b = impressionBox(w, h, x ?? w / 2, y ?? h / 2);
  const mark = document.createElement('span');
  mark.className = 'press-impression';
  mark.setAttribute('aria-hidden', 'true');
  mark.style.cssText = `left:${b.left}px;top:${b.top}px;width:${b.side}px;height:${b.side}px`;
  const done = (): void => mark.remove();
  mark.addEventListener('animationend', done, { once: true });
  setTimeout(done, 1500); // in case the stylesheet is missing and no animation runs
  el.append(mark);
}

let installed: (() => void) | null = null;

/** Starts the press behaviour for every `.press` element under `root`. Safe to call twice; returns the uninstall. */
export function installPress(root: Document | HTMLElement = document): () => void {
  if (installed) return installed;
  const held = new Set<HTMLElement>();
  const release = (): void => {
    for (const el of held) el.classList.remove('is-pressed');
    held.clear();
  };
  const down = (e: Event): void => {
    const p = e as PointerEvent;
    if (p.button !== 0) return;
    const el = pressable(p.target);
    if (!el) return;
    // Measure before the press shrinks it; offset sizes ignore transforms, client rects do not.
    const r = el.getBoundingClientRect();
    const sx = r.width > 0 ? el.offsetWidth / r.width : 1;
    const sy = r.height > 0 ? el.offsetHeight / r.height : 1;
    el.classList.add('is-pressed');
    held.add(el);
    impress(el, (p.clientX - r.left) * sx, (p.clientY - r.top) * sy);
  };
  const key = (e: Event): void => {
    const k = e as KeyboardEvent;
    if ((k.key !== 'Enter' && k.key !== ' ') || k.repeat) return;
    const el = pressable(k.target);
    if (!el || el !== k.target) return; // the key must be on the control itself, not on a field inside it
    el.classList.add('is-pressed');
    held.add(el);
    impress(el);
  };
  root.addEventListener('pointerdown', down);
  root.addEventListener('keydown', key);
  addEventListener('pointerup', release);
  addEventListener('pointercancel', release);
  addEventListener('keyup', release);
  addEventListener('blur', release);
  installed = () => {
    root.removeEventListener('pointerdown', down);
    root.removeEventListener('keydown', key);
    removeEventListener('pointerup', release);
    removeEventListener('pointercancel', release);
    removeEventListener('keyup', release);
    removeEventListener('blur', release);
    release();
    installed = null;
  };
  return installed;
}
