// The entry. Styles first, in cascade order: the design system (tokens, fonts, base, components, pages), then the
// landing page and the motion layer. Then the app, the press for every button, and Lenis once the page is idle.

import './styles/all.ts';
import './styles/landing.css';
import './styles/motion.css';
import { render } from 'preact';
import { App } from './app.tsx';
import { smoothScroll } from './motion/lenis.ts';
import { installPress } from './motion/press.ts';

// The first page's load sequence (header, then the page's own entrance) plays once; later pages arrive through the
// route transition instead. The class only gates CSS animations, which have all finished when it is removed.
const root = document.documentElement;
root.classList.add('is-booting');
setTimeout(() => root.classList.remove('is-booting'), 1600);

// The three preloaded faces (vite.config.ts) are loaded now, and the first render waits for them, 100 ms at most.
// Firefox sets text in a preloaded face only once its FontFace has loaded: until then it lays the text out in the
// fallback and reflows when the face arrives, so the hero's buttons jumped a line just after the first paint, and a
// page that first used a face after the chain answered moved down when it showed. Elsewhere the faces are in already
// and the wait is a few milliseconds; the text would sit out the same block period anyway.
const faces = ['1em "Bodoni Moda"', 'italic 1em "Bodoni Moda"', '1em "Instrument Sans"'].map((f) => document.fonts?.load(f));
const start = (): void => {
  render(<App />, document.getElementById('app')!);
  installPress();
  // Smooth scrolling is a nicety: start it when the main thread is free, never ahead of the first paint.
  const idle: (cb: () => void) => void = typeof requestIdleCallback === 'function' ? (cb) => requestIdleCallback(cb, { timeout: 2000 }) : (cb) => setTimeout(cb, 600);
  idle(() => void smoothScroll());
};
Promise.race([Promise.all(faces), new Promise((r) => setTimeout(r, 100))]).then(start, start);
