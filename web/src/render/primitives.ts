// Draw commands shared by the paper and stroke renderers, and the render
// limits of format.md §9 (Sources/SempereRender/Primitives.swift).

import type { Color } from "../format/model.ts";

export interface Point {
  x: number;
  y: number;
}

export function distance(a: Point, b: Point): number {
  const dx = b.x - a.x, dy = b.y - a.y;
  return Math.sqrt(dx * dx + dy * dy);
}

/** RGB 0…255 plus alpha 0…1. */
export interface Paint {
  r: number;
  g: number;
  b: number;
  alpha: number;
}

/** Clamps to 0…1; NaN becomes 0. */
export function clamp01(v: number): number {
  return Number.isNaN(v) ? 0 : Math.min(Math.max(v, 0), 1);
}

/** Paint from a `#RRGGBBAA` colour: alpha = `a / 255 × opacity`. */
export function paint(c: Color, opacity = 1): Paint {
  const v = parseInt(c.slice(1), 16);
  return {
    r: Math.floor(v / 0x1000000) & 0xff, g: (v >>> 16) & 0xff, b: (v >>> 8) & 0xff,
    alpha: clamp01(((v & 0xff) / 255) * opacity),
  };
}

export function paintHex(p: Paint): string {
  return "#" + [p.r, p.g, p.b].map((x) => x.toString(16).padStart(2, "0")).join("");
}

export interface Subpath {
  points: Point[];
  closed: boolean;
}

/** Shoelace signed area. */
export function signedArea(s: Subpath): number {
  const p = s.points;
  if (p.length <= 2) return 0;
  let a = 0;
  for (let i = 0; i < p.length; i++) {
    const u = p[i] as Point, v = p[(i + 1) % p.length] as Point;
    a += u.x * v.y - v.x * u.y;
  }
  return a / 2;
}

export type Primitive =
  | { kind: "rect"; x: number; y: number; width: number; height: number }
  | { kind: "line"; from: Point; to: Point }
  | { kind: "circle"; center: Point; radius: number }
  | { kind: "path"; subpaths: Subpath[] };

export interface DrawCommand {
  primitive: Primitive;
  fill?: Paint;
  stroke?: Paint;
  lineWidth: number;
}

export function pointCount(c: DrawCommand): number {
  const p = c.primitive;
  switch (p.kind) {
    case "rect": return 4;
    case "line": return 2;
    case "circle": return 1;
    case "path": return p.subpaths.reduce((n, s) => n + s.points.length, 0);
  }
}

/** Hard limits protecting the renderer from hostile or corrupt input (format.md §9). */
export const RenderLimits = {
  maxExtent: 200_000,
  minPaperSpacing: 4,
  maxPaperCommands: 40_000,
  maxPaperCommandsPerPage: 1_000_000,
  samplesPerPoint: 64,
  baseSamples: 1024,
  maxNibWidth: 1000,
  maxOutlinePoints: 40_000_000,
} as const;

export class RenderError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RenderError";
  }
}

/**
 * Deterministic number formatting with at most 3 decimals, as Swift's
 * `String(format: "%.3f")` (exact value, ties to even) with trailing zeros
 * removed. `toFixed` rounds exact ties away from zero instead; a tie at the
 * third decimal means 16·|v| is an odd integer, which is handled here.
 */
export function fmt(v: number): string {
  if (!Number.isFinite(v)) return "0";
  const a = Math.abs(v);
  let s: string;
  const sixteen = a * 16;
  if (a < 2 ** 40 && Number.isInteger(sixteen) && sixteen % 2 === 1) {
    let n = Math.floor(a * 1000);
    if (n % 2 === 1) n += 1;
    s = `${Math.floor(n / 1000)}.${String(n % 1000).padStart(3, "0")}`;
  } else {
    s = a.toFixed(3);
  }
  if (v < 0) s = "-" + s;
  if (s.includes(".")) s = s.replace(/0+$/, "").replace(/\.$/, "");
  return s === "-0" || s === "" ? "0" : s;
}
