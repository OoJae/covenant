import { defineConfig } from 'vite';

// The production build must be self-contained static files (it will be stored on chain):
// relative URLs, no module-preload helper, and index.html naming one script and one stylesheet.
// The circuit bench is a second script fetched on demand (see src/app.tsx).
export default defineConfig({
  base: './',
  oxc: { jsx: { runtime: 'automatic', importSource: 'preact' } },
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
