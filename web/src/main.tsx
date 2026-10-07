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

render(<App />, document.getElementById('app')!);
installPress();

// Smooth scrolling is a nicety: start it when the main thread is free, never ahead of the first paint.
const idle: (cb: () => void) => void = typeof requestIdleCallback === 'function' ? (cb) => requestIdleCallback(cb, { timeout: 2000 }) : (cb) => setTimeout(cb, 600);
idle(() => void smoothScroll());
