// Capture the link card (Open Graph and X) from the real landing hero: docs/brand/og-1200x630.jpg, and the same
// bytes as web/public/og.jpg, which index.html names in its og:image and twitter:image tags.
//
//   pnpm --filter web build
//   node docs/brand/tools/og_card.mjs
//
// Needs the playwright package (1.60 or later) with its Chromium, and python3 with Pillow. Neither is a dependency
// of the repo: if `playwright` does not resolve from here, set PLAYWRIGHT to the package's folder, for example
// PLAYWRIGHT=/opt/homebrew/lib/node_modules/@playwright/test/node_modules/playwright.
//
// What it does: serves web/dist on a free local port, opens it in a headless Chromium with WebGL2, loads the page
// twice so the font-display: optional faces come from cache, waits for the die to draw in 3D, for the headline's
// reveal to finish and for the hero's sway to settle, and screenshots a 1024 x 538 viewport (the desktop layout) at
// 2x. Pillow scales that to 1200 x 630 (Lanczos) and saves a progressive JPEG at quality 48, 4:2:0, about 52 KB:
// web/scripts/check-budget.mjs counts it in the site's 520,000 bytes, and the DeWEB copy is paid per byte.
//
// The die, the headline, the label and the wordmark are the page's own. CARD_CSS below is the only change, and it
// is added to the captured page, never to the site:
//   - hidden: the nav, the menu button, the skip buttons and the hero's foot (lede, CTAs, and the live ledger,
//     whose settle counts change over time);
//   - the 5% grain is off: it cannot be seen at card size and it doubles the file;
//   - the lockup is 1.4 times larger, the label one step up (0.875rem) and the headline 4.25rem, so they still read
//     at the third of its width X shows (about 506 px) and smaller in Telegram;
//   - margins for a card: the lockup comes off the top edge, and the headline sits clear of the bottom band, where
//     X lays the site's domain over the image.

import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const DIST = join(ROOT, 'web/dist');
const OUT = join(ROOT, 'docs/brand/og-1200x630.jpg');
const PUBLIC_COPY = join(ROOT, 'web/public/og.jpg');
const VIEW = { width: 1024, height: 538 };
const SCALE = 2;
const SIZE = [1200, 630];
const QUALITY = 48;
/** The hero's sway settles after 8 s without a scroll (src/scene/index.ts SWAY_IDLE); wait past that. */
const SETTLE_MS = 12_000;

const CARD_CSS = `
.skip, .skip-anim, .nav, .menu-btn, .hero__foot { display: none !important; }
*, *::before, *::after { --grain: none !important; --grain-si: none !important; --grain-pa: none !important; }
.brand { transform: scale(1.4); transform-origin: 0 50%; }
.hero__label { font-size: 0.875rem !important; }
.hero__title { font-size: 4.25rem !important; }
header.top { top: 1.25rem !important; }
.hero__inner {
  padding-top: calc(var(--header-h) + var(--sp-6) + 1.25rem) !important;
  padding-bottom: 4.5rem !important;
}
`;

const require = createRequire(import.meta.url);
let playwright;
try {
  playwright = require(process.env.PLAYWRIGHT ?? 'playwright');
} catch {
  console.error('og_card: cannot load playwright; set PLAYWRIGHT to the package folder (see the header).');
  process.exit(1);
}
try {
  statSync(join(DIST, 'index.html'));
} catch {
  console.error('og_card: web/dist/index.html is missing; run pnpm --filter web build first.');
  process.exit(1);
}

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.png': 'image/png', '.jpg': 'image/jpeg', '.json': 'application/json', '.svg': 'image/svg+xml' };
const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  const file = normalize(join(DIST, path.endsWith('/') ? `${path}index.html` : path));
  if (!file.startsWith(DIST + sep)) return res.writeHead(403).end();
  try {
    const body = readFileSync(file);
    res.writeHead(200, { 'content-type': TYPES[extname(file)] ?? 'application/octet-stream' }).end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
const url = `http://127.0.0.1:${server.address().port}/`;

const work = mkdtempSync(join(tmpdir(), 'covenant-og-'));
const png = join(work, 'hero.png');
// A real GPU: the stage asks for WebGL2 with failIfMajorPerformanceCaveat, so a software GL would get the 2D die.
const gpu = ['--enable-gpu', '--ignore-gpu-blocklist', ...(process.platform === 'darwin' ? ['--use-angle=metal'] : [])];
const browser = await playwright.chromium.launch({ headless: true, args: gpu });
try {
  const ctx = await browser.newContext({ viewport: VIEW, deviceScaleFactor: SCALE, reducedMotion: 'no-preference' });
  const page = await ctx.newPage();
  await page.addInitScript((css) => {
    const add = () => {
      const s = document.createElement('style');
      s.dataset.capture = 'og';
      s.textContent = css;
      document.head.append(s);
    };
    if (document.head) add();
    else document.addEventListener('DOMContentLoaded', add, { once: true });
  }, CARD_CSS);
  await page.goto(url, { waitUntil: 'networkidle' });
  await page.reload({ waitUntil: 'networkidle' });
  await page.waitForSelector('.die-stage[data-mode="gl"]', { timeout: 20_000 });
  await page.waitForFunction(() => !document.querySelector('.hero__title .rl-src'), null, { timeout: 20_000 });
  const faces = await page.evaluate(async () => {
    await document.fonts.ready;
    return [...document.fonts].filter((f) => f.status === 'loaded').map((f) => `${f.family} ${f.style}`);
  });
  for (const want of ['Bodoni Moda normal', 'Bodoni Moda italic', 'Fragment Mono normal']) {
    if (!faces.includes(want)) throw new Error(`the face ${want} did not load`);
  }
  await page.waitForTimeout(SETTLE_MS);
  await page.screenshot({ path: png });
} finally {
  await browser.close();
  server.close();
}

const py = `
import sys
from PIL import Image
src, out, w, h, q = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
im = Image.open(src).convert('RGB').resize((w, h), Image.LANCZOS)
im.save(out, 'JPEG', quality=q, subsampling=2, progressive=True, optimize=True)
`;
const r = spawnSync('python3', ['-c', py, png, OUT, String(SIZE[0]), String(SIZE[1]), String(QUALITY)], { stdio: 'inherit' });
rmSync(work, { recursive: true, force: true });
if (r.status !== 0) {
  console.error('og_card: python3 with Pillow failed to write the JPEG.');
  process.exit(1);
}
copyFileSync(OUT, PUBLIC_COPY);
console.log(`og_card: ${resolve(OUT)} and ${resolve(PUBLIC_COPY)}, ${statSync(OUT).size} bytes`);
