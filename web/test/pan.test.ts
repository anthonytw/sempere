// Sideways panning of the note view: none while the content fits the viewport's width.

import { describe, expect, it } from "vitest";
import { clampX, clampY } from "../src/ui/noteview.ts";

describe("clampX", () => {
  it("centres content that fits, whatever the offset", () => {
    for (const x of [-500, -48, 0, 16, 48, 500]) expect(clampX(x, 428, 460)).toBe(16);
    expect(clampX(-9, 460, 460)).toBe(0);
  });

  it("centres content within the margin of the viewport's width (no drift)", () => {
    // 468 + 2 * 40 > 500, yet it fits: it must not move.
    expect(clampX(30, 468, 500)).toBe(16);
    expect(clampX(-30, 468, 500)).toBe(16);
  });

  it("pans content wider than the viewport, within the margin of its edges", () => {
    expect(clampX(-100, 1000, 500)).toBe(-100);
    expect(clampX(100, 1000, 500)).toBe(40);
    expect(clampX(-9000, 1000, 500)).toBe(-540);
  });
});

describe("clampY", () => {
  it("keeps the margin at both ends", () => {
    expect(clampY(100, 5000, 800)).toBe(40);
    expect(clampY(-9999, 5000, 800)).toBe(-4240);
    expect(clampY(-50, 5000, 800)).toBe(-50);
  });
});
