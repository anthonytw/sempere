// Paper background and ruling (format.md §5.4.2), a port of
// Sources/SempereRender/PaperRenderer.swift.

import { type PageSize, type Paper, paperKind } from "../format/model.ts";
import { type DrawCommand, RenderLimits, paint } from "./primitives.ts";

function clamp(v: number, lo: number, hi: number, fallback: number): number {
  return Number.isFinite(v) ? Math.min(Math.max(v, lo), hi) : fallback;
}

/** Every parameter but `spacing` clamped to its range (non-finite: the default), as Swift's `rendered()`. */
export function renderedPaper(p: Paper): Paper {
  return {
    ...p,
    lineWidth: clamp(p.lineWidth, 0.1, 4, 0.5),
    dotRadius: clamp(p.dotRadius, 0.3, 4, 0.9),
    marginLeft: clamp(p.marginLeft, 0, 300, 0),
    marginTop: clamp(p.marginTop, 0, 300, 0),
    cueWidth: clamp(p.cueWidth, 40, 400, 150),
    summaryHeight: clamp(p.summaryHeight, 40, 400, 120),
    staffSpacing: clamp(p.staffSpacing, 3, 20, 7),
    staffGap: clamp(p.staffGap, 8, 150, 40),
  };
}

function supportsMargins(p: Paper): boolean {
  const k = paperKind(p);
  return k === "ruled" || k === "marginRuled" || k === "grid" || k === "dot";
}

/** Height of one sheet for sheet-structured paper (Cornell). */
export function sheetHeight(size: PageSize): number {
  const h = size.infinite ? (size.breakHeight ?? size.width * 11 / 8.5) : size.height;
  return Number.isFinite(h) && h > 0 ? Math.min(Math.max(h, 72), RenderLimits.maxExtent) : 792;
}

export interface PaperOptions {
  yOffset?: number;
  yEnd?: number;
  originY?: number;
  includeBackground?: boolean;
  sheetHeight?: number;
}

const rowFactor = 0.8660254037844386;

/** Commands for a `width × height` band whose top is at page y = `yOffset`. */
export function paperCommands(raw: Paper, width: number, height: number, opts: PaperOptions = {}): DrawCommand[] {
  const paper = renderedPaper(raw);
  const yOffset = opts.yOffset ?? 0;
  const origin = opts.originY ?? yOffset;
  const out: DrawCommand[] = [];
  if (opts.includeBackground ?? true) {
    out.push({ primitive: { kind: "rect", x: 0, y: yOffset - origin, width, height }, fill: paint(paper.background), lineWidth: 1 });
  }
  const s = paper.spacing;
  const bottom = opts.yEnd ?? yOffset + height;
  const sheet = opts.sheetHeight ?? Math.max(height, 1);
  const estimate = rulingCount(paper, width, yOffset, bottom, sheet);
  if (estimate === undefined || estimate > RenderLimits.maxPaperCommands) return out;

  const band = Math.max(bottom - yOffset, 0);
  const line = paint(paper.lineColor);
  const w = paper.lineWidth;
  const hline = (y: number, p = line, lw = w, x0 = 0, x1 = width) => {
    out.push({ primitive: { kind: "line", from: { x: x0, y: y - origin }, to: { x: x1, y: y - origin } }, stroke: p, lineWidth: lw });
  };
  const vline = (x: number, y0: number, y1: number, p = line, lw = w) => {
    out.push({ primitive: { kind: "line", from: { x, y: y0 - origin }, to: { x, y: y1 - origin } }, stroke: p, lineWidth: lw });
  };
  const diag = (x0: number, y0: number, x1: number, y1: number) => {
    out.push({ primitive: { kind: "line", from: { x: x0, y: y0 - origin }, to: { x: x1, y: y1 - origin } }, stroke: line, lineWidth: w });
  };
  const dot = (x: number, y: number) => {
    out.push({ primitive: { kind: "circle", center: { x, y: y - origin }, radius: paper.dotRadius }, fill: line, lineWidth: 1 });
  };

  const rowStart = Math.max(Math.ceil(yOffset / s), 1);
  const rowEnd = Math.ceil(bottom / s);
  const colEnd = Math.ceil(width / s);
  const rowCount = Math.max(rowEnd - rowStart, 0), colCount = Math.max(colEnd - 1, 0);

  switch (paperKind(paper)) {
    case "blank":
      break;
    case "ruled":
    case "marginRuled":
      if (rowCount > RenderLimits.maxPaperCommands) return out;
      for (let k = rowStart; k < rowStart + rowCount; k++) hline(k * s);
      break;
    case "grid":
      if (rowCount + colCount > RenderLimits.maxPaperCommands) return out;
      for (let k = rowStart; k < rowStart + rowCount; k++) hline(k * s);
      for (let k = 1; k < colCount + 1; k++) vline(k * s, yOffset, bottom);
      break;
    case "dot":
      if (rowCount * colCount > RenderLimits.maxPaperCommands) return out;
      for (let r = rowStart; r < rowStart + rowCount; r++) {
        for (let k = 1; k < colCount + 1; k++) dot(k * s, r * s);
      }
      break;
    case "isoDot":
    case "isoGrid": {
      const rowH = s * rowFactor;
      const r0 = Math.max(Math.ceil(yOffset / rowH), 1), r1 = Math.ceil(bottom / rowH);
      const rows = Math.max(r1 - r0, 0);
      if (paperKind(paper) === "isoDot") {
        if (rows * (width / s + 1) > RenderLimits.maxPaperCommands) return out;
        for (let r = r0; r < r0 + rows; r++) {
          const shift = r % 2 === 0 ? 0 : s / 2;
          let x = shift === 0 ? s : shift;
          while (x < width) {
            dot(x, r * rowH);
            x += s;
          }
        }
      } else {
        const slope = 1 / Math.sqrt(3);
        const nLo = Math.ceil((0 - bottom * slope) / s), nHi = Math.floor((width - yOffset * slope) / s);
        const nB0 = Math.ceil((yOffset * slope) / s), nB1 = Math.floor((width + bottom * slope) / s);
        if (rows + Math.max(nHi - nLo + 1, 0) + Math.max(nB1 - nB0 + 1, 0) > RenderLimits.maxPaperCommands) return out;
        for (let r = r0; r < r0 + rows; r++) hline(r * rowH);
        for (let n = nLo; n <= nHi; n++) {
          const x0 = n * s;
          const ya = Math.max(yOffset, (0 - x0) / slope), yb = Math.min(bottom, (width - x0) / slope);
          if (yb > ya) diag(x0 + ya * slope, ya, x0 + yb * slope, yb);
        }
        for (let n = nB0; n <= nB1; n++) {
          const x0 = n * s;
          const ya = Math.max(yOffset, (x0 - width) / slope), yb = Math.min(bottom, x0 / slope);
          if (yb > ya) diag(x0 - ya * slope, ya, x0 - yb * slope, yb);
        }
      }
      break;
    }
    case "cornell": {
      if (!Number.isFinite(sheet) || sheet < 1) return out;
      const firstSheet = Math.trunc(Math.max(Math.floor(yOffset / sheet), 0));
      const lastSheet = Math.trunc(Math.max(Math.ceil(bottom / sheet), 1));
      if ((lastSheet - firstSheet) * (sheet / s + 4) > RenderLimits.maxPaperCommands) return out;
      const cue = Math.min(paper.cueWidth, width * 0.6);
      const summary = Math.min(paper.summaryHeight, sheet * 0.5);
      const structural = w * 2;
      for (let j = firstSheet; j < lastSheet; j++) {
        const top = j * sheet, notesBottom = top + sheet - summary;
        let k = 1;
        while (top + k * s < notesBottom) {
          const y = top + k * s;
          if (y >= yOffset && y < bottom) hline(y, line, w, cue, width);
          k += 1;
        }
        const a = Math.max(top, yOffset), b = Math.min(notesBottom, bottom);
        if (b > a) vline(cue, a, b, line, structural);
        if (notesBottom >= yOffset && notesBottom < bottom) hline(notesBottom, line, structural);
      }
      break;
    }
    case "staff": {
      const ss = paper.staffSpacing, gap = paper.staffGap;
      const period = 4 * ss + gap;
      const i0 = Math.trunc(Math.max(Math.floor((yOffset - gap - 4 * ss) / period), 0));
      const i1 = Math.trunc(Math.max(Math.ceil((bottom - gap) / period), 0));
      if (Math.max(i1 - i0, 0) * 5 > RenderLimits.maxPaperCommands) return out;
      for (let i = i0; i < Math.max(i1, i0); i++) {
        const top = gap + i * period;
        for (let l = 0; l < 5; l++) {
          const y = top + l * ss;
          if (y >= yOffset && y < bottom) hline(y);
        }
      }
      break;
    }
  }

  if (supportsMargins(paper) && band > 0) {
    const mc = paint(paper.marginColor);
    if (paper.marginLeft > 0 && paper.marginLeft < width) vline(paper.marginLeft, yOffset, bottom, mc, w);
    if (paper.marginTop > 0 && paper.marginTop >= yOffset && paper.marginTop < bottom) hline(paper.marginTop, mc, w);
  }
  return out;
}

/**
 * How many ruling commands the band `[yOffset, bottom)` needs (an upper
 * bound), or undefined when the paper draws no ruling there.
 */
export function rulingCount(raw: Paper, width: number, yOffset: number, bottom: number, sheet: number): number | undefined {
  const paper = renderedPaper(raw);
  const s = paper.spacing;
  const kind = paperKind(paper);
  const usesSpacing = kind !== "staff";
  if (kind === "blank" || (usesSpacing && !(Number.isFinite(s) && s >= RenderLimits.minPaperSpacing))
    || !Number.isFinite(width) || width <= 0 || !Number.isFinite(bottom) || !Number.isFinite(yOffset)
    || width > RenderLimits.maxExtent || Math.abs(bottom) > RenderLimits.maxExtent * 2
    || Math.abs(yOffset) > RenderLimits.maxExtent * 2) return undefined;
  const rowStart = Math.max(Math.ceil(yOffset / s), 1);
  const rowEnd = Math.ceil(bottom / s);
  const colEnd = Math.ceil(width / s);
  const rowCount = Math.max(rowEnd - rowStart, 0), colCount = Math.max(colEnd - 1, 0);
  let n: number;
  switch (kind) {
    case "ruled": case "marginRuled": n = rowCount; break;
    case "grid": n = rowCount + colCount; break;
    case "dot": n = rowCount * colCount; break;
    case "isoDot": case "isoGrid": {
      const rowH = s * rowFactor;
      const rows = Math.max(Math.ceil(bottom / rowH) - Math.max(Math.ceil(yOffset / rowH), 1), 0);
      if (kind === "isoDot") {
        n = rows * (width / s + 1);
      } else {
        const slope = 1 / Math.sqrt(3);
        const nLo = Math.ceil((0 - bottom * slope) / s), nHi = Math.floor((width - yOffset * slope) / s);
        const nB0 = Math.ceil((yOffset * slope) / s), nB1 = Math.floor((width + bottom * slope) / s);
        n = rows + Math.max(nHi - nLo + 1, 0) + Math.max(nB1 - nB0 + 1, 0);
      }
      break;
    }
    case "cornell": {
      if (!Number.isFinite(sheet) || sheet < 1) return undefined;
      const sheets = Math.max(Math.ceil(bottom / sheet), 1) - Math.max(Math.floor(yOffset / sheet), 0);
      n = Math.max(sheets, 0) * (sheet / s + 4);
      break;
    }
    case "staff": {
      const period = 4 * paper.staffSpacing + paper.staffGap;
      const staves = Math.max(Math.ceil((bottom - paper.staffGap) / period), 0)
        - Math.max(Math.floor((yOffset - paper.staffGap - 4 * paper.staffSpacing) / period), 0);
      n = Math.max(staves, 0) * 5;
      break;
    }
  }
  if (supportsMargins(paper)) n += 2;
  return n;
}
