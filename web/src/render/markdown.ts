// Markdown text boxes laid out and drawn (format.md §8.5.4 "Lines",
// "Drawing"), as Sources/SempereRender/Text/MarkdownLayout.swift and
// MarkdownItems.swift do: rendered paragraphs cut into lines (the writer's
// `layout` when usable, else greedily with `measure`), stacked with the
// format's metrics, and turned into ordinary items the viewer already draws
// (text items with fixed lines, `math` items for formula boxes) plus shapes.

import type { JSONObject } from "../format/json.ts";
import {
  type BoxStyle, type Marker, MarkdownPlan, type PlanAtom, type PlanParagraph, type PlanRun, type TypesetFormula, isWhite, markdownHash,
  metrics, round3, typesetFormulas,
} from "../format/markdown.ts";
import type { Point } from "./primitives.ts";
import { type DrawCommand, paint } from "./primitives.ts";
import { type Measure, type RunStyle, approximateMeasure, graphemeBoundaries, isWide, paragraphIsRTL } from "./text.ts";
import { type PreparedItem, type Rect, apply, prepareItem, rotate } from "./items.ts";

export interface TextPiece { text: JSONObject; frame: Rect }
export interface BoxPiece { math: JSONObject; frame: Rect }
export interface LayoutLine { paragraph: number; start?: number; text: string; baseline: number }

export interface MarkdownLayout {
  lines: LayoutLine[];
  texts: TextPiece[];
  boxes: BoxPiece[];
  shapes: DrawCommand[];
  breaks: number[];
  height: number;
  usedStoredBreaks: boolean;
}

/** The box style of a text value, unknown values mapped as renderers must. */
export function boxStyle(t: JSONObject): BoxStyle {
  const out: BoxStyle = {
    font: t.font === "serif" || t.font === "mono" ? t.font : "sans",
    size: typeof t.size === "number" ? t.size : 12,
    color: typeof t.color === "string" ? t.color : "#000000FF",
    align: ["start", "center", "end", "left", "right"].includes(String(t.align)) ? String(t.align) : "start",
    dir: t.dir === "ltr" || t.dir === "rtl" ? t.dir : "auto",
  };
  if (typeof t.lang === "string") out.lang = t.lang;
  return out;
}

function sourceOf(t: JSONObject): string {
  return (Array.isArray(t.runs) ? t.runs as JSONObject[] : []).map((r) => typeof r.t === "string" ? r.t : "").join("");
}

const scalar = (a: PlanAtom): number | undefined => a.kind.k === "char" ? a.kind.c : undefined;

function groups(p: PlanParagraph): number[][] {
  const out: number[][] = [[]];
  p.atoms.forEach((a, i) => {
    if (a.kind.k === "break") out.push([]);
    else (out[out.length - 1] as number[]).push(i);
  });
  return out;
}

function styleOf(r: PlanRun, box: BoxStyle): RunStyle {
  const s: RunStyle = { size: r.size ?? box.size, color: r.color ?? box.color, bold: r.b, italic: r.i, underline: r.u, strike: r.s };
  if (box.lang !== undefined) s.lang = box.lang;
  return s;
}

/** The runs of the characters in `[a, b)` (boxes and breaks left out). */
function runsOf(atoms: PlanAtom[], a: number, b: number): { t: string; run: PlanRun }[] {
  const out: { t: string; run: PlanRun }[] = [];
  for (let i = a; i < b; i++) {
    const at = atoms[i] as PlanAtom;
    if (at.kind.k !== "char") continue;
    const last = out[out.length - 1];
    const ch = String.fromCodePoint(at.kind.c);
    if (last && sameRun(last.run, at.run)) last.t += ch;
    else out.push({ t: ch, run: at.run });
  }
  return out;
}

function sameRun(a: PlanRun, b: PlanRun): boolean {
  return a.b === b.b && a.i === b.i && a.u === b.u && a.s === b.s && a.color === b.color && a.size === b.size && a.font === b.font;
}

function widthOf(atoms: PlanAtom[], a: number, b: number, box: BoxStyle, measure: Measure): number {
  let w = 0;
  let s = a;
  const text = (x: number, y: number) => {
    for (const r of runsOf(atoms, x, y)) w += measure(r.t.replace(/\t/g, "    "), styleOf(r.run, box), r.run.font ?? box.font);
  };
  for (let i = a; i < b; i++) {
    const at = atoms[i] as PlanAtom;
    if (at.kind.k === "box") {
      if (i > s) text(s, i);
      w += at.kind.f.w;
      s = i + 1;
    }
  }
  if (b > s) text(s, b);
  return w;
}

/** The stored breaks as a set, when the `layout` is usable for the whole box. */
function storedBreaks(text: JSONObject, plan: MarkdownPlan): Set<number> | undefined {
  const layout = text.layout as JSONObject | undefined;
  if (!layout || layout.of !== markdownHash(sourceOf(text)) || !Array.isArray(layout.breaks)) return undefined;
  const list = layout.breaks.filter((b): b is number => typeof b === "number");
  const all = new Set(list);
  if (all.size !== list.length) return undefined;
  if (all.size === 0) return all;
  const wanted = new Set(all);
  for (const p of plan.paragraphs) {
    for (const g of groups(p)) {
      if (g.length < 2) continue;
      const clusters = graphemeBoundaries(g.map((i) => scalar(p.atoms[i] as PlanAtom) ?? 0xfffc));
      for (let k = 1; k < g.length; k++) {
        const o = (p.atoms[g[k] as number] as PlanAtom).offset;
        if (!wanted.has(o)) continue;
        if (!clusters.has(k)) return undefined;
        wanted.delete(o);
      }
    }
  }
  return wanted.size === 0 ? all : undefined;
}

interface LineRange { a: number; b: number; soft: boolean }

function greedy(p: PlanParagraph, a: number, b: number, width: number, box: BoxStyle, measure: Measure): [number, number][] {
  const atoms = p.atoms;
  const opps: number[] = [];
  for (let i = a + 1; i < b; i++) {
    const x = scalar(atoms[i - 1] as PlanAtom), y = scalar(atoms[i] as PlanAtom);
    if (x === undefined || y === undefined) { opps.push(i); continue; }
    const space = isWhite(x) && x !== 0xa0 && x !== 0x2007 && x !== 0x202f && !isWhite(y);
    if (space || x === 0x2d || (isWide(x) && isWide(y))) opps.push(i);
  }
  opps.push(b);
  const segs: { a: number; b: number; full: number; trimmed: number }[] = [];
  let s = a;
  for (const o of opps) {
    let e = o;
    while (e > s) {
      const c = scalar(atoms[e - 1] as PlanAtom);
      if (c !== undefined && isWhite(c)) e--;
      else break;
    }
    const full = widthOf(atoms, s, o, box, measure);
    segs.push({ a: s, b: o, full, trimmed: e === o ? full : widthOf(atoms, s, e, box, measure) });
    s = o;
  }
  const out: [number, number][] = [];
  let lineStart = a, used = 0, k = 0;
  while (k < segs.length) {
    const seg = segs[k] as { a: number; b: number; full: number; trimmed: number };
    if (used + seg.trimmed <= width + 1e-9) {
      used += seg.full;
      k++;
      continue;
    }
    if (seg.a > lineStart) {
      out.push([lineStart, seg.a]);
      lineStart = seg.a;
      used = 0;
      continue;
    }
    const pieces = cut(atoms, seg.a, seg.b, width, box, measure);
    for (const r of pieces.slice(0, -1)) out.push(r);
    const rest = pieces[pieces.length - 1] ?? [seg.a, seg.b];
    lineStart = rest[0];
    used = widthOf(atoms, rest[0], rest[1], box, measure);
    k++;
  }
  out.push([lineStart, b]);
  return out;
}

function cut(atoms: PlanAtom[], a: number, b: number, width: number, box: BoxStyle, measure: Measure): [number, number][] {
  const scalars: number[] = [];
  for (let i = a; i < b; i++) scalars.push(scalar(atoms[i] as PlanAtom) ?? 0xfffc);
  const bounds = [...graphemeBoundaries(scalars)].sort((x, y) => x - y).map((x) => a + x).filter((x) => x > a);
  const out: [number, number][] = [];
  let start = a, used = 0, previous = a;
  for (const x of bounds) {
    const w = widthOf(atoms, previous, x, box, measure);
    if (used + w > width + 1e-9 && previous > start) {
      out.push([start, previous]);
      start = previous;
      used = 0;
    }
    used += w;
    previous = x;
  }
  out.push([start, b]);
  return out;
}

function lines(p: PlanParagraph, stored: Set<number> | undefined, width: number, box: BoxStyle, measure: Measure): LineRange[] {
  const out: LineRange[] = [];
  for (const g of groups(p)) {
    const first = g[0], last = g[g.length - 1];
    if (first === undefined || last === undefined) {
      const prev = out[out.length - 1];
      const at = prev ? prev.b + 1 : 0;
      out.push({ a: at, b: at, soft: false });
      continue;
    }
    if (stored) {
      let s = first;
      for (const i of g.slice(1)) {
        if (stored.has((p.atoms[i] as PlanAtom).offset)) {
          out.push({ a: s, b: i, soft: s !== first });
          s = i;
        }
      }
      out.push({ a: s, b: last + 1, soft: s !== first });
    } else {
      greedy(p, first, last + 1, width, box, measure).forEach(([a, b], k) => out.push({ a, b, soft: k > 0 }));
    }
  }
  return out;
}

function lineSize(p: PlanParagraph, a: number, b: number): number {
  let size = 0;
  for (let i = a; i < b && i < p.atoms.length; i++) {
    const at = p.atoms[i] as PlanAtom;
    if (at.kind.k === "break") continue;
    size = Math.max(size, at.run.size ?? p.size);
  }
  return size > 0 ? size : p.size;
}

function lineRecord(p: PlanParagraph, index: number, a: number, b: number, baseline: number): LayoutLine {
  const cs: number[] = [];
  for (let i = a; i < b && i < p.atoms.length; i++) {
    const at = p.atoms[i] as PlanAtom;
    if (at.kind.k === "char") cs.push(at.kind.c);
    else if (at.kind.k === "box") cs.push(0xfffc);
  }
  while (cs.length > 0 && isWhite(cs[cs.length - 1] as number)) cs.pop();
  const out: LayoutLine = { paragraph: index, text: String.fromCodePoint(...cs), baseline: round3(baseline) };
  if (b > a && a < p.atoms.length) out.start = (p.atoms[a] as PlanAtom).offset;
  return out;
}

function runJSON(r: PlanRun, t: string, size: number | undefined): JSONObject {
  const o: JSONObject = { t };
  if (r.b) o.b = true;
  if (r.i) o.i = true;
  if (r.u) o.u = true;
  if (r.s) o.s = true;
  if (r.color !== undefined) o.color = r.color;
  if (size !== undefined) o.size = size;
  if (r.font !== undefined) o.font = r.font;
  return o;
}

function rect(x: number, y: number, w: number, h: number, fill: string, opacity: number): DrawCommand {
  return {
    primitive: { kind: "path", subpaths: [{ points: [{ x, y }, { x: x + w, y }, { x: x + w, y: y + h }, { x, y: y + h }], closed: true }] },
    fill: paint(fill, opacity), lineWidth: 1,
  };
}

/** Lays out a Markdown text value in `frame` (Swift `MarkdownLayout`). */
export function layoutMarkdown(text: JSONObject, frame: Rect, measure: Measure = approximateMeasure): MarkdownLayout {
  const box = boxStyle(text);
  const plan = new MarkdownPlan(sourceOf(text), box, typesetFormulas(text));
  const s = box.size;
  const stored = storedBreaks(text, plan);
  const out: MarkdownLayout = { lines: [], texts: [], boxes: [], shapes: [], breaks: [], height: 0, usedStoredBreaks: stored !== undefined };
  const fills: DrawCommand[] = [];
  const tops: number[] = [], bottoms: number[] = [];
  let y = frame.y;
  plan.paragraphs.forEach((p, pi) => {
    y += p.gapBefore;
    const top = y;
    y += p.pad;
    const x0 = frame.x + p.indent;
    const width = Math.max(frame.w - p.indent, 1);
    if (p.kind === "rule") {
      const thick = s / 12;
      out.shapes.push(rect(x0, y + 0.6 * s - thick / 2, width, thick, box.color, 0.4));
      y += 1.2 * s;
    } else {
      const ls = lines(p, stored, width, box, measure);
      for (const l of ls) if (l.soft) out.breaks.push((p.atoms[l.a] as PlanAtom).offset);
      const hasBox = p.atoms.some((a) => a.kind.k === "box");
      let firstBaseline: number | undefined;
      let firstSize = p.size;
      if (!hasBox) {
        let lineTop = y;
        for (const l of ls) {
          const size = lineSize(p, l.a, l.b);
          if (firstBaseline === undefined) { firstBaseline = lineTop + 0.95 * size; firstSize = size; }
          out.lines.push(lineRecord(p, pi, l.a, l.b, lineTop + 0.95 * size));
          lineTop += 1.2 * size;
        }
        out.texts.push({ text: paragraphText(p, ls, box), frame: { x: x0, y, w: width, h: Math.max(lineTop - y, 1) } });
        y = lineTop;
      } else {
        for (const l of ls) {
          const size = lineSize(p, l.a, l.b);
          let ascent = 0.95 * size, descent = 0.25 * size;
          for (let i = l.a; i < l.b; i++) {
            const at = p.atoms[i] as PlanAtom;
            if (at.kind.k === "box") {
              ascent = Math.max(ascent, at.kind.f.h - at.kind.f.depth);
              descent = Math.max(descent, at.kind.f.depth);
            }
          }
          const baseline = y + ascent;
          if (firstBaseline === undefined) { firstBaseline = baseline; firstSize = size; }
          out.lines.push(lineRecord(p, pi, l.a, l.b, baseline));
          place(out, p, l.a, l.b, baseline, x0, width, box, measure, size);
          y = baseline + descent;
        }
      }
      if (p.marker && firstBaseline !== undefined) marker(out, p.marker, firstBaseline, firstSize, x0, box);
    }
    y += p.pad;
    if (p.kind === "code") fills.push(rect(frame.x + p.column, top, Math.max(frame.w - p.column, 0), y - top, box.color, 0.08));
    tops.push(top);
    bottoms.push(y);
  });
  for (const bar of plan.bars) {
    const t = tops[bar.first], b = bottoms[bar.last];
    if (t === undefined || b === undefined) continue;
    out.shapes.push(rect(frame.x + bar.x, t, metrics.quoteBarWidth * s, b - t, box.color, 0.4));
  }
  out.shapes = [...fills, ...out.shapes];
  out.height = y - frame.y;
  return out;
}

function paragraphText(p: PlanParagraph, ls: LineRange[], box: BoxStyle): JSONObject {
  const runs: { t: string; run: PlanRun; size: number | undefined }[] = [];
  const starts: number[] = [];
  const soft = new Set(ls.filter((l) => l.soft).map((l) => l.a));
  let position = 0;
  p.atoms.forEach((a, i) => {
    if (soft.has(i)) starts.push(position);
    let ch: string;
    if (a.kind.k === "char") ch = String.fromCodePoint(a.kind.c);
    else if (a.kind.k === "break") ch = "\n";
    else return;
    let size: number | undefined = a.run.size ?? box.size;
    if (size === p.size) size = undefined;
    const last = runs[runs.length - 1];
    if (last && sameRun(last.run, a.run) && last.size === size) last.t += ch;
    else runs.push({ t: ch, run: a.run, size });
    position++;
  });
  const out: JSONObject = { font: box.font, size: p.size, color: box.color, align: p.align, dir: box.dir,
    runs: runs.map((r) => runJSON(r.run, r.t, r.size)), breaks: starts };
  if (box.lang !== undefined) out.lang = box.lang;
  return out;
}

function place(out: MarkdownLayout, p: PlanParagraph, a: number, b: number, baseline: number, x0: number, width: number,
  box: BoxStyle, measure: Measure, size: number): void {
  let end = b;
  while (end > a) {
    const c = scalar(p.atoms[end - 1] as PlanAtom);
    if (c !== undefined && isWhite(c)) end--;
    else break;
  }
  const pieces: ({ k: "text"; a: number; b: number; w: number } | { k: "box"; f: TypesetFormula; w: number })[] = [];
  let s = a;
  for (let i = a; i < end; i++) {
    const at = p.atoms[i] as PlanAtom;
    if (at.kind.k === "box") {
      if (i > s) pieces.push({ k: "text", a: s, b: i, w: widthOf(p.atoms, s, i, box, measure) });
      pieces.push({ k: "box", f: at.kind.f, w: at.kind.f.w });
      s = i + 1;
    }
  }
  if (end > s) pieces.push({ k: "text", a: s, b: end, w: widthOf(p.atoms, s, end, box, measure) });
  const total = pieces.reduce((m, x) => m + x.w, 0);
  const scalars = p.atoms.map(scalar).filter((c): c is number => c !== undefined);
  const rtl = box.dir === "rtl" || (box.dir === "auto" && paragraphIsRTL(scalars));
  let x: number;
  switch (p.kind === "displayMath" ? "center" : p.align) {
    case "left": x = x0; break;
    case "right": x = x0 + width - total; break;
    case "center": x = x0 + (width - total) / 2; break;
    case "end": x = rtl ? x0 : x0 + width - total; break;
    default: x = rtl ? x0 + width - total : x0;
  }
  if (p.kind === "displayMath" && total > width) x = x0;
  for (const piece of rtl ? [...pieces].reverse() : pieces) {
    if (piece.k === "box") {
      out.boxes.push({ math: piece.f.math, frame: { x, y: baseline - (piece.f.h - piece.f.depth), w: Math.max(piece.w, 0.001),
        h: Math.max(piece.f.h, 0.001) } });
    } else {
      const runs = runsOf(p.atoms, piece.a, piece.b);
      const pieceSize = Math.max(...runs.map((r) => r.run.size ?? box.size), 0) || size;
      const t: JSONObject = { font: box.font, size: pieceSize, color: box.color, align: "left", dir: box.dir,
        runs: runs.map((r) => {
          const sz = r.run.size ?? box.size;
          return runJSON(r.run, r.t, sz === pieceSize ? undefined : sz);
        }), breaks: [] };
      if (box.lang !== undefined) t.lang = box.lang;
      out.texts.push({ text: t, frame: { x, y: baseline - 0.95 * pieceSize, w: Math.max(piece.w, 0.001) + pieceSize, h: 1.2 * pieceSize } });
    }
    x += piece.w;
  }
}

function marker(out: MarkdownLayout, m: Marker, b: number, S: number, x0: number, box: BoxStyle): void {
  const s = box.size;
  const p = paint(box.color);
  if (m.k === "bullet") {
    const r = 0.18 * S;
    const c = { x: x0 - 0.8 * s, y: b - 0.32 * S };
    const points: Point[] = [];
    for (let k = 0; k < 24; k++) {
      const t = k / 24 * 2 * Math.PI;
      points.push({ x: c.x + r * Math.cos(t), y: c.y + r * Math.sin(t) });
    }
    if (m.ring) {
      const w = S / 16;
      const inner = points.map((q) => ({ x: c.x + (q.x - c.x) * (r - w / 2) / r, y: c.y + (q.y - c.y) * (r - w / 2) / r }));
      out.shapes.push({ primitive: { kind: "path", subpaths: [{ points: inner, closed: true }] }, stroke: p, lineWidth: w });
    } else {
      out.shapes.push({ primitive: { kind: "path", subpaths: [{ points, closed: true }] }, fill: p, lineWidth: 1 });
    }
  } else if (m.k === "task") {
    const a = 0.66 * S;
    const left = x0 - 0.35 * s - a, top = b - a;
    const w = S / 14;
    const sq = [{ x: left + w / 2, y: top + w / 2 }, { x: left + a - w / 2, y: top + w / 2 }, { x: left + a - w / 2, y: top + a - w / 2 },
      { x: left + w / 2, y: top + a - w / 2 }];
    out.shapes.push({ primitive: { kind: "path", subpaths: [{ points: sq, closed: true }] }, stroke: p, lineWidth: w });
    if (m.checked) {
      const tick = ([[0.18, 0.52], [0.42, 0.76], [0.82, 0.24]] as const).map(([u, v]) => ({ x: left + u * a, y: top + v * a }));
      out.shapes.push({ primitive: { kind: "path", subpaths: [{ points: tick, closed: false }] }, stroke: p, lineWidth: S / 9 });
    }
  } else {
    const w = (metrics.listIndent - 0.35) * s;
    const t: JSONObject = { font: box.font, size: s, color: box.color, align: "right", dir: "ltr", runs: [{ t: m.label }], breaks: [] };
    if (box.lang !== undefined) t.lang = box.lang;
    out.texts.push({ text: t, frame: { x: x0 - 0.35 * s - w, y: b - 0.95 * s, w, h: 1.2 * s } });
  }
}

/** Every formula of the box drawn as its source (no typeset rendering stored, §8.5.4). */
export function unrenderedFormulas(text: JSONObject): number {
  const plan = new MarkdownPlan(sourceOf(text), boxStyle(text), typesetFormulas(text));
  const boxes = plan.paragraphs.reduce((n, p) => n + p.atoms.filter((a) => a.kind.k === "box").length, 0);
  return plan.formulas.length - boxes;
}

/**
 * A Markdown text item as the items every renderer draws in its place
 * (Swift `MarkdownItems.pieces`): an empty text item at the box's frame
 * carrying the shapes as its underlay, then the text pieces and the formula
 * boxes (math items), each turned with the box about the box's centre.
 * Undefined for anything else.
 */
export function expandMarkdown(it: PreparedItem, measure: Measure = approximateMeasure): { pieces: PreparedItem[]; unrendered: number } | undefined {
  const text = it.item.text as JSONObject | undefined;
  if (it.kind !== "text" || !text || typeof text !== "object" || text.markup !== "markdown") return undefined;
  const laid = layoutMarkdown(text, it.frame, measure);
  const turn = rotate(it.frame, it.rotation);
  const place = (r: Rect): number[] => {
    const c = apply(turn, { x: r.x + r.w / 2, y: r.y + r.h / 2 });
    return [c.x - r.w / 2, c.y - r.h / 2, r.w, r.h];
  };
  let n = 0;
  const base = (kind: string, frame: number[], extra: JSONObject): JSONObject => {
    n += 1;
    const o: JSONObject = { id: `${String(it.item.id)}/markdown-${n}`, kind, frame, z: it.item.z ?? "", ...extra };
    if (it.item.layer !== undefined) o.layer = it.item.layer;
    if (it.rotation !== 0) o.rotation = it.rotation;
    return o;
  };
  const pieces: PreparedItem[] = [];
  const box = boxStyle(text);
  const carrier = prepareItem(base("text", [it.frame.x, it.frame.y, it.frame.w, it.frame.h],
    { text: { font: "sans", size: box.size, color: box.color, runs: [], breaks: [] } }));
  if (typeof carrier !== "string") {
    carrier.underlay = laid.shapes.map((c) => mapCommand(c, (p) => apply(turn, p)));
    pieces.push(carrier);
  }
  for (const t of laid.texts) {
    const p = prepareItem(base("text", place(t.frame), { text: t.text }));
    if (typeof p !== "string") pieces.push(p);
  }
  for (const b of laid.boxes) {
    const p = prepareItem(base("math", place(b.frame), { math: b.math }));
    if (typeof p !== "string") pieces.push(p);
  }
  return { pieces, unrendered: unrenderedFormulas(text) };
}

function mapCommand(c: DrawCommand, f: (p: Point) => Point): DrawCommand {
  const p = c.primitive;
  switch (p.kind) {
    case "path": return { ...c, primitive: { kind: "path", subpaths: p.subpaths.map((s) => ({ points: s.points.map(f), closed: s.closed })) } };
    case "line": return { ...c, primitive: { kind: "line", from: f(p.from), to: f(p.to) } };
    case "rect": return { ...c, primitive: { kind: "path", subpaths: [{ points: [{ x: p.x, y: p.y }, { x: p.x + p.width, y: p.y },
      { x: p.x + p.width, y: p.y + p.height }, { x: p.x, y: p.y + p.height }].map(f), closed: true }] } };
    case "circle": return c;
  }
}
