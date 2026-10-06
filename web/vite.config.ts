import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { defineConfig, type Plugin } from 'vite';

// The production build must be self-contained static files (it will be stored on chain):
// relative URLs, no module-preload helper, and index.html naming one script and one stylesheet.
// The circuit bench and the kernel pages are further scripts fetched on demand (see src/app.tsx).
//
// COVENANT_FORK=web/.fork/deployment.json points the site at the local fork that scripts/fork-fixture.sh builds:
// its addresses replace deployments/xlayer.json and its RPC replaces the public endpoints, and every page carries
// a SIMULATION banner. A build made that way also fails scripts/check-budget.mjs (its RPC host is not allowed), so
// it cannot be published by accident.
const forkPath = process.env.COVENANT_FORK;
const fork = forkPath ? JSON.parse(readFileSync(resolve(process.cwd(), forkPath.replace(/^web\//, '')), 'utf8')) : null;

// The site bundles deployments/xlayer.json (src/config.ts) without its `.site` section. That section records the
// site's own publication (deploy/publish-site.sh writes it after a publish and builds from the file without it): it
// must not feed the build it records, and its gateway host would fail scripts/check-budget.mjs. The site reads none
// of it.
const withoutSiteRecord: Plugin = {
  name: 'covenant-deployment-without-site',
  enforce: 'pre',
  transform(code, id) {
    if (!id.split('?')[0].replace(/\\/g, '/').endsWith('/deployments/xlayer.json')) return null;
    const d = JSON.parse(code) as Record<string, unknown>;
    if (!('site' in d)) return null;
    delete d.site;
    return { code: JSON.stringify(d), map: null };
  },
};

export default defineConfig({
  base: './',
  plugins: [withoutSiteRecord],
  oxc: { jsx: { runtime: 'automatic', importSource: 'preact' } },
  define: { __COVENANT_FORK__: JSON.stringify(fork) },
  build: {
    target: 'es2022',
    cssCodeSplit: false,
    assetsInlineLimit: 0,
    modulePreload: false,
    sourcemap: false,
  },
  server: { port: 5173, strictPort: false },
  preview: { port: 4173, strictPort: false },
});
