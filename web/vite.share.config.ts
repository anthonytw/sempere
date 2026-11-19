import { join } from "node:path";
import type { Plugin } from "vite";
import { defineConfig } from "vite";

/**
 * The share viewer's build (`npm run build:share`, docs/web-viewer.md "Share files"): the note view and its
 * renderers as one classic script and one stylesheet, which `scripts/build-share.ts` inlines into
 * `share-viewer.html`. pdf.js is left out: a shared note's PDF pages are pictures (design D4).
 */
function withoutPDF(): Plugin {
  const stub = join(import.meta.dirname, "src", "share", "pdfstub.ts");
  return {
    name: "sempere-share-no-pdf",
    enforce: "pre",
    resolveId(source, importer) {
      if (source === "./pdf.ts" && importer !== undefined && /[\\/]ui[\\/]noteview\.ts$/.test(importer)) return stub;
      return null;
    },
  };
}

export default defineConfig({
  base: "./",
  plugins: [withoutPDF()],
  build: {
    outDir: "dist-share",
    emptyOutDir: true,
    target: "es2022",
    sourcemap: false,
    cssCodeSplit: false,
    assetsInlineLimit: 0,
    lib: { entry: join(import.meta.dirname, "src", "share", "main.ts"), formats: ["iife"], name: "SempereShare", fileName: () => "share.js", cssFileName: "share" },
  },
});
