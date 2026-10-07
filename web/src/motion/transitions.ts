// Page transitions (plan section D). Where the browser has same-document view transitions and motion is allowed,
// a route change runs inside document.startViewTransition: the old page fades and lifts over 350 ms, the new one
// rises over 900 ms, and the header (view-transition-name: header) holds still while the Bond's gold pad blinks
// once. Elsewhere the route change happens at once, and a keyed <main> with the `page-enter` class rises on mount
// instead (pageEnter below). Under prefers-reduced-motion both are off. The CSS is in src/styles/motion.css.

import { motionAllowed } from './prefs.ts';

/** True when route changes will run as view transitions. */
export function viewTransitions(): boolean {
  return motionAllowed() && typeof document !== 'undefined' && typeof document.startViewTransition === 'function';
}

/**
 * Applies `update` (which changes the DOM, or sets state and awaits `afterRender()`) inside a view transition when
 * there is one. Resolves once the update has been applied; rejects only if `update` throws.
 */
export function withViewTransition(update: () => Promise<void> | void): Promise<void> {
  if (!viewTransitions()) return Promise.resolve().then(update);
  const root = document.documentElement;
  root.classList.add('vt-nav');
  const vt = document.startViewTransition(async () => {
    await update();
  });
  const clear = (): void => root.classList.remove('vt-nav');
  vt.finished.then(clear, clear);
  vt.ready.catch(() => {}); // skipped transitions reject `ready`; the update still applies
  return vt.updateCallbackDone;
}

/** Waits until Preact has rendered the state set just before (its renders are queued, not synchronous). */
export function afterRender(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

/**
 * The fallback: props for <main>. Without view transitions (and with motion allowed) <main> is keyed by the route,
 * so each route mounts a fresh element and its `page-enter` animation plays; otherwise the key never changes and
 * there is no class.
 */
export function pageEnter(routeKey: string): { key: string; class: string | undefined } {
  return !viewTransitions() && motionAllowed() ? { key: routeKey, class: 'page-enter' } : { key: 'page', class: undefined };
}
