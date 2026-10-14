// Placed items (format.md §8.2, §8.5): geometry and drawing order, a port of
// Sources/SempereRender/Items.swift (`Affine`, `ItemGeometry`,
// `PreparedItem`). The writers of the page (page.ts, the note view) use it
// to place images, PDF pages, text and placeholders exactly where the Swift
// exports put them.

import type { JSONObject } from "../format/json.ts";
import { type Paper } from "../format/model.ts";
import { itemLayer } from "../format/registers.ts";
import { type DrawCommand, type Point, RenderLimits, fmt, paint } from "./primitives.ts";

/** `[x, y, w, h]`. */
export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export function rectOf(v: unknown): Rect | undefined {
  if (!Array.isArray(v) || v.length !== 4 || !v.every((n) => typeof n === "number")) return undefined;
  const [x, y, w, h] = v as [number, number, number, number];
  return { x, y, w, h };
}

/** An affine map `(x, y) ↦ (a·x + c·y + tx, b·x + d·y + ty)` (PDF `cm` order). */
export interface Affine {
  a: number;
  b: number;
  c: number;
  d: number;
  tx: number;
  ty: number;
}

export const identity: Affine = { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 };

export function apply(m: Affine, p: Point): Point {
  return { x: m.a * p.x + m.c * p.y + m.tx, y: m.b * p.x + m.d * p.y + m.ty };
}

/** `m ∘ n`: first `n`, then `m`. */
export function after(m: Affine, n: Affine): Affine {
  return {
    a: m.a * n.a + m.c * n.b, b: m.b * n.a + m.d * n.b, c: m.a * n.c + m.c * n.d, d: m.b * n.c + m.d * n.d,
    tx: m.a * n.tx + m.c * n.ty + m.tx, ty: m.b * n.tx + m.d * n.ty + m.ty,
  };
}

export function isFiniteAffine(m: Affine): boolean {
  return [m.a, m.b, m.c, m.d, m.tx, m.ty].every(Number.isFinite);
}

export function isInvertible(m: Affine): boolean {
  const det = m.a * m.d - m.b * m.c;
  return Number.isFinite(det) && Math.abs(det) > 1e-300;
}

export function translate(x: number, y: number): Affine {
  return { ...identity, tx: x, ty: y };
}

export function scale(x: number, y: number): Affine {
  return { ...identity, a: x, d: y };
}

/** cos and sin of `degrees`, exact for multiples of 90 (Swift `ItemGeometry.rotation`). */
export function rotation(degrees: number): { cos: number; sin: number } {
  const r = degrees % 360;
  switch ((r + 360) % 360) {
    case 0: return { cos: 1, sin: 0 };
    case 90: return { cos: 0, sin: 1 };
    case 180: return { cos: -1, sin: 0 };
    case 270: return { cos: 0, sin: -1 };
    default: {
      const t = (r * Math.PI) / 180;
      return { cos: Math.cos(t), sin: Math.sin(t) };
    }
  }
}

/** Rotation by `degrees` (clockwise on the y-down page) about the frame's centre. */
export function rotate(f: Rect, degrees: number): Affine {
  const { cos: cs, sin: sn } = rotation(degrees);
  const mx = f.x + f.w / 2, my = f.y + f.h / 2;
  return { a: cs, b: sn, c: -sn, d: cs, tx: mx - mx * cs + my * sn, ty: my - mx * sn - my * cs };
}

/** Source coordinates → page: the crop onto the frame, then the rotation (§8.5.1). */
export function placement(crop: Rect, frame: Rect, degrees: number): Affine {
  const sx = frame.w / crop.w, sy = frame.h / crop.h;
  const toFrame: Affine = { a: sx, b: 0, c: 0, d: sy, tx: frame.x - crop.x * sx, ty: frame.y - crop.y * sy };
  return after(rotate(frame, degrees), toFrame);
}

/** Stored pixel coordinates of a `w × h` image → oriented coordinates (§8.5.1 table). */
export function orientation(o: number, w: number, h: number): Affine {
  switch (o) {
    case 2: return { a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0 };
    case 3: return { a: -1, b: 0, c: 0, d: -1, tx: w, ty: h };
    case 4: return { a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h };
    case 5: return { a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0 };
    case 6: return { a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0 };
    case 7: return { a: 0, b: -1, c: -1, d: 0, tx: h, ty: w };
    case 8: return { a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w };
    default: return identity;
  }
}

export function orientedSize(o: number, w: number, h: number): { w: number; h: number } {
  return o >= 5 && o <= 8 ? { w: h, h: w } : { w, h };
}

/** `a ∩ b`, undefined when empty or `a` has no positive size. */
export function intersect(a: Rect, b: Rect): Rect | undefined {
  if (!(a.w > 0 && a.h > 0)) return undefined;
  const x0 = Math.max(a.x, b.x), y0 = Math.max(a.y, b.y);
  const x1 = Math.min(a.x + a.w, b.x + b.w), y1 = Math.min(a.y + a.h, b.y + b.h);
  if (!(x1 > x0 && y1 > y0)) return undefined;
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

/** The frame's corners after rotation, page coordinates. */
export function corners(f: Rect, degrees: number): Point[] {
  const r = rotate(f, degrees);
  return [{ x: f.x, y: f.y }, { x: f.x + f.w, y: f.y }, { x: f.x + f.w, y: f.y + f.h }, { x: f.x, y: f.y + f.h }]
    .map((p) => apply(r, p));
}

/**
 * PDF user space → effective-page coordinates (y down) for a page's visible
 * box `[x0, y0, x1, y1]` and `/Rotate` (§8.5.1 table).
 */
export function pdfToEffective(v: { x0: number; y0: number; x1: number; y1: number }, rot: number): Affine {
  const bw = v.x1 - v.x0, bh = v.y1 - v.y0;
  switch (rot) {
    case 90: return { a: 0, b: 1, c: 1, d: 0, tx: bh - v.y1, ty: -v.x0 };
    case 180: return { a: -1, b: 0, c: 0, d: 1, tx: bw + v.x0, ty: bh - v.y1 };
    case 270: return { a: 0, b: -1, c: -1, d: 0, tx: v.y1, ty: bw + v.x0 };
    default: return { a: 1, b: 0, c: 0, d: -1, tx: -v.x0, ty: v.y1 };
  }
}

/** The placeholder (§8.5.2): the rotated frame outlined 1 pt in `#9AA0A6` with both diagonals. */
export function placeholderCommands(c: Point[]): DrawCommand[] {
  const grey = { r: 0x9a, g: 0xa0, b: 0xa6, alpha: 1 };
  const [p0, p1, p2, p3] = c as [Point, Point, Point, Point];
  return [
    { primitive: { kind: "path", subpaths: [{ points: c, closed: true }] }, stroke: grey, lineWidth: 1 },
    { primitive: { kind: "line", from: p0, to: p2 }, stroke: grey, lineWidth: 1 },
    { primitive: { kind: "line", from: p1, to: p3 }, stroke: grey, lineWidth: 1 },
  ];
}

/**
 * The play mark over a video item (§8.2.7, Swift `ItemGeometry.playMark`):
 * a disc of diameter `d = min(48, 0.3 · min(w, h))` filled `#00000080` at
 * the frame's centre, and a white triangle pointing right, turned with the item.
 */
export function playMarkCommands(f: Rect, degrees: number): DrawCommand[] {
  const d = Math.min(48, 0.3 * Math.min(f.w, f.h));
  if (!(Number.isFinite(d) && d > 0)) return [];
  const mx = f.x + f.w / 2, my = f.y + f.h / 2;
  const r = rotate(f, degrees);
  const triangle = [{ x: mx - 0.18 * d, y: my - 0.25 * d }, { x: mx - 0.18 * d, y: my + 0.25 * d }, { x: mx + 0.27 * d, y: my }]
    .map((p) => apply(r, p));
  return [
    { primitive: { kind: "circle", center: { x: mx, y: my }, radius: d / 2 }, fill: { r: 0, g: 0, b: 0, alpha: 128 / 255 }, lineWidth: 1 },
    { primitive: { kind: "path", subpaths: [{ points: triangle, closed: true }] }, fill: { r: 255, g: 255, b: 255, alpha: 1 }, lineWidth: 1 },
  ];
}

/** A matrix coefficient as Swift's `coef`: `fmt`, with 6 decimals below 1. */
export function coef(v: number): string {
  if (!Number.isFinite(v)) return "0";
  if (Math.abs(v) >= 1 || v === 0) return fmt(v);
  let s = v.toFixed(6).replace(/0+$/, "").replace(/\.$/, "");
  if (s === "-0" || s === "") s = "0";
  return s;
}

/** `matrix(a b c d tx ty)` for SVG, coefficients as `coef`, translation as `fmt` (TextRender.swift). */
export function svgMatrix(m: Affine): string {
  return `matrix(${coef(m.a)} ${coef(m.b)} ${coef(m.c)} ${coef(m.d)} ${fmt(m.tx)} ${fmt(m.ty)})`;
}

/** `matrix(…)` with every coefficient as `coef` (images in SVGWriter.swift). */
export function svgImageMatrix(m: Affine): string {
  return `matrix(${[m.a, m.b, m.c, m.d, m.tx, m.ty].map(coef).join(" ")})`;
}

export function pointsAttr(c: Point[]): string {
  return c.map((p) => `${fmt(p.x)},${fmt(p.y)}`).join(" ");
}

/** An item validated once, with its rotated frame (Swift `PreparedItem`). */
export interface PreparedItem {
  item: JSONObject;
  kind: string;
  frame: Rect;
  rotation: number;
  corners: Point[];
  minY: number;
  maxY: number;
  /** Background layers (below 100) first fill their frame with the paper colour (§8.2.3). */
  fillsBackground: boolean;
  /** Drawn under the item: a Markdown box's markers, bars, rules and code fills (§8.5.4), page coordinates. */
  underlay?: DrawCommand[];
}

/**
 * Prepares an item, or explains why it cannot be drawn (non-finite or
 * beyond the renderer's extent): such an item is skipped, never fatal.
 */
export function prepareItem(item: JSONObject): PreparedItem | string {
  const f = rectOf(item.frame);
  const rot = typeof item.rotation === "number" ? item.rotation : 0;
  if (!f || ![f.x, f.y, f.w, f.h].every(Number.isFinite) || !(f.w > 0 && f.h > 0) || !Number.isFinite(rot)) {
    return "outside the drawable area; not drawn";
  }
  const c = corners(f, rot);
  for (const p of c) {
    if (!Number.isFinite(p.x) || !Number.isFinite(p.y) || Math.abs(p.x) > RenderLimits.maxExtent
      || Math.abs(p.y) > RenderLimits.maxExtent) {
      return "outside the drawable area; not drawn";
    }
  }
  const ys = c.map((p) => p.y);
  return {
    item, kind: String(item.kind), frame: f, rotation: rot, corners: c,
    minY: Math.min(...ys), maxY: Math.max(...ys), fillsBackground: itemLayer(item) < 100,
  };
}

/** Most items drawn on one page (`RenderLimits.maxItemsPerPage`, §8.4). */
export const maxItemsPerPage = 10_000;

/** The paper fill of a background item. */
export function backgroundFill(it: PreparedItem, paper: Paper): DrawCommand {
  return { primitive: { kind: "path", subpaths: [{ points: it.corners, closed: true }] }, fill: paint(paper.background), lineWidth: 1 };
}

/** The crop an image item shows: its `crop` ∩ the oriented image, or undefined (§8.2.5). */
export function imageCrop(item: JSONObject, ow: number, oh: number): Rect | undefined {
  const full = { x: 0, y: 0, w: ow, h: oh };
  return intersect(rectOf(item.crop) ?? full, full);
}

export function itemOrientation(item: JSONObject): number {
  const o = item.orientation;
  return typeof o === "number" && Number.isInteger(o) && o >= 1 && o <= 8 ? o : 1;
}

/**
 * Stored pixel coordinates → page for an image item whose decoded (stored)
 * size is `w × h`, or why it cannot be placed (Swift `ImageStore.place`).
 */
export function imageTransform(it: PreparedItem, w: number, h: number): Affine | string {
  const o = itemOrientation(it.item);
  const os = orientedSize(o, w, h);
  const crop = imageCrop(it.item, os.w, os.h);
  if (!crop) return "crop lies outside the image";
  const m = after(placement(crop, it.frame, it.rotation), orientation(o, w, h));
  if (!isFiniteAffine(m) || !isInvertible(m)) return "degenerate placement";
  return m;
}

/**
 * Stored pixel coordinates → page for a video's poster decoded at `w × h`:
 * the whole image, upright, onto the frame (§8.2.7; Swift `ImageStore.place`).
 */
export function posterTransform(it: PreparedItem, w: number, h: number): Affine | string {
  const m = placement({ x: 0, y: 0, w, h }, it.frame, it.rotation);
  if (!(w > 0 && h > 0) || !isFiniteAffine(m) || !isInvertible(m)) return "degenerate placement";
  return m;
}

/** Effective-page coordinates → page for a PDF page item on an effective page `w × h`. */
export function pdfCrop(it: PreparedItem, w: number, h: number): Rect {
  return rectOf(it.item.crop) ?? { x: 0, y: 0, w, h };
}
