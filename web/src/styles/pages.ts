// The inner pages' styles (pages.css: vault, audit, hostile, judge, trust, the circuit bench, 404) travel with the
// pages, not in the entry stylesheet: the landing never uses them (no rule of pages.css matches anything on it),
// and the entry is what the first paint pays for. Every on-demand page module that uses them imports this module
// and calls pageStyles() when it is evaluated, before app.tsx renders the page: routes/kernelPages.tsx,
// routes/guidePages.tsx, routes/Circuit.tsx and routes/NotFound.tsx (the processor page uses none of them). The
// bundler puts this module in one small chunk those pages share. The <style> element goes at the end of <head>,
// after the entry stylesheet, as landing-paper.ts does. The text holds no url() and no @import.

import css from './pages.css?inline';

let added = false;

export function pageStyles(): void {
  if (added || typeof document === 'undefined') return;
  added = true;
  const el = document.createElement('style');
  el.dataset.styles = 'pages';
  el.textContent = css;
  document.head.append(el);
}
