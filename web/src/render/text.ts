// Text items (format.md §8.2.4, §8.5.3): lines and their vertical metrics,
// as Sources/SempereRender/Text/TextLayout.swift computes them. The stored
// `breaks` decide the lines whenever they are valid, so the viewer's lines
// are the app's and the CLI's whatever fonts the browser has; only when they
// are absent or invalid does the viewer break greedily with its own widths.
// Glyphs are left to the browser (system fonts, shaping, bidi reordering
// within a line); vertical positions are fixed by the format.

import type { JSONObject } from "../format/json.ts";
import type { Rect } from "./items.ts";

export interface RunStyle {
  size: number;
  color: string;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  strike: boolean;
  lang?: string;
  /** A run's own generic family (§8.2.4), overriding the box's. */
  font?: "sans" | "serif" | "mono";
}

export interface TextContent {
  font: "sans" | "serif" | "mono";
  size: number;
  color: string;
  align: "start" | "center" | "end" | "left" | "right";
  dir: "auto" | "ltr" | "rtl";
  lang?: string;
  runs: { t: string; style: RunStyle }[];
  breaks?: number[];
}

function bool(v: unknown): boolean {
  return v === true;
}

/** The text of a validated item (§8.2.4), unknown values mapped as renderers must. */
export function textContent(item: JSONObject): TextContent | undefined {
  const t = item.text as JSONObject | undefined;
  if (!t || typeof t !== "object") return undefined;
  const size = typeof t.size === "number" ? t.size : 12;
  const color = typeof t.color === "string" ? t.color : "#000000FF";
  const font = t.font === "serif" || t.font === "mono" ? t.font : "sans";
  const align = ["start", "center", "end", "left", "right"].includes(String(t.align)) ? t.align as TextContent["align"] : "start";
  const dir = t.dir === "ltr" || t.dir === "rtl" ? t.dir : "auto";
  const runs = (Array.isArray(t.runs) ? t.runs as JSONObject[] : []).map((r) => {
    const style: RunStyle = {
      size: typeof r.size === "number" ? r.size : size, color: typeof r.color === "string" ? r.color : color,
      bold: bool(r.b), italic: bool(r.i), underline: bool(r.u), strike: bool(r.s),
    };
    const lang = typeof r.lang === "string" ? r.lang : typeof t.lang === "string" ? t.lang : undefined;
    if (lang !== undefined) style.lang = lang;
    if (r.font === "sans" || r.font === "serif" || r.font === "mono") style.font = r.font;
    return { t: typeof r.t === "string" ? r.t : "", style };
  });
  const out: TextContent = { font, size, color, align, dir, runs };
  if (typeof t.lang === "string") out.lang = t.lang;
  if (Array.isArray(t.breaks)) out.breaks = t.breaks.filter((b): b is number => typeof b === "number");
  return out;
}

/** CSS font stacks for the generic families: system fonts first, then common ones. */
export const fontStacks: Record<TextContent["font"], string> = {
  sans: "system-ui, -apple-system, \"Segoe UI\", Roboto, \"Noto Sans\", \"Helvetica Neue\", Arial, sans-serif",
  serif: "\"Iowan Old Style\", \"Noto Serif\", Georgia, Cambria, \"Times New Roman\", serif",
  mono: "ui-monospace, \"SF Mono\", Menlo, Consolas, \"Noto Sans Mono\", \"Liberation Mono\", monospace",
};

/** Width in points of `text` drawn at `style` in `font` (the browser's canvas, or a test stand-in). */
export type Measure = (text: string, style: RunStyle, font: TextContent["font"]) => number;

/** A stand-in measure: half an em per character, a full em for wide (CJK) ones. */
export const approximateMeasure: Measure = (text, style) => {
  let w = 0;
  for (const ch of text) w += (isWide(ch.codePointAt(0) ?? 0) ? 1 : 0.5) * style.size;
  return w;
};

/** Unicode `White_Space`. */
export function isWhiteSpace(c: number): boolean {
  return (c >= 0x09 && c <= 0x0d) || c === 0x20 || c === 0x85 || c === 0xa0 || c === 0x1680 || (c >= 0x2000 && c <= 0x200a)
    || c === 0x2028 || c === 0x2029 || c === 0x202f || c === 0x205f || c === 0x3000;
}

const wide = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;

/** East Asian Width `W` or `F`, approximately (CJK ideographs, kana, Hangul, full-width forms). */
export function isWide(c: number): boolean {
  return (c >= 0x3000 && c <= 0x303f) || (c >= 0xff01 && c <= 0xff60) || (c >= 0xffe0 && c <= 0xffe6)
    || wide.test(String.fromCodePoint(c));
}

function isRTLLetter(c: number): boolean {
  return (c >= 0x0590 && c <= 0x08ff) || (c >= 0xfb1d && c <= 0xfdff) || (c >= 0xfe70 && c <= 0xfeff)
    || (c >= 0x10800 && c <= 0x10fff) || (c >= 0x1e800 && c <= 0x1efff);
}

const letter = /\p{L}/u;

/**
 * A paragraph's direction under `dir: auto` (UAX #9 P2–P3): that of its first
 * strong character, left to right without one. Strong characters are taken
 * to be letters; those of the right-to-left blocks are right to left.
 */
export function paragraphIsRTL(scalars: number[]): boolean {
  for (const c of scalars) {
    if (letter.test(String.fromCodePoint(c))) return isRTLLetter(c);
  }
  return false;
}

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/** The scalar offsets that start a grapheme cluster, the end included. */
export function graphemeBoundaries(scalars: number[]): Set<number> {
  const text = String.fromCodePoint(...scalars);
  const out = new Set<number>([0, scalars.length]);
  // UTF-16 index → scalar index.
  const toScalar = new Map<number, number>();
  let u = 0;
  scalars.forEach((c, i) => {
    toScalar.set(u, i);
    u += c > 0xffff ? 2 : 1;
  });
  for (const s of graphemes.segment(text)) out.add(toScalar.get(s.index) ?? scalars.length);
  return out;
}

/** The stored breaks if valid (Swift `TextContent.validBreaks` and the grapheme check), else undefined. */
export function validBreaks(content: TextContent, scalars: number[]): number[] | undefined {
  const b = content.breaks;
  if (!b) return undefined;
  let last = 0;
  for (const x of b) {
    if (!(Number.isInteger(x) && x > last && x < scalars.length && scalars[x - 1] !== 0x0a && scalars[x] !== 0x0a)) return undefined;
    last = x;
  }
  const clusters = graphemeBoundaries(scalars);
  return b.every((x) => clusters.has(x)) ? b : undefined;
}

/** A stretch of one run on a line, in logical order. */
export interface LinePiece {
  text: string;
  style: RunStyle;
}

export interface TextLine {
  /** Scalar offsets of the line in the item's text; `drawnEnd` drops trailing white space. */
  start: number;
  end: number;
  drawnEnd: number;
  /** The drawn characters in logical order (as Swift's `ShapedLine.text`). */
  text: string;
  /** Line size `S`: the largest run size on the line. */
  size: number;
  top: number;
  baseline: number;
  rtl: boolean;
  pieces: LinePiece[];
}

export interface TextLayout {
  lines: TextLine[];
  /** Lines were cut at the stored `breaks`. */
  storedBreaks: boolean;
  bottom: number;
}

/**
 * Break opportunities of a paragraph (offsets relative to it, the end
 * included as mandatory): the minimum §8.5.3 asks of a renderer without
 * UAX #14 — after white space other than no-break spaces, after `-`, and
 * between two wide (CJK) characters.
 */
export function breakOpportunities(p: number[]): { index: number; mandatory: boolean }[] {
  const out: { index: number; mandatory: boolean }[] = [];
  for (let i = 1; i < p.length; i++) {
    const a = p[i - 1] ?? 0, b = p[i] ?? 0;
    const space = isWhiteSpace(a) && a !== 0xa0 && a !== 0x2007 && a !== 0x202f && !isWhiteSpace(b);
    if (space || a === 0x2d || (isWide(a) && isWide(b))) out.push({ index: i, mandatory: false });
  }
  out.push({ index: p.length, mandatory: true });
  return out;
}

/**
 * Lays out `content` in `frame` (§8.5.3). `measure` is used only when the
 * stored breaks are absent or invalid.
 */
export function layoutText(content: TextContent, frame: Rect, measure: Measure = approximateMeasure): TextLayout {
  const chars: { c: number; run: number }[] = [];
  content.runs.forEach((r, i) => {
    for (const ch of r.t) chars.push({ c: ch.codePointAt(0) ?? 0, run: i });
  });
  const scalars = chars.map((x) => x.c);
  const breaks = validBreaks(content, scalars);
  const sizes = content.runs.map((r) => r.style.size);
  const lines: TextLine[] = [];
  let y = frame.y;
  // Per-character advances for the greedy fallback, cached per style and character.
  const cache = new Map<string, number>();
  const advance = (i: number): number => {
    const ch = chars[i] as { c: number; run: number };
    const run = content.runs[ch.run] as { style: RunStyle };
    const s = ch.c === 0x09 ? "    " : String.fromCodePoint(ch.c);
    const st = run.style;
    const key = `${st.size}|${st.bold}|${st.italic}|${st.font ?? ""}|${s}`;
    let w = cache.get(key);
    if (w === undefined) {
      w = measure(s, st, st.font ?? content.font);
      cache.set(key, w);
    }
    return w;
  };
  // Shared by every paragraph (each fills only its own range), so the work is
  // linear in the text, never paragraphs × text length (format.md §9).
  const lastInk: number[] = new Array<number>(chars.length + 1).fill(0);
  const prefix: number[] = new Array<number>(chars.length + 1).fill(0);
  let nextBreak = 0;
  let start = 0;
  while (start <= chars.length) {
    let end = start;
    while (end < chars.length && chars[end]?.c !== 0x0a) end++;
    if (end === start) {
      // An empty line: the box size, or the size of the run holding its line feed.
      y += 1.2 * (start < chars.length ? sizes[chars[start]?.run ?? 0] ?? content.size : content.size);
    } else {
      y = layoutParagraph(start, end);
    }
    start = end + 1;
  }
  return { lines, storedBreaks: breaks !== undefined, bottom: y };

  function layoutParagraph(ps: number, pe: number): number {
    const para = scalars.slice(ps, pe);
    const rtl = content.dir === "rtl" || (content.dir === "auto" && paragraphIsRTL(para));
    lastInk[ps] = ps;
    for (let i = ps; i < pe; i++) lastInk[i + 1] = isWhiteSpace(scalars[i] ?? 0) ? lastInk[i] ?? ps : i + 1;
    const ranges: [number, number][] = [];
    if (breaks) {
      let s = ps;
      // `breaks` is strictly increasing: one cursor serves every paragraph.
      while (nextBreak < breaks.length && (breaks[nextBreak] ?? 0) <= ps) nextBreak++;
      while (nextBreak < breaks.length && (breaks[nextBreak] ?? 0) < pe) {
        const b = breaks[nextBreak] ?? pe;
        ranges.push([s, b]);
        s = b;
        nextBreak++;
      }
      ranges.push([s, pe]);
    } else {
      prefix[ps] = 0;
      for (let i = ps; i < pe; i++) prefix[i + 1] = (prefix[i] ?? 0) + advance(i);
      const width = (s: number, e: number) => (prefix[Math.max(lastInk[e] ?? s, s)] ?? 0) - (prefix[s] ?? 0);
      const opps = breakOpportunities(para).map((o) => ({ index: ps + o.index, mandatory: o.mandatory }));
      const clusters = [...graphemeBoundaries(para)].map((c) => ps + c).sort((a, b) => a - b);
      let s = ps;
      let lastFit: number | undefined;
      let k = 0;
      while (k < opps.length) {
        const { index: b, mandatory } = opps[k] as { index: number; mandatory: boolean };
        if (width(s, b) <= frame.w + 1e-9) {
          if (mandatory) {
            ranges.push([s, b]);
            s = b;
            lastFit = undefined;
          } else {
            lastFit = b;
          }
          k++;
        } else if (lastFit !== undefined) {
          ranges.push([s, lastFit]);
          s = lastFit;
          lastFit = undefined;
        } else {
          // A word wider than the frame: break it between grapheme clusters.
          let cut = s;
          // The first cluster boundary after `s` (binary search), then forward.
          let lo = 0, hi = clusters.length;
          while (lo < hi) {
            const mid = (lo + hi) >> 1;
            if ((clusters[mid] ?? 0) <= s) lo = mid + 1;
            else hi = mid;
          }
          for (let ci = lo; ci < clusters.length; ci++) {
            const c = clusters[ci] ?? b;
            if (c >= b) break;
            if (width(s, c) <= frame.w + 1e-9 || cut === s) cut = c;
            else break;
          }
          if (cut === s || cut >= b) {
            if (mandatory) {
              ranges.push([s, b]);
              s = b;
            } else {
              lastFit = b;
            }
            k++;
          } else {
            ranges.push([s, cut]);
            s = cut;
          }
        }
      }
      if (s < pe) ranges.push([s, pe]);
    }
    let top = y;
    for (const [s, e] of ranges) {
      let size = 0;
      for (let i = s; i < e; i++) size = Math.max(size, sizes[chars[i]?.run ?? 0] ?? 0);
      if (s === e) size = content.size;
      const drawnEnd = Math.max(lastInk[e] ?? s, s);
      const pieces: LinePiece[] = [];
      let text = "";
      for (let i = s; i < drawnEnd; i++) {
        const ch = chars[i] as { c: number; run: number };
        const str = String.fromCodePoint(ch.c);
        text += str;
        const last = pieces[pieces.length - 1];
        const style = (content.runs[ch.run] as { style: RunStyle }).style;
        const shown = ch.c === 0x09 ? "    " : str;
        if (last && last.style === style) last.text += shown;
        else pieces.push({ text: shown, style });
      }
      lines.push({ start: s, end: e, drawnEnd, text, size, top, baseline: top + 0.95 * size, rtl, pieces });
      top += 1.2 * size;
    }
    return top;
  }
}

/** Where a line is anchored: the side of the frame and the SVG `text-anchor` for its direction. */
export function lineAnchor(align: TextContent["align"], rtl: boolean, frame: Rect): { x: number; anchor: "start" | "middle" | "end" } {
  let side: "left" | "right" | "center";
  switch (align) {
    case "center": side = "center"; break;
    case "left": side = "left"; break;
    case "right": side = "right"; break;
    case "end": side = rtl ? "left" : "right"; break;
    default: side = rtl ? "right" : "left";
  }
  if (side === "center") return { x: frame.x + frame.w / 2, anchor: "middle" };
  // For right-to-left text `start` is its right end.
  if (side === "left") return { x: frame.x, anchor: rtl ? "end" : "start" };
  return { x: frame.x + frame.w, anchor: rtl ? "start" : "end" };
}
