// Writes the two fixture sites used by the fork tests and the TypeScript tests. Deterministic: running it
// again produces identical files (the 60,000-byte file comes from a fixed-seed xorshift32 generator).
//   node tools/deweb/sim/test/fixtures/make-fixtures.mjs
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const write = (site, path, content) => {
  const file = join(here, site, path);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, content);
};

/** `n` bytes of xorshift32 output, seed fixed. */
function noise(n, seed) {
  const out = new Uint8Array(n);
  let x = seed >>> 0;
  for (let i = 0; i < n; i++) {
    x ^= x << 13; x >>>= 0;
    x ^= x >>> 17;
    x ^= x << 5; x >>>= 0;
    out[i] = x & 255;
  }
  return out;
}

const html = (title, extra) => `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>${title}</title>
    <link rel="stylesheet" href="./style.css" />
    <script type="module" src="./app.js"></script>
  </head>
  <body>
    <p id="out">fixture</p>${extra}
  </body>
</html>
`;

for (const site of ['site', 'site-v2']) rmSync(join(here, site), { recursive: true, force: true });

// site: four small files and one 60,000-byte file (three chunks: 24,000 + 24,000 + 12,000)
write('site', 'index.html', html('DeWEB fixture', ''));
write('site', 'app.js', "document.getElementById('out').textContent = 'fixture: script ran';\n");
write('site', 'style.css', 'body { font: 16px/1.5 system-ui, sans-serif; margin: 2rem; }\n');
write('site', 'data.json', JSON.stringify({ fixture: true, files: 5 }) + '\n');
write('site', 'big.bin', noise(60000, 0x9e3779b9));

// site-v2: the same site after an edit. index.html changed, app.js and data.json unchanged,
// style.css and big.bin gone, two new files in sub-directories. One of them has a path and a content type
// longer than 31 bytes (strings that long take extra storage slots, which the gas estimate must count).
write('site-v2', 'index.html', html('DeWEB fixture, second version', '\n    <p>second version</p>'));
write('site-v2', 'app.js', "document.getElementById('out').textContent = 'fixture: script ran';\n");
write('site-v2', 'data.json', JSON.stringify({ fixture: true, files: 5 }) + '\n');
write('site-v2', 'notes/read-me.txt', 'A file in a sub-directory, added in the second version.\n');
write('site-v2', 'notes/a-path-longer-than-thirty-two-bytes/site.webmanifest', JSON.stringify({ name: 'DeWEB fixture', display: 'browser' }) + '\n');
console.log('fixtures written under', here);
