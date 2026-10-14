// PDF page items (format.md §8.2.6) drawn with pdf.js, loaded only when a
// note shows one. The PDF bytes come from a verified blob; pdf.js parses
// them in its worker (a file of the viewer, created through a Trusted Types
// policy that admits exactly that URL), draws glyphs as paths (no font
// loading), runs no scripts, renders no annotations (§8.2.6: `/Annots` are
// not drawn) and fetches nothing but its own bundled font data (standard
// fonts, CMaps) and JavaScript image decoders from the viewer's origin.

import type { PDFDocumentProxy, PDFPageProxy } from "pdfjs-dist/legacy/build/pdf.mjs";
import workerURL from "pdfjs-dist/legacy/build/pdf.worker.min.mjs?url";

type PDFJS = typeof import("pdfjs-dist/legacy/build/pdf.mjs");

/** Largest PDF blob the viewer reads (held in memory for pdf.js). */
export const maxPDFBytes = 256 * 1024 * 1024;
/** Most pixels one rendered PDF crop may have. */
export const maxPDFPixels = 16_000_000;
/** A page that takes longer is abandoned and drawn as a placeholder. */
const renderTimeout = 30_000;

interface TrustedTypePolicyLike {
  createScriptURL(url: string): unknown;
}

interface TrustedTypesLike {
  createPolicy(name: string, rules: { createScriptURL(url: string): string }): TrustedTypePolicyLike;
}

let library: Promise<PDFJS> | undefined;

/** The pdf.js worker's URL, resolved against the page (the bundle's own asset). */
export function pdfWorkerURL(): string {
  return new URL(workerURL, document.baseURI).href;
}

let policy: TrustedTypePolicyLike | undefined;
let worker: Worker | undefined;

/** Starts a pdf.js worker and makes it the one new documents use. */
function startWorker(lib: PDFJS): void {
  const url = pdfWorkerURL();
  const tt = (globalThis as { trustedTypes?: TrustedTypesLike }).trustedTypes;
  // The CSP allows this one policy (docs/web-viewer.md); it only ever admits the bundled worker.
  policy ??= tt?.createPolicy("sempere-pdf-worker", {
    createScriptURL: (u: string) => {
      if (u !== url) throw new TypeError("unexpected worker URL");
      return u;
    },
  });
  const scriptURL = policy ? policy.createScriptURL(url) : url;
  worker = new Worker(scriptURL as string, { type: "module", name: "pdf.js" });
  lib.GlobalWorkerOptions.workerPort = worker;
}

/** Loads pdf.js once and starts its worker. */
function pdfjs(): Promise<PDFJS> {
  library ??= import("pdfjs-dist/legacy/build/pdf.mjs").then((lib) => {
    startWorker(lib);
    return lib;
  });
  return library;
}

/**
 * Stops a worker that a hostile or broken PDF keeps busy, so the PDFs of
 * later notes get a fresh one (documents of the old worker then fail).
 */
function replaceWorker(): void {
  worker?.terminate();
  worker = undefined;
  void library?.then(startWorker);
}

/** `p`, or a `PDFError` after `ms` (then `onTimeout` runs). */
async function within<T>(p: Promise<T>, ms: number, what: string, onTimeout: () => void): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      onTimeout();
      reject(new PDFError(`${what} took longer than ${ms / 1000} s`));
    }, ms);
  });
  try {
    return await Promise.race([p, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

/** Where the bundled pdf.js data lives (copied into `dist/pdfjs/` by the build). */
function assetURL(dir: string): string {
  return new URL(`pdfjs/${dir}/`, document.baseURI).href;
}

/**
 * The pdf.js viewport that draws the part `crop` of the effective page
 * (points, y down, format.md §8.5.1) at `scale` pixels per point (lowered to
 * stay within `maxPDFPixels`) onto a `width × height` canvas. pdf.js's
 * viewport at scale 1 is the effective page: CropBox ∩ MediaBox turned by
 * `/Rotate` (test/pdf.test.ts checks it against the §8.5.1 tables).
 */
export function cropViewport(page: PDFPageProxy, crop: { x: number; y: number; w: number; h: number }, scale: number) {
  let s = scale;
  if (crop.w * crop.h * s * s > maxPDFPixels) s = Math.sqrt(maxPDFPixels / (crop.w * crop.h));
  const width = Math.max(1, Math.round(crop.w * s)), height = Math.max(1, Math.round(crop.h * s));
  const viewport = page.getViewport({ scale: s, offsetX: -crop.x * s, offsetY: -crop.y * s });
  return { viewport, width, height, scale: s };
}

export class PDFError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PDFError";
  }
}

/** The PDF documents of one open note, each parsed once. */
export class NotePDFs {
  private readonly docs = new Map<string, Promise<PDFDocumentProxy>>();
  private destroyed = false;

  async document(key: string, bytes: () => Promise<Uint8Array>): Promise<PDFDocumentProxy> {
    if (this.destroyed) throw new PDFError("the note was closed");
    let p = this.docs.get(key);
    if (!p) {
      p = (async () => {
        const lib = await pdfjs();
        const task = lib.getDocument({
          data: await bytes(),
          useWorkerFetch: true,
          standardFontDataUrl: assetURL("standard_fonts"),
          cMapUrl: assetURL("cmaps"),
          wasmUrl: assetURL("wasm"),
          useWasm: false,
          disableFontFace: true,
          useSystemFonts: false,
          enableXfa: false,
          stopAtErrors: false,
          maxImageSize: 100_000_000,
          verbosity: 0,
        });
        task.onPassword = () => {
          void task.destroy();
        };
        let doc: PDFDocumentProxy;
        try {
          doc = await within(task.promise, renderTimeout, "reading the PDF", () => {
            void task.destroy();
            replaceWorker();
          });
        } catch (e) {
          if (e instanceof PDFError) throw e;
          throw new PDFError(`the PDF cannot be read (${e instanceof Error ? e.message : String(e)})`);
        }
        // Closed while loading: nothing may outlive the note.
        if (this.destroyed) {
          void task.destroy();
          throw new PDFError("the note was closed");
        }
        return doc;
      })();
      this.docs.set(key, p);
    }
    return p;
  }

  async page(doc: PDFDocumentProxy, index: number): Promise<PDFPageProxy> {
    if (!(index >= 0 && index < doc.numPages)) throw new PDFError(`the PDF has no page ${index + 1}`);
    return within(doc.getPage(index + 1), renderTimeout, "reading the PDF page", replaceWorker);
  }

  /** The effective page's size in points (§8.2.6: CropBox ∩ MediaBox, turned by `/Rotate`). */
  static effectiveSize(page: PDFPageProxy): { w: number; h: number } {
    const v = page.getViewport({ scale: 1 });
    return { w: v.width, h: v.height };
  }

  /**
   * Renders the part `crop` of the effective page (points, y down) at
   * `scale` pixels per point onto a new canvas: on white, as viewers show a
   * page, or on nothing (`transparent`: a math item's render, §8.2.8).
   */
  async render(page: PDFPageProxy, crop: { x: number; y: number; w: number; h: number }, scale: number,
    transparent = false): Promise<HTMLCanvasElement> {
    const lib = await pdfjs();
    const { viewport, width, height } = cropViewport(page, crop, scale);
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const task = page.render({ canvas, viewport, annotationMode: lib.AnnotationMode.DISABLE,
      background: transparent ? "rgba(0,0,0,0)" : "#ffffff" });
    const timer = setTimeout(() => task.cancel(), renderTimeout);
    try {
      await task.promise;
    } catch (e) {
      throw new PDFError(`the PDF page cannot be drawn (${e instanceof Error ? e.message : String(e)})`);
    } finally {
      clearTimeout(timer);
    }
    return canvas;
  }

  destroy(): void {
    if (this.destroyed) return;
    this.destroyed = true;
    for (const p of this.docs.values()) p.then((d) => d.loadingTask.destroy(), () => undefined).catch(() => undefined);
    this.docs.clear();
  }
}
