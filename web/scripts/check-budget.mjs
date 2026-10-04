// Fails the build if web/dist breaks the rules for a site that will be stored on chain:
//   - whole site at most 240,000 bytes;
//   - index.html plus its entry script and stylesheet at most 96,000 bytes;
//   - fully self-contained: no script, stylesheet, font or image loaded from another origin,
//     no source maps, and no URL in the code except the RPC endpoints and explorer links.
// Sizes are bytes on disk (what on-chain storage is paid for), not gzip.
//
//   node scripts/check-budget.mjs            checks web/dist
//   node scripts/check-budget.mjs some/dir   checks another build output

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';

const TOTAL_LIMIT = 240_000;
const ENTRY_LIMIT = 96_000;

const root = fileURLToPath(new URL('../', import.meta.url));
const dist = process.argv[2] ? resolve(process.argv[2]) : join(root, 'dist');
const addresses = JSON.parse(readFileSync(join(root, 'src/addresses.json'), 'utf8'));

// Hosts the code may mention: the RPC endpoints it calls, the explorer it links to, and the
// XML namespace identifiers Preact needs to create SVG and MathML nodes (never fetched).
const allowedHosts = new Set([...addresses.rpc.map((u) => new URL(u).host), 'www.oklink.com', 'www.w3.org']);

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
  .map((f) => ({ path: relative(dist, f), bytes: statSync(f).size, gzip: gzipSync(readFileSync(f), { level: 9 }).length }))
  .sort((a, b) => b.bytes - a.bytes);
const total = rows.reduce((n, r) => n + r.bytes, 0);

// The entry: index.html and every script and stylesheet it names.
const html = readFileSync(join(dist, 'index.html'), 'utf8');
const refs = [...html.matchAll(/<(?:script|link|img|source|iframe|audio|video)\b[^>]*?\b(?:src|href)\s*=\s*["']([^"']+)["']/gi)].map((m) => m[1]);
const entry = new Set(['index.html']);
for (const ref of refs) {
  if (ref.startsWith('data:')) continue; // inlined, e.g. the icon
  if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(ref)) problems.push(`index.html loads ${ref} from another origin`);
  else if (ref.startsWith('/')) problems.push(`index.html uses the absolute path ${ref}; paths must be relative so the site works from any folder`);
  else entry.add(ref.replace(/^\.\//, ''));
}
const entryBytes = rows.filter((r) => entry.has(r.path)).reduce((n, r) => n + r.bytes, 0);
for (const name of entry) if (!rows.some((r) => r.path === name)) problems.push(`index.html refers to ${name}, which is not in dist`);

for (const r of rows) {
  if (r.path.endsWith('.map')) problems.push(`${r.path}: source maps must not ship`);
  if (/\.(?:woff2?|ttf|otf|eot)$/i.test(r.path)) problems.push(`${r.path}: no font files (system font stack only)`);
  if (!/\.(?:js|mjs|css|html)$/i.test(r.path)) continue;
  const text = readFileSync(join(dist, r.path), 'utf8');
  if (r.path.endsWith('.css')) {
    if (/@import/i.test(text)) problems.push(`${r.path}: @import is not allowed`);
    for (const m of text.matchAll(/url\(\s*["']?([^"')]+)/gi)) {
      if (!m[1].startsWith('data:') && /^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(m[1])) problems.push(`${r.path}: loads ${m[1]}`);
    }
  }
  for (const m of text.matchAll(/\b(?:https?|wss?):\/\/([a-z0-9.-]+)/gi)) {
    if (!allowedHosts.has(m[1].toLowerCase())) problems.push(`${r.path}: mentions ${m[0]}, which is not an RPC endpoint or the explorer`);
  }
  if (/\b(?:importScripts|sendBeacon)\s*\(/.test(text)) problems.push(`${r.path}: uses importScripts or sendBeacon`);
}

if (total > TOTAL_LIMIT) problems.push(`site is ${total} bytes, above the ${TOTAL_LIMIT} byte budget`);
if (entryBytes > ENTRY_LIMIT) problems.push(`index.html with its entry files is ${entryBytes} bytes, above the ${ENTRY_LIMIT} byte budget`);

const pad = (v, n) => String(v).padStart(n);
console.log(relative(resolve(root, '..'), dist) || dist);
for (const r of rows) console.log(`  ${pad(r.bytes, 8)} bytes  ${pad(r.gzip, 7)} gzip  ${r.path}${entry.has(r.path) ? '  (entry)' : ''}`);
console.log(`  ${pad(total, 8)} bytes total            budget ${TOTAL_LIMIT}  (${((100 * total) / TOTAL_LIMIT).toFixed(1)}%)`);
console.log(`  ${pad(entryBytes, 8)} bytes entry            budget ${ENTRY_LIMIT}  (${((100 * entryBytes) / ENTRY_LIMIT).toFixed(1)}%)`);

if (problems.length > 0) {
  console.error('\ncheck-budget: FAILED');
  for (const p of [...new Set(problems)]) console.error(`  - ${p}`);
  process.exit(1);
}
console.log('check-budget: ok (within budget, self-contained)');
