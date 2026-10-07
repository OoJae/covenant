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

// The site bundles deployments/xlayer.json (src/config.ts), keeping only the fields src/config.ts reads (its
// `Deployment` interface). Never the `.site` section: it records the site's own publication (deploy/publish-site.sh
// writes it after a publish and builds from the file without it), so it must not feed the build it records, and its
// gateway host would fail scripts/check-budget.mjs. The rest (transaction hashes, commits, notes, the reference
// launch) is for people and scripts, not the page, and would cost about 4 KB of the entry budget. A field added to
// `Deployment` in src/config.ts must be added here too.
const DEPLOYMENT_READ: Record<string, true | string[]> = {
  chainId: true,
  deployer: true,
  keeper: true,
  issuance: ['splitter', 'transistors', 'circuits', 'keeperTank', 'teamRegistry', 'storyKeccak256', 'block'],
  probe: ['circuitId', 'gates', 'netlistKeccak256'],
  evaluator: ['sealedVM', 'fab'],
  core: ['kernelFactory', 'kernelImpl', 'lens'],
  flagship: ['chipId', 'kernel', 'netlistKeccak256'],
  coreV2: ['kernelFactory', 'kernelImpl', 'lens'],
  flagshipV2: ['chipId', 'kernel'],
  architect: ['payTo', 'agentWallet'],
  prelaunch: ['gluttonChipId', 'glutton512ChipId', 'keeperInvited'],
  glutton: ['chipId'],
};
const deploymentAsRead: Plugin = {
  name: 'covenant-deployment-as-read',
  enforce: 'pre',
  transform(code, id) {
    if (!id.split('?')[0].replace(/\\/g, '/').endsWith('/deployments/xlayer.json')) return null;
    const d = JSON.parse(code) as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const [key, keep] of Object.entries(DEPLOYMENT_READ)) {
      const v = d[key];
      if (v === undefined) continue;
      if (keep === true || v === null || typeof v !== 'object') out[key] = v;
      else out[key] = Object.fromEntries(keep.filter((k) => k in (v as object)).map((k) => [k, (v as Record<string, unknown>)[k]]));
    }
    return { code: JSON.stringify(out), map: null };
  },
};

// The three faces the first screen needs are preloaded (src/styles/fonts.css sets font-display: optional, so a face
// that is late is not swapped in: preloading makes it arrive in time, and nothing ever shifts). In a build their
// names carry a hash, so the links are written after bundling; on the dev server they point at the source files.
// Fragment Mono (labels and data) is not preloaded: scripts/check-budget.mjs allows three preloads at most.
const PRELOADED_FONTS = ['bodoni-moda-roman', 'bodoni-moda-italic', 'instrument-sans'];
const fontPreload: Plugin = {
  name: 'covenant-font-preload',
  transformIndexHtml: {
    order: 'post',
    handler(_html, ctx) {
      const hrefs: string[] = [];
      for (const font of PRELOADED_FONTS) {
        if (!ctx.bundle) {
          hrefs.push(`/src/fonts/${font}.woff2`);
          continue;
        }
        const asset = Object.values(ctx.bundle).find((f) => {
          if (f.type !== 'asset' || !f.fileName.endsWith('.woff2')) return false;
          const a = f as { originalFileNames?: string[]; names?: string[]; name?: string };
          const names = [...(a.originalFileNames ?? []), ...(a.names ?? []), ...(a.name ? [a.name] : [])];
          return names.some((n) => n.replace(/\\/g, '/').split('/').pop() === `${font}.woff2`);
        });
        if (!asset) throw new Error(`covenant-font-preload: ${font}.woff2 is not in the bundle (is it still referenced by src/styles/fonts.css?)`);
        hrefs.push(`./${asset.fileName}`);
      }
      return hrefs.map((href) => ({
        tag: 'link',
        attrs: { rel: 'preload', href, as: 'font', type: 'font/woff2', crossorigin: true },
        injectTo: 'head' as const,
      }));
    },
  },
};

export default defineConfig({
  base: './',
  plugins: [deploymentAsRead, fontPreload],
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
