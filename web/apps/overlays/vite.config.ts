/// <reference types="vitest/config" />
import { resolve } from 'node:path';
import { defineConfig } from 'vite';

// One page per overlay window → dist/overlays/<name>.html. crates/blurt-capture loads
// WebviewUrl::App("overlays/<name>.html"), so the Tauri app's frontendDist must contain that folder (copy
// dist/overlays into it, or point frontendDist at dist/ as crates/blurt-capture/demo does).
const pages = ['index', 'picker', 'island', 'note'];

export default defineConfig({
  base: './',
  build: {
    outDir: 'dist/overlays',
    emptyOutDir: true,
    target: 'es2022',
    rollupOptions: { input: Object.fromEntries(pages.map((p) => [p, resolve(import.meta.dirname, `${p}.html`)])) },
  },
  server: { port: 5178, strictPort: true },
  test: { environment: 'node', include: ['tests/**/*.test.ts'] },
});
