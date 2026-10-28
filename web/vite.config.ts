import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import type { Plugin } from "vite";
import { defineConfig } from "vitest/config";

/**
 * The Content-Security-Policy of the built page (docs/web-viewer.md "Threat
 * model"). Scripts and styles come only from the page's own origin; network
 * requests go only to the page's origin plus the origins listed in
 * SEMPERE_CONNECT_SRC (space-separated, e.g. a WebDAV share on another host);
 * no frames, forms, plugins or <base>; Trusted Types forbid string-to-DOM
 * sinks. Serve the same policy as an HTTP header too (frame-ancestors only
 * works there); the meta tag protects copies served without it.
 */
export function contentSecurityPolicy(connect: string[] = []): string {
  return [
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self'",
    // blob: URLs are made by the page itself from verified attachment blobs.
    "img-src 'self' data: blob:",
    "media-src blob:",
    `connect-src ${["'self'", ...connect].join(" ")}`,
    "base-uri 'none'",
    "form-action 'none'",
    "object-src 'none'",
    "frame-src 'none'",
    // pdf.js's worker and the key worker (scrypt), files of the viewer (docs/web-viewer.md).
    "worker-src 'self'",
    "manifest-src 'none'",
    "require-trusted-types-for 'script'",
    // Two policies, each admitting only one worker's URL: pdf.js's (src/ui/pdf.ts) and the
    // key worker's (src/ui/keyunwrap.ts).
    "trusted-types sempere-pdf-worker sempere-key-worker",
  ].join("; ");
}

function connectOrigins(): string[] {
  const raw = process.env.SEMPERE_CONNECT_SRC ?? "";
  return raw.split(/\s+/).filter((o) => o.length > 0).map((o) => {
    const u = new URL(o);
    if (u.protocol !== "https:" && u.protocol !== "http:") throw new Error(`SEMPERE_CONNECT_SRC: not an http(s) origin: ${o}`);
    return u.origin;
  });
}

function csp(): Plugin {
  return {
    name: "sempere-csp",
    apply: "build",
    transformIndexHtml: {
      order: "post",
      handler: () => [{
        tag: "meta", injectTo: "head-prepend",
        attrs: { "http-equiv": "Content-Security-Policy", content: contentSecurityPolicy(connectOrigins()) },
      }],
    },
  };
}

/**
 * The pdf.js data the viewer serves itself (src/ui/pdf.ts): standard fonts
 * and CMaps for PDFs that do not embed their fonts, and the JavaScript JPEG
 * 2000 and JBIG2 decoders (no WebAssembly: the CSP has no 'wasm-unsafe-eval').
 * Emitted under `pdfjs/` in the build, served from node_modules in dev.
 */
function pdfjsAssets(): Plugin {
  const root = join(import.meta.dirname, "node_modules", "pdfjs-dist");
  const files = (): [string, string][] => [
    ...["standard_fonts", "cmaps"].flatMap((d) => readdirSync(join(root, d)).map((f): [string, string] => [`${d}/${f}`, join(root, d, f)])),
    ...["openjpeg_nowasm_fallback.js", "jbig2_nowasm_fallback.js"].map((f): [string, string] => [`wasm/${f}`, join(root, "wasm", f)]),
  ];
  return {
    name: "sempere-pdfjs-assets",
    configureServer(server) {
      const map = new Map(files());
      server.middlewares.use((req, res, next) => {
        const m = /\/pdfjs\/([^?]+)/.exec(req.url ?? "");
        const file = m ? map.get(m[1] ?? "") : undefined;
        if (!file) return next();
        res.setHeader("Content-Type", file.endsWith(".js") ? "text/javascript" : "application/octet-stream");
        res.end(readFileSync(file));
      });
    },
    generateBundle() {
      for (const [name, file] of files()) this.emitFile({ type: "asset", fileName: `pdfjs/${name}`, source: readFileSync(file) });
    },
  };
}

export default defineConfig({
  base: "./",
  plugins: [csp(), pdfjsAssets()],
  build: {
    target: "es2022",
    modulePreload: { polyfill: false },
    sourcemap: false,
    assetsInlineLimit: 0,
  },
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
  },
});
