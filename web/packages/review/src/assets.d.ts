// Vite inlines these into the one-file page (vite.config.ts: assetsInlineLimit) as data URLs.
declare module "*.svg" {
  const url: string;
  export default url;
}
declare module "*.png" {
  const url: string;
  export default url;
}
