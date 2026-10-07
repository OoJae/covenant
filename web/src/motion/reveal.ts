// Reveal once: an element with class `reveal` is held down and transparent until its top crosses 85% of the
// viewport, then rises into place (900 ms, reveal ease) and stays. Children marked data-stagger with a --i index
// follow 60 ms apart. One IntersectionObserver serves every element. Under prefers-reduced-motion, or without
// IntersectionObserver, elements are revealed at once. The CSS is in src/styles/motion.css.

import type { RefObject } from 'preact';
import { useEffect, useRef } from 'preact/hooks';
import { motionAllowed } from './prefs.ts';

export const REVEALED = 'is-revealed';

const waiting = new Map<Element, () => void>();
let io: IntersectionObserver | null = null;

function observer(): IntersectionObserver {
  io ??= new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        io!.unobserve(e.target);
        e.target.classList.add(REVEALED);
        const cb = waiting.get(e.target);
        waiting.delete(e.target);
        cb?.();
      }
    },
    { rootMargin: '0px 0px -15% 0px', threshold: 0 },
  );
  return io;
}

/** Reveals `el` the first time it enters the view, then calls `onReveal`. Returns a function that stops watching. */
export function revealOnce(el: Element, onReveal: () => void = () => {}): () => void {
  if (!motionAllowed() || typeof IntersectionObserver !== 'function') {
    el.classList.add(REVEALED);
    onReveal();
    return () => {};
  }
  waiting.set(el, onReveal);
  observer().observe(el);
  return () => {
    waiting.delete(el);
    io?.unobserve(el);
  };
}

/** A ref for an element with class `reveal`: it is revealed once when it enters the view. */
export function useReveal<T extends Element>(onReveal?: () => void): RefObject<T | null> {
  const ref = useRef<T>(null);
  useEffect(() => (ref.current ? revealOnce(ref.current, onReveal) : undefined), []);
  return ref;
}
