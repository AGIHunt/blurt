import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";
import { viteSingleFile } from "vite-plugin-singlefile";

// One self-contained HTML file: review.py serves it as skills/blurt/scripts/review.html, the macOS app bundles it as
// blurt-app://ui/index.html, the Tauri app embeds it. scripts/publish.mjs copies it into the skill and checks its size.
export default defineConfig({
  base: "./",
  plugins: [react(), viteSingleFile({ removeViteModuleLoader: true })],
  build: {
    target: ["safari15", "chrome100", "firefox100"],
    outDir: "dist",
    emptyOutDir: true,
    cssCodeSplit: false,
    assetsInlineLimit: 100_000_000,
    reportCompressedSize: false,
  },
  test: {
    include: ["test/**/*.test.{ts,tsx}"],
    environment: "jsdom",
  },
});
