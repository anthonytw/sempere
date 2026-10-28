// The stroke outline (src/render/stroke.ts `ribbon`, a port of StrokeOutline.outline):
// an end wider than the stroke next to it keeps its whole round cap.
import { describe, expect, it } from "vitest";
import { type Sample, ribbon } from "../src/render/stroke.ts";

function line(widths: number[], step: number): Sample[] {
  return widths.map((w, i) => ({ x: 10 + i * step, y: 10, w, h: w, o: 1, f: 0 }));
}

/** Whether the outline has a vertex at `(x, y)`. */
function hasPoint(s: Sample[], x: number, y: number): boolean {
  return ribbon(s, 1).some((sp) => sp.points.some((p) => Math.abs(p.x - x) < 1e-9 && Math.abs(p.y - y) < 1e-9));
}

describe("ribbon ends", () => {
  it("is one outline per stroke", () => {
    expect(ribbon(line([2, 2, 2, 2], 1), 1)).toHaveLength(1);
  });

  it("keeps the whole disc of an end wider than its neighbour", () => {
    // Widths 10 then 1 at 1 pt: the start's disc (radius 5) reaches x = 15 ahead of it.
    expect(hasPoint(line([10, 1, 1, 1], 1), 15, 10)).toBe(true);
    // Widths 6, 4, 3, 3 at 0.5 pt: radius 3 at x = 10.
    expect(hasPoint(line([6, 4, 3, 3, 3, 3], 0.5), 13, 10)).toBe(true);
    // The same at the far end.
    expect(hasPoint(line([1, 1, 1, 10], 1), 8, 10)).toBe(true);
  });

  it("adds no disc to an end no wider than the stroke", () => {
    expect(hasPoint(line([2, 2, 2, 2, 2, 2], 1), 11, 10)).toBe(false);
  });
});
