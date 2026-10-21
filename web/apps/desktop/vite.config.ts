/// <reference types="vitest/config" />
import { cpSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';

// blurt_capture opens WebviewUrl::App("overlays/<name>.html"): the overlay pages (web/apps/overlays, built first by
// tauri.conf's beforeBuildCommand) must sit in this app's dist/overlays.
function copyOverlays(): Plugin {
  return {
    name: 'blurt-copy-overlays',
    apply: 'build',
    closeBundle() {
      const src = resolve(import.meta.dirname, '../overlays/dist/overlays');
      if (existsSync(src)) cpSync(src, resolve(import.meta.dirname, 'dist/overlays'), { recursive: true });
      else this.warn('web/apps/overlays is not built: recording overlays will be missing (pnpm --filter @blurt/overlays build)');
    },
  };
}

// Tauri expects a fixed port in dev and plain relative assets in the bundle.
export default defineConfig({
  plugins: [react(), copyOverlays()],
  clearScreen: false,
  base: './',
  server: { port: 1420, strictPort: true },
  build: { target: 'es2021', outDir: 'dist', emptyOutDir: true, chunkSizeWarningLimit: 800 },
  test: { environment: 'node', include: ['src/**/*.test.ts'] },
});
