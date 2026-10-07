// The landing's 3D stage styles (scene.css) travel with the stage, not in the entry stylesheet, as the landing's
// paper styles do (landing-paper.ts): the build makes one stylesheet for the entry (vite.config.ts, cssCodeSplit:
// false), and these rules are needed only once the stage renders. Landing.tsx loads this module beside
// scene/DieStage.tsx, in parallel, and calls sceneStyles() before the stage first renders, so nothing on screen is
// ever unstyled. Every state the stage can be in (3D, the Canvas 2D fallback, a still frame, reduced motion) is
// rendered by DieStage itself, so all of its rules can wait for it; until it arrives the landing shows its chapters
// stacked on plain silicon (landing.css). The <style> element goes at the end of <head>, after the entry
// stylesheet, where the bundler used to put these rules too (last). The text holds no url() and no @import.

import css from './scene.css?inline';

let added = false;

export function sceneStyles(): void {
  if (added || typeof document === 'undefined') return;
  added = true;
  const el = document.createElement('style');
  el.dataset.styles = 'scene';
  el.textContent = css;
  document.head.append(el);
}
