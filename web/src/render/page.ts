// One note page validated and outlined once (Sources/SempereRender/PageComposer.swift),
// and its SVG (SVGWriter.swift). The viewer draws exactly this SVG, so what is
// on screen is what `sempere export --format svg` writes.

import { type NoteMeta, type Page, type Paper, pointStride } from "../format/model.ts";
import { paperCommands, rulingCount, sheetHeight } from "./paper.ts";
import {
  type DrawCommand, RenderError, RenderLimits, fmt, paint, paintHex, pointCount,
} from "./primitives.ts";
import { meanScale, strokeCommands, transformOf } from "./stroke.ts";
import { type PreparedItem, maxItemsPerPage, prepareItem } from "./items.ts";
import { expandMarkdown } from "./markdown.ts";
import type { Measure } from "./text.ts";
import { cmpItems } from "../format/registers.ts";

export interface RenderOptions {
  paper: boolean;
  tolerance: number;
  infiniteChunkHeight?: number;
  /** Text widths for laying Markdown boxes out (§8.5.4); the approximate measure when absent. */
  measure?: Measure;
}

export const defaultRenderOptions: RenderOptions = { paper: true, tolerance: 0.05 };

export interface PreparedStroke {
  commands: DrawCommand[];
  minY: number;
  maxY: number;
  centreY: number;
  /** Drawn below the content items: a marker on a note with `markersBehindText` (§8.2.3). */
  behindItems?: boolean;
}

/** The option, else the sheet height of the pageless page (PageComposer.chunkHeight). */
export function chunkHeight(options: RenderOptions, meta: NoteMeta): number {
  const base = options.infiniteChunkHeight ?? sheetHeight({ ...meta.pageSize, infinite: true });
  return Math.min(Math.max(Number.isFinite(base) ? base : 792, 72), RenderLimits.maxExtent);
}

export class PreparedPage {
  readonly paper: Paper;
  readonly strokes: PreparedStroke[] = [];
  /** Placed items in drawing order (§8.2.3); those that cannot be drawn are in `warnings`. */
  readonly items: PreparedItem[] = [];
  readonly warnings: string[] = [];
  /** Page height: `pageSize.height`, or for infinite pages also the lowest ink and one chunk. */
  readonly extent: number;
  /** `paper`, or its plain background when ruling every band would be too much. */
  readonly drawnPaper: Paper;

  constructor(page: Page, readonly meta: NoteMeta, readonly options: RenderOptions = defaultRenderOptions,
    maxOutlinePoints: number = RenderLimits.maxOutlinePoints) {
    const size = meta.pageSize;
    const maxE = RenderLimits.maxExtent;
    if (!(Number.isFinite(size.width) && size.width > 0 && size.width <= maxE && Number.isFinite(size.height)
      && size.height >= 0 && size.height <= maxE && (size.infinite || size.height > 0))) {
      throw new RenderError("the page size is invalid");
    }
    this.paper = page.paper ?? meta.paper;
    let low = 0;
    let outline = 0;
    for (const stroke of page.strokes) {
      const n = stroke.points.length / pointStride;
      if (n === 0) continue;
      const xf = transformOf(stroke);
      if (![...xf, stroke.ink.width].every(Number.isFinite)) throw new RenderError("a stroke has a non-finite transform or width");
      let radius = Math.abs(stroke.ink.width);
      let lo = Infinity, hi = -Infinity;
      // Scalar reads and the transform inlined (applyTransform's arithmetic, in its order): no
      // allocation per point. A read past the end is undefined, so a short last point fails as before.
      const pts = stroke.points;
      const [a, b, c, d, tx, ty] = xf;
      for (let i = 0; i < n; i++) {
        const base = i * pointStride;
        const x = pts[base], y = pts[base + 1], w = pts[base + 3], h = pts[base + 4], o = pts[base + 5], f = pts[base + 6];
        if (!(Number.isFinite(x) && Number.isFinite(y) && Number.isFinite(w) && Number.isFinite(h) && Number.isFinite(o) && Number.isFinite(f))) {
          throw new RenderError("a stroke has non-finite points");
        }
        const qx = a * (x as number) + c * (y as number) + tx, qy = b * (x as number) + d * (y as number) + ty;
        if (!Number.isFinite(qx) || !Number.isFinite(qy)) throw new RenderError("a stroke has non-finite points");
        if (Math.abs(qx) > maxE || Math.abs(qy) > maxE) {
          throw new RenderError("a stroke reaches beyond the supported extent");
        }
        lo = Math.min(lo, qy);
        hi = Math.max(hi, qy);
        radius = Math.max(radius, Math.abs(w as number), Math.abs(h as number));
      }
      const pad = Math.min(radius * meanScale(xf), RenderLimits.maxNibWidth) / 2 + 1;
      if (!Number.isFinite(pad) || pad > maxE) throw new RenderError("a stroke is too wide");
      const commands = strokeCommands(stroke, options.tolerance);
      outline += commands.reduce((m, c) => m + pointCount(c), 0);
      if (outline > maxOutlinePoints) throw new RenderError("the page has more ink geometry than the renderer accepts");
      const behindItems = meta.markersBehindText === true && stroke.ink.tool === "marker";
      this.strokes.push({ commands, minY: lo - pad, maxY: hi + pad, centreY: lo / 2 + hi / 2, ...(behindItems ? { behindItems } : {}) });
      low = Math.max(low, hi + pad);
    }
    // Items count toward an infinite page's extent like strokes (§8.2.3); one
    // that cannot be drawn is skipped, never fatal to the page (§8.5.2).
    // A Markdown box counts as the pieces it is drawn as (§8.4, §8.5.4).
    let cut = false;
    for (const item of [...page.items].sort(cmpItems).slice(0, maxItemsPerPage)) {
      if (this.items.length >= maxItemsPerPage) { cut = true; break; }
      const p = prepareItem(item);
      if (typeof p === "string") {
        this.warnings.push(`item ${String(item.id).slice(0, 8)}: ${p}`);
        continue;
      }
      const md = expandMarkdown(p, options.measure);
      if (md) {
        // A Markdown box is drawn as its pieces (§8.5.4).
        const kept = md.pieces.slice(0, maxItemsPerPage - this.items.length);
        if (kept.length < md.pieces.length) cut = true;
        this.items.push(...kept);
        for (const q of kept) low = Math.max(low, q.maxY);
        if (md.unrendered > 0) {
          this.warnings.push(`text box ${String(item.id).slice(0, 8)}: ${md.unrendered} formula${md.unrendered === 1 ? " is" : "s are"} `
            + "drawn as its LaTeX source (no typeset rendering stored)");
        }
      } else {
        this.items.push(p);
      }
      low = Math.max(low, p.maxY);
    }
    if (page.items.length > maxItemsPerPage || cut) this.warnings.push(`more than ${maxItemsPerPage} items; the rest are not drawn`);
    if (size.infinite) {
      if (low > maxE) throw new RenderError("the page is taller than the supported extent");
      this.extent = Math.max(size.height, Math.ceil(low), chunkHeight(options, meta));
    } else {
      // Ink centred at or below a finite page adds to its extent (PageComposer.swift).
      let below = 0;
      for (const sp of [...this.strokes, ...this.items.map((i) => ({ minY: i.minY, maxY: i.maxY, centreY: i.minY / 2 + i.maxY / 2 }))]) {
        if (sp.centreY >= size.height) below = Math.max(below, sp.maxY);
      }
      this.extent = Math.max(size.height, Math.ceil(Math.min(below, maxE)));
    }
    let ruling = 0;
    for (const c of chunks(meta, this.extent, chunkHeight(options, meta))) {
      const k = rulingCount(this.paper, c.width, c.yOffset, c.yEnd, sheetHeight(size)) ?? 0;
      if (k <= RenderLimits.maxPaperCommands) ruling += k;
    }
    this.drawnPaper = ruling <= RenderLimits.maxPaperCommandsPerPage ? this.paper
      : { ...this.paper, kindName: "blank", lineWidth: 0.5, dotRadius: 0.9, marginLeft: 0, marginTop: 0,
        marginColor: "#F2A6A6FF", cueWidth: 150, summaryHeight: 120, staffSpacing: 7, staffGap: 40 };
  }

  /** Paper for the whole page in one coordinate space (the SVG layout). */
  fullPagePaper(): DrawCommand[] {
    if (!this.options.paper) return [];
    const w = this.meta.pageSize.width;
    const out: DrawCommand[] = [{
      primitive: { kind: "rect", x: 0, y: 0, width: w, height: this.extent }, fill: paint(this.paper.background), lineWidth: 1,
    }];
    const h = this.meta.pageSize.infinite ? chunkHeight(this.options, this.meta) : this.extent;
    const count = Math.max(Math.ceil(this.extent / h), 1);
    for (let i = 0; i < count; i++) {
      const top = i * h;
      const bottom = i === count - 1 ? this.extent : (i + 1) * h;
      out.push(...paperCommands(this.drawnPaper, w, bottom - top, {
        yOffset: top, yEnd: bottom, originY: 0, includeBackground: false, sheetHeight: sheetHeight(this.meta.pageSize),
      }));
    }
    return out;
  }

  allStrokeCommands(): DrawCommand[] {
    return this.strokes.flatMap((s) => s.commands);
  }

  /** The strokes drawn below (`behind`) or above the content items (§8.2.3; Swift `strokeCommands(behind:)`). */
  strokeCommands(behind: boolean): DrawCommand[] {
    return this.strokes.filter((s) => (s.behindItems === true) === behind).flatMap((s) => s.commands);
  }

  /** Index in `items` before which the strokes behind the items go: the first content-layer item (≥ 100). */
  underIndex(): number {
    const i = this.items.findIndex((it) => !it.fillsBackground);
    return i < 0 ? this.items.length : i;
  }
}

function chunks(meta: NoteMeta, extent: number, h: number): { yOffset: number; yEnd: number; width: number }[] {
  const w = meta.pageSize.width;
  if (!meta.pageSize.infinite) return [{ yOffset: 0, yEnd: extent, width: w }];
  const count = Math.max(Math.ceil(extent / h), 1);
  return Array.from({ length: count }, (_, i) => ({ yOffset: i * h, yEnd: (i + 1) * h, width: w }));
}

// MARK: - SVG

/** An SVG element as tag + attributes, serialisable to text or DOM. */
export interface SVGElementSpec {
  tag: "rect" | "line" | "circle" | "polyline" | "path";
  attrs: [string, string][];
}

function paintAttrs(name: string, p: { r: number; g: number; b: number; alpha: number }): [string, string][] {
  const out: [string, string][] = [[name, paintHex(p)]];
  if (p.alpha < 0.9995) out.push([`${name}-opacity`, fmt(p.alpha)]);
  return out;
}

function styleAttrs(c: DrawCommand): [string, string][] {
  const out: [string, string][] = c.fill ? paintAttrs("fill", c.fill) : [["fill", "none"]];
  if (c.stroke) {
    out.push(...paintAttrs("stroke", c.stroke), ["stroke-width", fmt(c.lineWidth)],
      ["stroke-linecap", "round"], ["stroke-linejoin", "round"]);
  }
  return out;
}

export function elementSpec(c: DrawCommand): SVGElementSpec {
  const p = c.primitive;
  switch (p.kind) {
    case "rect":
      return { tag: "rect", attrs: [["x", fmt(p.x)], ["y", fmt(p.y)], ["width", fmt(p.width)], ["height", fmt(p.height)], ...styleAttrs(c)] };
    case "line":
      return { tag: "line", attrs: [["x1", fmt(p.from.x)], ["y1", fmt(p.from.y)], ["x2", fmt(p.to.x)], ["y2", fmt(p.to.y)], ...styleAttrs(c)] };
    case "circle":
      return { tag: "circle", attrs: [["cx", fmt(p.center.x)], ["cy", fmt(p.center.y)], ["r", fmt(p.radius)], ...styleAttrs(c)] };
    case "path": {
      const first = p.subpaths[0];
      if (p.subpaths.length === 1 && first && !first.closed && !c.fill) {
        return { tag: "polyline", attrs: [["points", first.points.map((q) => `${fmt(q.x)},${fmt(q.y)}`).join(" ")], ...styleAttrs(c)] };
      }
      let d = "";
      for (const sp of p.subpaths) {
        sp.points.forEach((q, i) => { d += `${i === 0 ? "M" : "L"}${fmt(q.x)} ${fmt(q.y)}`; });
        if (sp.points.length > 0 && sp.closed) d += "Z";
      }
      return { tag: "path", attrs: [["d", d], ...styleAttrs(c)] };
    }
  }
}

/** XML text escaping as SVGWriter.escape: drops characters XML 1.0 forbids. */
export function escapeXML(s: string): string {
  let o = "";
  for (const ch of s) {
    const v = ch.codePointAt(0) ?? 0;
    if (ch === "&") o += "&amp;";
    else if (ch === "<") o += "&lt;";
    else if (ch === ">") o += "&gt;";
    else if (ch === "\"") o += "&quot;";
    else if ((v < 0x20 && ch !== "\t" && ch !== "\n" && ch !== "\r") || v === 0xfffe || v === 0xffff) continue;
    else o += ch;
  }
  return o;
}

export interface PageSVG {
  width: number;
  height: number;
  paper: SVGElementSpec[];
  strokes: SVGElementSpec[];
}

/** The page as SVG element specs (paper group, strokes group). Throws `RenderError`. */
export function pageSVG(page: Page, meta: NoteMeta, options: RenderOptions = defaultRenderOptions): PageSVG {
  const prepared = new PreparedPage(page, meta, options);
  return {
    width: meta.pageSize.width, height: prepared.extent,
    paper: prepared.fullPagePaper().map(elementSpec),
    // Without items, the strokes behind them simply come first (§8.2.3).
    strokes: [...prepared.strokeCommands(true), ...prepared.strokeCommands(false)].map(elementSpec),
  };
}

function elementText(e: SVGElementSpec): string {
  return `<${e.tag} ${e.attrs.map(([k, v]) => `${k}="${v}"`).join(" ")}/>`;
}

/** The standalone SVG document `sempere export --format svg` writes for one page. */
export function renderSVG(page: Page, meta: NoteMeta, options: RenderOptions = defaultRenderOptions): string {
  const p = pageSVG(page, meta, options);
  let s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
  s += `<svg xmlns="http://www.w3.org/2000/svg" width="${fmt(p.width)}pt" height="${fmt(p.height)}pt" `;
  s += `viewBox="0 0 ${fmt(p.width)} ${fmt(p.height)}">\n`;
  if (meta.title.length > 0) s += `<title>${escapeXML(meta.title)}</title>\n`;
  s += "<g id=\"paper\">\n";
  for (const e of p.paper) s += elementText(e) + "\n";
  s += "</g>\n<g id=\"strokes\">\n";
  for (const e of p.strokes) s += elementText(e) + "\n";
  s += "</g>\n</svg>\n";
  return s;
}
