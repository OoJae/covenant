// scripts/check-budget.mjs against tampered builds: a small synthetic dist that passes, then one change at a time
// that each rule must catch. No build and no network; each case runs the script as the build does.

import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, describe, expect, test } from 'vitest';

const SCRIPT = fileURLToPath(new URL('../scripts/check-budget.mjs', import.meta.url));
const made: string[] = [];
afterAll(() => {
  for (const d of made) rmSync(d, { recursive: true, force: true });
});

type Files = Record<string, string | number>;
const FONTS = ['display-roman.woff2', 'display-italic.woff2', 'body.woff2', 'mono.woff2'];

/** A build that keeps every rule: entry, three preloaded fonts plus one more, the two images, a lazy chunk. */
function good(): Files {
  return {
    'index.html': `<!doctype html><html><head>
<link rel="icon" href="data:image/svg+xml,%3Csvg%3E%3C/svg%3E">
<link rel="apple-touch-icon" href="./apple-touch-icon.png">
<meta property="og:image" content="https://oojae.github.io/covenant/og.jpg">
<script type="module" crossorigin src="./assets/index-a.js"></script>
<link rel="stylesheet" href="./assets/style-a.css">
${FONTS.slice(0, 3)
  .map((f) => `<link rel="preload" href="./assets/${f}" as="font" type="font/woff2" crossorigin>`)
  .join('\n')}
</head><body><div id="app"></div></body></html>`,
    'assets/index-a.js': `import "./shared-a.js";const f=()=>import("./kernelPages-a.js");fetch("https://rpc.xlayer.tech");${'x'.repeat(60_000)}`,
    'assets/shared-a.js': `export const s=1;${'y'.repeat(10_000)}`,
    'assets/style-a.css': `${FONTS.map((f, i) => `@font-face{font-family:f${i};src:url(./${f}) format("woff2")}`).join('')}body{color:#000}${'a{}'.repeat(3000)}`,
    'assets/kernelPages-a.js': `export const k=1;${'z'.repeat(50_000)}`,
    'assets/scene-a.js': 20_000,
    'assets/DieStage-a.js': 4_000,
    'assets/lenis-a.js': 15_000,
    'assets/display-roman.woff2': 30_000,
    'assets/display-italic.woff2': 17_000,
    'assets/body.woff2': 34_000,
    'assets/mono.woff2': 9_000,
    'apple-touch-icon.png': 200,
    'og.jpg': 100_000,
  };
}

function check(files: Files): { ok: boolean; out: string } {
  const dir = mkdtempSync(join(tmpdir(), 'covenant-budget-'));
  made.push(dir);
  for (const [path, body] of Object.entries(files)) {
    const p = join(dir, path);
    mkdirSync(join(p, '..'), { recursive: true });
    writeFileSync(p, typeof body === 'number' ? Buffer.alloc(body, 0x41) : body);
  }
  const r = spawnSync(process.execPath, [SCRIPT, dir], { encoding: 'utf8' });
  return { ok: r.status === 0, out: `${r.stdout}\n${r.stderr}` };
}

describe('check-budget.mjs', () => {
  test('a build within every rule passes', () => {
    const r = check(good());
    expect(r.out).toContain('check-budget: ok');
    expect(r.ok).toBe(true);
  });

  const preloadFor = (html: string, font: string): string =>
    html.replace('</head>', `<link rel="preload" href="./assets/${font}" as="font" type="font/woff2" crossorigin></head>`);

  const cases: [string, (f: Files) => void, RegExp][] = [
    ['a script from another origin', (f) => (f['index.html'] = String(f['index.html']).replace('./assets/index-a.js', 'https://cdn.example.com/x.js')), /from another origin/],
    ['an absolute path', (f) => (f['index.html'] = String(f['index.html']).replace('./assets/style-a.css', '/assets/style-a.css')), /absolute path/],
    ['a site above 520,000 bytes', (f) => (f['assets/big-a.js'] = 300_000), /above the 520000 byte budget/],
    ['an entry above 112,000 bytes', (f) => (f['assets/index-a.js'] = String(f['assets/index-a.js']) + 'q'.repeat(45_000)), /entry files is \d+ bytes, above the 112000/],
    ['an entry within budget only because a static import was split out', (f) => (f['assets/shared-a.js'] = 'export const s=1;' + 's'.repeat(45_000)), /above the 112000/],
    [
      'first paint above 196,000 bytes',
      (f) => {
        f['assets/index-a.js'] = String(f['assets/index-a.js']) + 'q'.repeat(25_000);
        f['assets/body.woff2'] = 39_000;
        f['assets/display-roman.woff2'] = 39_000;
        f['assets/mono.woff2'] = 1_000;
      },
      /first paint .* above the 196000/,
    ],
    ['a font that is not woff2', (f) => (f['assets/old.ttf'] = 1_000), /fonts must be woff2/],
    ['a font above 40,000 bytes', (f) => (f['assets/body.woff2'] = 41_000), /above the 40000 byte limit per font/],
    ['fonts above 100,000 bytes', (f) => (f['assets/mono.woff2'] = 25_000), /fonts are \d+ bytes, above the 100000/],
    ['a font no stylesheet references', (f) => (f['assets/stray.woff2'] = 1_000), /stray\.woff2: font is not referenced/],
    ['four preloaded fonts', (f) => (f['index.html'] = preloadFor(String(f['index.html']), 'mono.woff2')), /preloads 4 fonts/],
    ['an image other than og.jpg and apple-touch-icon.png', (f) => (f['assets/logo.png'] = 500), /the only images allowed/],
    ['og.jpg above 110,000 bytes', (f) => (f['og.jpg'] = 111_000), /og\.jpg: image is \d+ bytes, above its 110000/],
    ['apple-touch-icon.png above 8,000 bytes', (f) => (f['apple-touch-icon.png'] = 9_000), /apple-touch-icon\.png: image is \d+ bytes, above its 8000/],
    ['a scene chunk above 24,000 bytes', (f) => (f['assets/scene-a.js'] = 25_000), /3D-stage chunk .* above its 24000/],
    ['a DieStage chunk above 24,000 bytes', (f) => (f['assets/DieStage-a.js'] = 24_500), /3D-stage chunk .* above its 24000/],
    ['the Lenis chunk above 20,000 bytes', (f) => (f['assets/lenis-a.js'] = 21_000), /Lenis chunk is \d+ bytes, above its 20000/],
    ['an analytics host in the code', (f) => (f['assets/kernelPages-a.js'] = String(f['assets/kernelPages-a.js']) + 'fetch("https://analytics.example.com/p")'), /mentions https:\/\/analytics\.example\.com/],
    ['a source map', (f) => (f['assets/index-a.js.map'] = '{}'), /source maps must not ship/],
    ['@import in a stylesheet', (f) => (f['assets/style-a.css'] = '@import "x.css";' + String(f['assets/style-a.css'])), /@import is not allowed/],
    ['a stylesheet that loads from another origin', (f) => (f['assets/style-a.css'] = String(f['assets/style-a.css']) + 'b{background:url(https://example.com/a.png)}'), /loads https:\/\/example\.com/],
  ];

  test.each(cases)('rejects %s', (_name, tamper, message) => {
    const f = good();
    tamper(f);
    const r = check(f);
    expect(r.ok).toBe(false);
    expect(r.out).toMatch(message);
  });
});
