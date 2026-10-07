// Page transitions (plan section D). Where the browser has same-document view transitions and motion is allowed,
// a route change runs inside document.startViewTransition: the old page fades and lifts over 350 ms, the new one
// rises over 900 ms, and the header (view-transition-name: header) holds still while the Bond's gold pad blinks
// once. Elsewhere the route change happens at once, and the keyed <main class="route"> that app.tsx renders rises
// on mount instead: routeEnter() below switches that CSS on, from the first route change of the visit, so the first
// page keeps its own load sequence. Under prefers-reduced-motion both are off. The CSS is in src/styles/motion.css.
// useRoute (src/router.ts) is the only caller for route changes.

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

/** Class on <html> that lets the keyed <main class="route"> rise on mount (the fallback for view transitions). */
export const ROUTE_ENTER = 'route-enter';

/**
 * Called just before a route change is rendered. Without view transitions (and with motion allowed) it marks the
 * document so the new <main> rises on mount. It is set before the new page renders, so the class never starts an
 * animation on a page that is already on screen; and it is never set where view transitions run, so the two never
 * play together.
 */
export function routeEnter(): void {
  if (typeof document === 'undefined') return;
  document.documentElement.classList.toggle(ROUTE_ENTER, !viewTransitions() && motionAllowed());
}
