// The landing page's paper styles (§01 to §05) travel with the chunks that render those clauses, not in the entry
// stylesheet: the build makes one stylesheet for the entry (vite.config.ts, cssCodeSplit: false), and these rules
// are needed only once a clause has loaded. The first chunk to load adds them as one <style> element at the end of
// <head>, before its component renders, so they come after the entry stylesheet in the cascade, as landing.css
// does. The text holds no url() and no @import.

import css from './landing-paper.css?inline';

let added = false;

export function paperStyles(): void {
  if (added || typeof document === 'undefined') return;
  added = true;
  const el = document.createElement('style');
  el.dataset.styles = 'landing-paper';
  el.textContent = css;
  document.head.append(el);
}
