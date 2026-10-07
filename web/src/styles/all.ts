// The site's stylesheet, in cascade order: the tokens and the two materials, the faces, then the page as paper and
// the shared components. src/main.tsx imports this first, then landing.css and motion.css. Vite bundles all of it
// into the one stylesheet index.html names. What only part of the site needs travels with that part, as a <style>
// element added when its chunk loads: the inner pages' rules (pages.css, styles/pages.ts), the landing's 3D stage
// (scene.css, styles/scene.ts) and the landing's paper clauses (landing-paper.css, styles/landing-paper.ts).
import './tokens.css';
import './fonts.css';
import './base.css';
import './components.css';
