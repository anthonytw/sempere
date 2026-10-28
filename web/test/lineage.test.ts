// Concurrent replacements of one stroke (format.md §5.6.1): the shared vectors
// Tests/SempereTests/ConcurrentSliceTests.swift writes (random logs of writers
// with partial views, some compacted) must reconstruct to the Swift reducer's
// note, in any order.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { decodeRevision, decodeState, encodeState } from "../src/format/model.ts";
import { Budget } from "../src/format/attachments.ts";
import { reconstruct } from "../src/format/reducer.ts";
import { formatRFC3339 } from "../src/format/rfc3339.ts";
import { SplitMix64 } from "./builders.ts";
import { fixtures } from "./support.ts";

interface Vectors { cases: { name: string; revisions: unknown[]; state: unknown }[] }

const v = JSON.parse(readFileSync(join(fixtures, "concurrent-replacement-vectors.json"), "utf8")) as Vectors;

function canonical(x: unknown): unknown {
  if (Array.isArray(x)) return x.map(canonical);
  if (x && typeof x === "object") {
    return Object.fromEntries(Object.keys(x).sort().map((k) => [k, canonical((x as Record<string, unknown>)[k])]));
  }
  return x;
}

describe("concurrent replacement vectors", () => {
  it("has cases that exercise the rule", () => {
    const states = v.cases.map((c) => decodeState(c.state, "$", new Budget()));
    expect(states.some((s) => (s.tombstones?.superseded.length ?? 0) > 0)).toBe(true);
    expect(states.some((s) => (s.tombstones?.lineage.length ?? 0) > 0)).toBe(true);
  });

  for (const c of v.cases) {
    it(`reconstructs ${c.name} like Swift, in any order`, () => {
      const revs = c.revisions.map(decodeRevision);
      const want = canonical(c.state);
      expect(canonical(encodeState(reconstruct(revs), formatRFC3339))).toEqual(want);
      const rng = new SplitMix64(7n);
      for (let i = 0; i < 5; i++) {
        const shuffled = revs.map((r) => ({ r, k: rng.next() })).sort((a, b) => (a.k < b.k ? -1 : a.k > b.k ? 1 : 0))
          .map((x) => x.r);
        expect(canonical(encodeState(reconstruct(shuffled), formatRFC3339))).toEqual(want);
      }
    });
  }
});
