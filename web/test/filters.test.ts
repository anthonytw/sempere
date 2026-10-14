// The sidebar's filters (src/ui/filters.ts).

import { describe, expect, it } from "vitest";
import { sameFilter } from "../src/ui/filters.ts";

describe("sidebar filters", () => {
  it("matches a tag by its key, whatever spelling is shown (bug audit B53)", () => {
    expect(sameFilter({ kind: "tag", key: "work", label: "Work" }, { kind: "tag", key: "work", label: "work" })).toBe(true);
    expect(sameFilter({ kind: "tag", key: "work", label: "Work" }, { kind: "tag", key: "home", label: "Work" })).toBe(false);
  });

  it("matches a notebook by its path and the rest by kind", () => {
    expect(sameFilter({ kind: "notebook", path: "A/B" }, { kind: "notebook", path: "A/B" })).toBe(true);
    expect(sameFilter({ kind: "notebook", path: "A/B" }, { kind: "notebook", path: "A" })).toBe(false);
    expect(sameFilter({ kind: "all" }, { kind: "all" })).toBe(true);
    expect(sameFilter({ kind: "all" }, { kind: "favorites" })).toBe(false);
    expect(sameFilter({ kind: "tag", key: "x", label: "x" }, { kind: "notebook", path: "x" })).toBe(false);
  });
});
