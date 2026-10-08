// Fails the build if web/dist breaks the rules for a site that will be stored on chain (reasons: web/NOTES.md 3.7):
//   - whole site at most 520,000 bytes;
//   - entry at most 112,000 bytes: index.html, the scripts and stylesheet it names, and every script those import
//     statically (fonts are not part of it);
//   - first paint at most 196,000 bytes: the entry plus the fonts index.html preloads;
//   - fonts: woff2 only, each at most 40,000 bytes, all of them at most 100,000, each one referenced by a stylesheet,
//     and at most 3 preloaded;
//   - images: only og.jpg (at most 110,000 bytes) and apple-touch-icon.png (at most 8,000), at the root of dist;
//   - on-demand chunks: any chunk named scene* or DieStage* at most 24,000 bytes, the Lenis chunk at most 20,000;
//   - fully self-contained: no script, stylesheet, font or image loaded from another origin, no source maps, no
//     @import, and no URL in the code except the RPC endpoints, the explorer and the few plain links listed below.
// Sizes are bytes on disk (what on-chain storage is paid for), not gzip.
//
//   node scripts/check-budget.mjs            checks web/dist
//   node scripts/check-budget.mjs some/dir   checks another build output

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';

const TOTAL_LIMIT = 520_000;
const ENTRY_LIMIT = 112_000;
const FIRST_PAINT_LIMIT = 196_000;
const FONT_LIMIT = 40_000;
const FONTS_LIMIT = 100_000;
const PRELOAD_LIMIT = 3;
/** The only images: name at the root of dist, and its limit. */
const IMAGES = { 'og.jpg': 110_000, 'apple-touch-icon.png': 8_000 };
/** On-demand chunks that must stay small: the landing's 3D stage and the smooth-scroll library. */
const LAZY = [
  { test: (name) => /^(?:scene|DieStage)/.test(name), limit: 24_000, what: 'a 3D-stage chunk (scene*, DieStage*)' },
  { test: (name) => /^lenis\b/i.test(name), limit: 20_000, what: 'the Lenis chunk' },
];

const root = fileURLToPath(new URL('../', import.meta.url));
const dist = process.argv[2] ? resolve(process.argv[2]) : join(root, 'dist');
const addresses = JSON.parse(readFileSync(join(root, 'src/addresses.json'), 'utf8'));

// Hosts the code may mention: the RPC endpoints it calls, the explorer it links to, the public repository it
// links source files on (plain links, never fetched), the XML namespace identifiers Preact needs to create SVG
// and MathML nodes (never fetched), the Covenant Architect endpoint that deployments/xlayer.json records (a plain
// link, never fetched), the site's public address on GitHub Pages (the OG and Twitter tags name its og.jpg; a crawler
// fetches it, the page does not), the DeWEB mirror on X Layer (a plain link in the footer) and IGNIX's page of a
// bound token (a plain link on the vault page, never fetched).
const deployment = JSON.parse(readFileSync(join(root, '../deployments/xlayer.json'), 'utf8'));
const architectHosts = ['endpoint', 'freeEndpoint']
  .map((k) => deployment.architect?.[k])
  .filter((u) => typeof u === 'string')
  .map((u) => new URL(u).host);
const allowedHosts = new Set([
  ...addresses.rpc.map((u) => new URL(u).host),
  'www.oklink.com',
  'github.com',
  'www.w3.org',
  'oojae.github.io',
  '1-2-283.tapekit.org',
  'ignix.bot',
  ...architectHosts,
]);

const walk = (dir) =>
  readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]));

let files;
try {
  files = walk(dist);
} catch {
  console.error(`check-budget: ${dist} does not exist. Run the build first.`);
  process.exit(1);
}

const problems = [];
const rows = files
  .map((f) => ({ path: relative(dist, f).split('\\').join('/'), bytes: statSync(f).size, gzip: gzipSync(readFileSync(f), { level: 9 }).length }))
  .sort((a, b) => b.bytes - a.bytes);
const total = rows.reduce((n, r) => n + r.bytes, 0);
const has = (name) => rows.some((r) => r.path === name);
const sizeOf = (name) => rows.find((r) => r.path === name)?.bytes ?? 0;

const isFont = (p) => /\.(?:woff2?|ttf|otf|eot)$/i.test(p);
const isImage = (p) => /\.(?:png|jpe?g|gif|webp|avif|svg|ico|bmp|tiff?)$/i.test(p);

// What index.html loads. Scripts and stylesheets are the entry; preloaded fonts count towards first paint; icons
// are images (checked below with the other images).
const html = readFileSync(join(dist, 'index.html'), 'utf8');
const attr = (tag, name) => tag.match(new RegExp(`\\b${name}\\s*=\\s*["']([^"']*)["']`, 'i'))?.[1] ?? null;
const entry = new Set(['index.html']);
const preloads = [];
for (const m of html.matchAll(/<(script|link|img|source|iframe|audio|video|embed|object)\b[^>]*>/gi)) {
  const tag = m[0];
  const ref = attr(tag, 'src') ?? attr(tag, 'href') ?? attr(tag, 'data');
  if (ref === null || ref.startsWith('data:')) continue; // inlined, e.g. the icon
  if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(ref)) {
    problems.push(`index.html loads ${ref} from another origin`);
    continue;
  }
  if (ref.startsWith('/')) {
    problems.push(`index.html uses the absolute path ${ref}; paths must be relative so the site works from any folder`);
    continue;
  }
  const file = ref.replace(/^\.\//, '').split(/[?#]/)[0];
  const rel = (attr(tag, 'rel') ?? '').toLowerCase();
  if (m[1].toLowerCase() === 'link' && rel === 'preload' && (attr(tag, 'as') ?? '').toLowerCase() === 'font') {
    preloads.push(file);
    if (!/\.woff2$/i.test(file)) problems.push(`index.html preloads ${file}, which is not a woff2 font`);
  } else if (/\bicon\b/.test(rel) || isImage(file)) {
    if (!isImage(file)) problems.push(`index.html names ${file} as an icon, which is not an image`);
  } else entry.add(file);
  if (!has(file)) problems.push(`index.html refers to ${file}, which is not in dist`);
}
// A script the entry imports statically is loaded at startup too: follow `import … from "./x.js"` and
// `import "./x.js"` (not `import("./x.js")`, which is on demand) through every script reached.
for (const queue = [...entry].filter((f) => /\.m?js$/.test(f)); queue.length > 0; ) {
  const f = queue.pop();
  let text;
  try {
    text = readFileSync(join(dist, f), 'utf8');
  } catch {
    continue;
  }
  for (const m of text.matchAll(/(?:\bfrom|\bimport)\s*["'](\.{1,2}\/[^"']+)["']/g)) {
    const dep = join(dirname(f), m[1]).split('\\').join('/').replace(/^\.\//, '');
    if (!entry.has(dep)) {
      entry.add(dep);
      queue.push(dep);
    }
  }
}
const entryBytes = rows.filter((r) => entry.has(r.path)).reduce((n, r) => n + r.bytes, 0);
const preloadBytes = [...new Set(preloads)].reduce((n, f) => n + sizeOf(f), 0);
const firstPaint = entryBytes + preloadBytes;

// Every stylesheet's text, for the font references.
const css = rows.filter((r) => r.path.endsWith('.css')).map((r) => ({ path: r.path, text: readFileSync(join(dist, r.path), 'utf8') }));
const referenced = new Set();
for (const c of css) {
  for (const m of c.text.matchAll(/url\(\s*["']?([^"')]+)/gi)) {
    if (!m[1].startsWith('data:')) referenced.add(join(dirname(c.path), m[1].split(/[?#]/)[0]).split('\\').join('/'));
  }
}

let fontBytes = 0;
for (const r of rows) {
  if (r.path.endsWith('.map')) problems.push(`${r.path}: source maps must not ship`);
  if (isFont(r.path)) {
    fontBytes += r.bytes;
    if (!/\.woff2$/i.test(r.path)) problems.push(`${r.path}: fonts must be woff2`);
    if (r.bytes > FONT_LIMIT) problems.push(`${r.path}: font is ${r.bytes} bytes, above the ${FONT_LIMIT} byte limit per font`);
    if (!referenced.has(r.path)) problems.push(`${r.path}: font is not referenced by any stylesheet`);
  }
  if (isImage(r.path)) {
    const limit = IMAGES[r.path];
    if (limit === undefined) problems.push(`${r.path}: the only images allowed are ${Object.keys(IMAGES).join(' and ')} at the root of dist`);
    else if (r.bytes > limit) problems.push(`${r.path}: image is ${r.bytes} bytes, above its ${limit} byte limit`);
  }
  for (const g of LAZY) {
    if (/\.m?js$/.test(r.path) && g.test(basename(r.path)) && r.bytes > g.limit) problems.push(`${r.path}: ${g.what} is ${r.bytes} bytes, above its ${g.limit} byte limit`);
  }
  if (!/\.(?:js|mjs|css|html)$/i.test(r.path)) continue;
  const text = readFileSync(join(dist, r.path), 'utf8');
  if (r.path.endsWith('.css')) {
    if (/@import/i.test(text)) problems.push(`${r.path}: @import is not allowed`);
    for (const m of text.matchAll(/url\(\s*["']?([^"')]+)/gi)) {
      if (!m[1].startsWith('data:') && /^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(m[1])) problems.push(`${r.path}: loads ${m[1]}`);
    }
  }
  for (const m of text.matchAll(/\b(?:https?|wss?):\/\/([a-z0-9.-]+)/gi)) {
    if (!allowedHosts.has(m[1].toLowerCase())) problems.push(`${r.path}: mentions ${m[0]}, which is not an RPC endpoint, the explorer or an allowed link`);
  }
  if (/\b(?:importScripts|sendBeacon)\s*\(/.test(text)) problems.push(`${r.path}: uses importScripts or sendBeacon`);
}

if (preloads.length > PRELOAD_LIMIT) problems.push(`index.html preloads ${preloads.length} fonts, above the limit of ${PRELOAD_LIMIT}`);
if (fontBytes > FONTS_LIMIT) problems.push(`fonts are ${fontBytes} bytes, above the ${FONTS_LIMIT} byte budget`);
if (total > TOTAL_LIMIT) problems.push(`site is ${total} bytes, above the ${TOTAL_LIMIT} byte budget`);
if (entryBytes > ENTRY_LIMIT) problems.push(`index.html with its entry files is ${entryBytes} bytes, above the ${ENTRY_LIMIT} byte budget`);
if (firstPaint > FIRST_PAINT_LIMIT) problems.push(`first paint (entry plus preloaded fonts) is ${firstPaint} bytes, above the ${FIRST_PAINT_LIMIT} byte budget`);

const pad = (v, n) => String(v).padStart(n);
const pct = (v, of) => `${((100 * v) / of).toFixed(1)}%`;
console.log(relative(resolve(root, '..'), dist) || dist);
for (const r of rows) {
  const tag = entry.has(r.path) ? '  (entry)' : preloads.includes(r.path) ? '  (preloaded)' : '';
  console.log(`  ${pad(r.bytes, 8)} bytes  ${pad(r.gzip, 7)} gzip  ${r.path}${tag}`);
}
console.log(`  ${pad(total, 8)} bytes total            budget ${TOTAL_LIMIT}  (${pct(total, TOTAL_LIMIT)})`);
console.log(`  ${pad(entryBytes, 8)} bytes entry            budget ${ENTRY_LIMIT}  (${pct(entryBytes, ENTRY_LIMIT)})`);
console.log(`  ${pad(firstPaint, 8)} bytes first paint      budget ${FIRST_PAINT_LIMIT}  (${pct(firstPaint, FIRST_PAINT_LIMIT)}; ${preloads.length} font${preloads.length === 1 ? '' : 's'} preloaded)`);
console.log(`  ${pad(fontBytes, 8)} bytes fonts            budget ${FONTS_LIMIT}  (${pct(fontBytes, FONTS_LIMIT)})`);
if (!has('og.jpg') && /og\.jpg/.test(html)) console.log('  note: index.html names og.jpg, which is not in dist yet (the OG image is added later)');

if (problems.length > 0) {
  console.error('\ncheck-budget: FAILED');
  for (const p of [...new Set(problems)]) console.error(`  - ${p}`);
  process.exit(1);
}
console.log('check-budget: ok (within budget, self-contained)');
