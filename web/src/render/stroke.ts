// Stroke geometry: uniform cubic B-spline evaluation as PencilKit's
// `PKStrokePath`, adaptive sampling, and variable-width outlines. A port of
// Sources/SempereRender/Geometry.swift and StrokeOutline.swift; the output must
// match `sempere export --format svg` exactly (test/golden).

import { type InkTool, type Stroke, pointStride } from "../format/model.ts";
import {
  type DrawCommand, type Point, RenderLimits, type Subpath, clamp01, distance, paint,
} from "./primitives.ts";

export interface Sample {
  x: number;
  y: number;
  w: number;
  h: number;
  o: number;
  f: number;
}

const X = 0, Y = 1, W = 3, H = 4, O = 5, F = 6;

function at(p: Float64Array, i: number, field: number): number {
  return p[i * pointStride + field] ?? 0;
}

function segment(n: number, t: number): [number, number] {
  const c = Math.min(Math.max(Number.isNaN(t) ? 0 : t, 0), n - 1);
  const i = Math.min(Math.floor(c), n - 2);
  return [i, c - i];
}

function control(p: Float64Array, n: number, j: number): [number, number] {
  if (j < 0) return [2 * at(p, 0, X) - at(p, 1, X), 2 * at(p, 0, Y) - at(p, 1, Y)];
  if (j >= n) return [2 * at(p, n - 1, X) - at(p, n - 2, X), 2 * at(p, n - 1, Y) - at(p, n - 2, Y)];
  return [at(p, j, X), at(p, j, Y)];
}

/** Location at parameter `t`, untransformed. */
export function location(p: Float64Array, t: number): Point {
  const n = p.length / pointStride;
  if (n === 0) return { x: 0, y: 0 };
  if (n === 1) return { x: at(p, 0, X), y: at(p, 0, Y) };
  const [i, u] = segment(n, t);
  const c0 = control(p, n, i - 1), c1 = control(p, n, i), c2 = control(p, n, i + 1), c3 = control(p, n, i + 2);
  const u2 = u * u, u3 = u2 * u;
  const b0 = (1 - u) * (1 - u) * (1 - u) / 6;
  const b1 = (3 * u3 - 6 * u2 + 4) / 6;
  const b2 = (-3 * u3 + 3 * u2 + 3 * u + 1) / 6;
  const b3 = u3 / 6;
  return {
    x: b0 * c0[0] + b1 * c1[0] + b2 * c2[0] + b3 * c3[0],
    y: b0 * c0[1] + b1 * c1[1] + b2 * c2[1] + b3 * c3[1],
  };
}

/** Full sample at `t`: location on the B-spline, other attributes linear. */
export function sampleAt(p: Float64Array, t: number): Sample {
  const n = p.length / pointStride;
  if (n === 0) return { x: 0, y: 0, w: 0, h: 0, o: 0, f: 0 };
  const loc = location(p, t);
  if (n === 1) return { x: loc.x, y: loc.y, w: at(p, 0, W), h: at(p, 0, H), o: at(p, 0, O), f: at(p, 0, F) };
  const [i, u] = segment(n, t);
  const lerp = (field: number) => {
    const a = at(p, i, field), b = at(p, i + 1, field);
    return a + (b - a) * u;
  };
  return { x: loc.x, y: loc.y, w: lerp(W), h: lerp(H), o: lerp(O), f: lerp(F) };
}

type Transform = [number, number, number, number, number, number];

export function transformOf(s: Stroke): Transform {
  const t = s.transform;
  return t ? [t[0] ?? 1, t[1] ?? 0, t[2] ?? 0, t[3] ?? 1, t[4] ?? 0, t[5] ?? 0] : [1, 0, 0, 1, 0, 0];
}

export function applyTransform(t: Transform, x: number, y: number): Point {
  return { x: t[0] * x + t[2] * y + t[4], y: t[1] * x + t[3] * y + t[5] };
}

/** Uniform scale for widths: `sqrt(|det|)`; non-finite collapses to 0. */
export function meanScale(t: Transform): number {
  const det = Math.abs(t[0] * t[3] - t[1] * t[2]);
  return Number.isFinite(det) ? Math.sqrt(det) : 0;
}

function pt(s: Sample): Point {
  return { x: s.x, y: s.y };
}

/**
 * Adaptive samples of a stroke's curve with its transform applied: at least
 * two for any non-empty stroke, none for an empty one.
 */
export function samples(stroke: Stroke, tolerance = 0.05, maxSpacing = 1.0, offsetY = 0): Sample[] {
  const pts = stroke.points;
  const count = pts.length / pointStride;
  if (count === 0) return [];
  const xf = transformOf(stroke);
  const scale = meanScale(xf);
  const tol = Number.isFinite(tolerance) ? Math.max(tolerance, 1e-4) : 0.05;
  const cap = Number.isFinite(maxSpacing) ? Math.max(maxSpacing, 0.01) : 1.0;

  const evaluate = (t: number): Sample => {
    const s = sampleAt(pts, t);
    const p = applyTransform(xf, s.x, s.y);
    return { x: p.x, y: p.y + offsetY, w: s.w * scale, h: s.h * scale, o: s.o, f: s.f };
  };

  const segments = count - 1;
  const budget = RenderLimits.samplesPerPoint * count + RenderLimits.baseSamples;
  let maxDepth = 12;
  while (maxDepth > 1 && segments > Math.floor(budget / 2 ** maxDepth)) maxDepth -= 1;

  const out: Sample[] = [evaluate(0)];
  if (count > 1) {
    const subdivide = (t0: number, s0: Sample, t1: number, s1: Sample, depth: number): void => {
      const tm = (t0 + t1) / 2;
      const sm = evaluate(tm);
      const chord = distance(pt(s0), pt(s1));
      const mid = { x: (s0.x + s1.x) / 2, y: (s0.y + s1.y) / 2 };
      const flat = distance(pt(sm), mid) <= tol;
      const limit = flat ? cap * 4 : cap;
      if (depth < maxDepth && (depth === 0 || !flat || chord > limit)) {
        subdivide(t0, s0, tm, sm, depth + 1);
        subdivide(tm, sm, t1, s1, depth + 1);
      } else {
        out.push(s1);
      }
    };
    for (let i = 0; i < count - 1; i++) {
      subdivide(i, out[out.length - 1] as Sample, i + 1, evaluate(i + 1), 0);
    }
  }

  // Drop coincident neighbours (repeated control points).
  const dedup: Sample[] = [];
  for (const s of out) {
    const last = dedup[dedup.length - 1];
    if (last && distance(pt(last), pt(s)) < 1e-9) continue;
    dedup.push(s);
  }
  if (dedup.length < 2) {
    const only = dedup[0] ?? out[0];
    return only ? [only, only] : [];
  }
  return dedup;
}

/** Opacity multiplier per tool, on top of colour alpha and sample opacity. */
export function toolOpacity(tool: InkTool): number {
  switch (tool) {
    case "pen": case "fountainPen": case "monoline": return 1;
    case "marker": return 0.5;
    case "pencil": return 0.8;
    case "crayon": return 0.85;
    case "watercolor": return 0.5;
  }
}

export function opacityFactor(stroke: Stroke, s: Sample[]): number {
  const meanO = s.length === 0 ? 1 : s.reduce((n, x) => n + x.o, 0) / s.length;
  return clamp01(meanO) * toolOpacity(stroke.ink.tool);
}

/** Unit-circle vertices (32 segments) written out, as in Swift, so no libm call sits in the output path. */
const unitCircle: [number, number][] = [
  [1.0, 0.0], [0.9807852804032304, 0.1950903220161282], [0.9238795325112867, 0.3826834323650898],
  [0.8314696123025452, 0.5555702330196022], [0.7071067811865476, 0.7071067811865475],
  [0.5555702330196023, 0.8314696123025452], [0.3826834323650898, 0.9238795325112867],
  [0.1950903220161283, 0.9807852804032304], [1e-16, 1.0], [-0.1950903220161282, 0.9807852804032304],
  [-0.3826834323650897, 0.9238795325112867], [-0.555570233019602, 0.8314696123025453],
  [-0.7071067811865475, 0.7071067811865476], [-0.8314696123025453, 0.5555702330196022],
  [-0.9238795325112867, 0.3826834323650899], [-0.9807852804032304, 0.1950903220161286], [-1.0, 1e-16],
  [-0.9807852804032304, -0.1950903220161284], [-0.9238795325112868, -0.3826834323650897],
  [-0.8314696123025455, -0.555570233019602], [-0.7071067811865477, -0.7071067811865475],
  [-0.5555702330196022, -0.8314696123025452], [-0.3826834323650903, -0.9238795325112865],
  [-0.1950903220161287, -0.9807852804032303], [-2e-16, -1.0], [0.1950903220161283, -0.9807852804032304],
  [0.38268343236509, -0.9238795325112866], [0.5555702330196018, -0.8314696123025455],
  [0.7071067811865474, -0.7071067811865477], [0.8314696123025452, -0.5555702330196022],
  [0.9238795325112865, -0.3826834323650904], [0.9807852804032303, -0.1950903220161287],
];

export function circle(c: Point, r: number): Subpath {
  return { points: unitCircle.map(([x, y]) => ({ x: c.x + r * x, y: c.y + r * y })), closed: true };
}

function isDot(s: Sample[]): boolean {
  const first = s[0];
  return first !== undefined && s.every((x) => distance(pt(x), pt(first)) < 1e-9);
}

/** The 32-gon around `c` as a closed counter-clockwise loop (its first vertex repeated at the end). */
function disc(c: Point, r: number): Point[] {
  const out = unitCircle.map(([x, y]) => ({ x: c.x + r * x, y: c.y + r * y }));
  out.push(out[0] as Point);
  return out;
}

/**
 * The 32-gon's vertices around `c` strictly inside the counter-clockwise turn from direction `u` to
 * direction `v` (a half turn when `v` is opposite `u`), in that order. StrokeOutline.arc.
 */
function arc(c: Point, r: number, ux: number, uy: number, vx: number, vy: number): Point[] {
  const uv = ux * vy - uy * vx;
  const half = uv <= 0;
  if (half && ux * vx + uy * vy >= 0) return [];
  const count = unitCircle.length;
  const inside = unitCircle.map(([tx, ty]) => ux * ty - uy * tx > 0 && (half || tx * vy - ty * vx > 0));
  let start = -1;
  for (let j = 0; j < count; j++) {
    if (inside[j] && !inside[(j + count - 1) % count]) { start = j; break; }
  }
  if (start < 0) return [];
  const out: Point[] = [];
  let j = start;
  while (inside[j]) {
    const [tx, ty] = unitCircle[j] as [number, number];
    out.push({ x: c.x + r * tx, y: c.y + r * ty });
    j = (j + 1) % count;
    if (j === start) break;
  }
  return out;
}

/**
 * The outline of a disc of radius `radii[i]` swept along `input` (round caps and joins), for a
 * non-zero fill: one polygon for an open polyline, two rings for a closed one, a 32-gon for a single
 * point. A port of StrokeOutline.outline (see there); the arithmetic is the same, operation for
 * operation, so the SVG matches the CLI's exactly.
 */
export function outline(input: Point[], radii: number[], closed: boolean): Point[][] {
  const p: Point[] = [], r: number[] = [];
  input.forEach((q, i) => {
    const rq = radii[i] ?? 0;
    const last = p[p.length - 1];
    if (last !== undefined && distance(last, q) <= 1e-9) {
      r[r.length - 1] = Math.max(r[r.length - 1] as number, rq);
      return;
    }
    p.push(q); r.push(rq);
  });
  if (closed && p.length > 2 && distance(p[p.length - 1] as Point, p[0] as Point) <= 1e-9) {
    r[0] = Math.max(r[0] as number, r[r.length - 1] as number);
    p.pop(); r.pop();
  }
  const first = p[0];
  if (first === undefined) return [];
  if (p.length === 1) return [circle(first, r.reduce((a, b) => Math.max(a, b), -Infinity)).points];
  const ring = closed && p.length > 2;
  const m = p.length, segments = ring ? m : m - 1;
  const P = (v: number) => p[v] as Point, R = (v: number) => r[v] as number;
  const dx: number[] = [], dy: number[] = [];
  for (let k = 0; k < segments; k++) {
    const a = P(k), b = P((k + 1) % m);
    const len = distance(a, b);
    dx.push((b.x - a.x) / len); dy.push((b.y - a.y) / len);
  }
  const DX = (k: number) => dx[k] as number, DY = (k: number) => dy[k] as number;
  const into = (v: number): number | undefined => (v > 0 ? v - 1 : ring ? segments - 1 : undefined);
  const outOf = (v: number): number | undefined => (v < segments ? v : undefined);
  const mitred: boolean[] = new Array<boolean>(m).fill(false), sharp: boolean[] = new Array<boolean>(m).fill(false);
  for (let v = 0; v < m; v++) {
    const i = into(v), o = outOf(v);
    if (i === undefined || o === undefined) continue;
    mitred[v] = DX(i) * DX(o) + DY(i) * DY(o) >= 0.97;
    sharp[v] = !mitred[v];
  }
  /** The cross-section at vertex `v` on segment `k`'s side: [left, right]. */
  const section = (v: number, k: number): [Point, Point] => {
    const c = P(v), rv = R(v);
    let nx = -DY(k), ny = DX(k);
    const i = into(v), o = outOf(v);
    if (mitred[v] && i !== undefined && o !== undefined) {
      const s = 1 + (DX(i) * DX(o) + DY(i) * DY(o));
      nx = (-DY(i) - DY(o)) / s; ny = (DX(i) + DX(o)) / s;
    }
    return [{ x: c.x + rv * nx, y: c.y + rv * ny }, { x: c.x - rv * nx, y: c.y - rv * ny }];
  };
  const convex = (k: number): boolean => {
    const [ls, rs] = section(k, k), [le, re] = section((k + 1) % m, k);
    const q = [rs, re, le, ls];
    for (let j = 0; j < 4; j++) {
      const a = q[j] as Point, b = q[(j + 1) % 4] as Point, c = q[(j + 2) % 4] as Point;
      if (!((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) > 0)) return false;
    }
    return true;
  };
  const check: number[] = [];
  for (let k = segments - 1; k >= 0; k--) check.push(k);
  for (let k = check.pop(); k !== undefined; k = check.pop()) {
    const e = (k + 1) % m;
    if (!(mitred[k] || mitred[e]) || convex(k)) continue;
    if (mitred[k]) { mitred[k] = false; const i = into(k); if (i !== undefined) check.push(i); }
    if (mitred[e]) { mitred[e] = false; const o = outOf(e); if (o !== undefined) check.push(o); }
  }
  const right: Point[] = [], left: Point[] = [];
  for (let v = 0; v < m; v++) {
    const c = P(v), rv = R(v);
    const i = into(v), o = outOf(v);
    if (i === undefined || o === undefined || mitred[v]) {
      const [l, rr] = section(v, o ?? i ?? 0);
      left.push(l); right.push(rr);
      continue;
    }
    const n1x = -DY(i), n1y = DX(i), n2x = -DY(o), n2y = DX(o);
    const l1 = { x: c.x + rv * n1x, y: c.y + rv * n1y }, l2 = { x: c.x + rv * n2x, y: c.y + rv * n2y };
    const r1 = { x: c.x - rv * n1x, y: c.y - rv * n1y }, r2 = { x: c.x - rv * n2x, y: c.y - rv * n2y };
    const cross = DX(i) * DY(o) - DY(i) * DX(o);
    const turnsLeft = cross > 0 || (cross === 0 && DX(i) * DX(o) + DY(i) * DY(o) < 0);
    if (sharp[v]) {
      const loop = disc(c, rv);
      if (turnsLeft) {
        right.push(r1, r2);
        left.push(l1, c, ...loop.reverse(), c, l2);
      } else {
        left.push(l1, l2);
        right.push(r1, c, ...loop, c, r2);
      }
    } else if (turnsLeft) {
      right.push(r1, ...arc(c, rv, -n1x, -n1y, -n2x, -n2y), r2);
      left.push(l1, c, l2);
    } else {
      left.push(l1, ...arc(c, rv, n2x, n2y, n1x, n1y).reverse(), l2);
      right.push(r1, c, r2);
    }
  }
  if (ring) return [right, left.reverse()];
  /** StrokeOutline.outline's needsDisc: the end may be wider than the stroke near it, or it bends there. */
  const needsDisc = (v: number, step: number): boolean => {
    let length = 0, k = v;
    for (;;) {
      const next = k + step;
      if (!(next >= 0 && next < m)) return false;
      length += distance(P(k), P(next));
      if (length >= 2 * R(v)) return false;
      if (R(next) < R(v)) return true;
      if (next === 0 || next === m - 1) return false;
      if (!mitred[next]) return true;
      k = next;
    }
  };
  const discAt = (v: number, x: Point): Point[] => [P(v), ...disc(P(v), R(v)), P(v), x];
  const s = segments - 1;
  const out = right;
  if (needsDisc(m - 1, -1)) out.push(...discAt(m - 1, out[out.length - 1] as Point));
  out.push(...arc(P(m - 1), R(m - 1), DY(s), -DX(s), -DY(s), DX(s)));
  for (let k = left.length - 1; k >= 0; k--) out.push(left[k] as Point);
  if (needsDisc(0, 1)) out.push(...discAt(0, out[out.length - 1] as Point));
  out.push(...arc(P(0), R(0), -DY(0), DX(0), DY(0), -DX(0)));
  return [out];
}

/** Variable-width ribbon: one closed outline (StrokeOutline.ribbon), for a non-zero fill. */
export function ribbon(s: Sample[], fallbackWidth: number): Subpath[] {
  if (s.length === 0) return [];
  const radius = (x: Sample) => Math.min(Math.max(x.w > 0 ? x.w : fallbackWidth, 0.05), RenderLimits.maxNibWidth) / 2;
  return outline(s.map(pt), s.map(radius), false).map((points) => ({ points, closed: true }));
}

/** Draw commands for one stroke (empty for a stroke with no points). */
export function strokeCommands(stroke: Stroke, tolerance = 0.05, offsetY = 0): DrawCommand[] {
  const s = samples(stroke, tolerance, 1.0, offsetY);
  if (s.length === 0) return [];
  const scale = meanScale(transformOf(stroke));
  const fill = paint(stroke.ink.color, opacityFactor(stroke, s));
  if (stroke.ink.tool === "monoline") {
    const width = Math.min(Math.max(stroke.ink.width * scale, 0.05), RenderLimits.maxNibWidth);
    if (isDot(s)) {
      return [{ primitive: { kind: "path", subpaths: [circle(pt(s[0] as Sample), width / 2)] }, fill, lineWidth: 1 }];
    }
    return [{ primitive: { kind: "path", subpaths: [{ points: s.map(pt), closed: false }] }, stroke: fill, lineWidth: width }];
  }
  const polys = ribbon(s, stroke.ink.width * scale);
  return polys.length === 0 ? [] : [{ primitive: { kind: "path", subpaths: polys }, fill, lineWidth: 1 }];
}
