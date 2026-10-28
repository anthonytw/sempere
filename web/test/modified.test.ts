// A note's modified date (format.md §5.5, §10, §12.2), ported from
// Tests/SempereTests/ModifiedDateTests.swift: recognition-only deltas and the
// snapshots compaction and thinning write leave it at the last edit.

import { describe, expect, it } from "vitest";
import { type Op, decodeRevision, isDerivedOnly, modifiedDate, revisionModifiedDate } from "../src/format/model.ts";
import { LogBuilder, baseMillis, devA, devB, devC, newUUID, op, page, recognition, stroke } from "./builders.ts";

const p = "7e57c0de-0000-4000-8000-0000000000a1";
const recognized = (t: number): Op => op.setMeta({ field: "recognized", value: { at: baseMillis + t, pages: 1, read: 1 } });

function edits(log: LogBuilder) {
  return [log.delta(devA, 0, [{ op: "addPage", page: page(p, "a0") }, op.addStroke(p, stroke(newUUID()))]),
    log.delta(devA, 10, [op.addStroke(p, stroke(newUUID()))])];
}

describe("modifiedDate", () => {
  it("leaves out recognition-only deltas", () => {
    const log = new LogBuilder();
    const r = log.delta(devB, 20, [op.setPageRecognition(p, recognition("x"))]);
    const both = log.delta(devB, 30, [op.setPageRecognition(p, recognition("y")), recognized(30)]);
    const alone = log.delta(devB, 40, [recognized(40)]);
    for (const d of [r, both, alone]) expect(isDerivedOnly(d)).toBe(true);
    expect(modifiedDate([...edits(log), r, both, alone])).toBe(baseMillis + 10);
  });

  it("counts a delta with any other op, an empty one and a newer one", () => {
    const log = new LogBuilder();
    const mixed = log.delta(devA, 20, [op.addStroke(p, stroke(newUUID())), op.setPageRecognition(p, recognition("x"))]);
    expect(isDerivedOnly(mixed)).toBe(false);
    expect(modifiedDate([...edits(log), mixed])).toBe(baseMillis + 20);
    expect(modifiedDate([...edits(log), log.delta(devA, 30, [])])).toBe(baseMillis + 30);
    const newer = log.delta(devB, 40, [op.setPageRecognition(p, recognition("x"))]);
    newer.newer = { revisions: 1, unreadable: 0, skippedOps: {}, skippedElements: 0, formats: {}, features: { future: 1 } };
    expect(isDerivedOnly(newer)).toBe(false);
  });

  it("counts a saved version (any checkpoint object) as the user's act", () => {
    const wire = (checkpoint: unknown) => decodeRevision({
      type: "delta", noteId: "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c", device: devA, seq: 1, hlc: "17596320000200000",
      wall: "2025-10-05T02:40:00.020Z", app: "t/1", checkpoint,
      ops: [{ op: "setPageRecognition", pageId: p, recognition: { engine: "e", text: "x", words: [] } }],
    });
    const saved = wire({ name: 3 });
    expect(saved.checkpoint).toBe(true);
    expect(isDerivedOnly(saved)).toBe(false);
    const ignored = wire("not an object");
    expect(ignored.checkpoint).toBeUndefined();
    expect(isDerivedOnly(ignored)).toBe(true);
  });

  it("falls back to the newest wall when only derived deltas exist", () => {
    const log = new LogBuilder();
    expect(modifiedDate([log.delta(devB, 5, [op.setPageRecognition(p, recognition("a"))]),
      log.delta(devB, 50, [op.setPageRecognition(p, recognition("b"))])])).toBe(baseMillis + 50);
    expect(modifiedDate([])).toBeUndefined();
  });

  it("dates a snapshot by the newest edit it holds, not when it was written", () => {
    const log = new LogBuilder();
    const before = [...edits(log), log.delta(devB, 20, [op.setPageRecognition(p, recognition("x"))])];
    const snap = log.snapshot(devC, 86_400_000, before);
    expect(snap.wall).toBe(baseMillis + 86_400_000);
    expect(revisionModifiedDate(snap)).toBe(baseMillis + 10);
    expect(modifiedDate([snap, log.delta(devA, 90_000_000, [op.title("x")])])).toBe(baseMillis + 90_000_000);
    // Newer content: its wall (it may hold edits in fields this reader skipped).
    const newer = log.snapshot(devC, 86_400_000, edits(new LogBuilder()));
    expect(revisionModifiedDate(newer)).toBe(baseMillis + 10);
    newer.newer = { revisions: 1, unreadable: 0, skippedOps: {}, skippedElements: 0, formats: {}, features: { future: 1 } };
    expect(revisionModifiedDate(newer)).toBe(newer.wall);
    // Never after its own wall.
    const early = log.snapshot(devC, -60_000, edits(new LogBuilder()));
    expect(revisionModifiedDate(early)).toBe(early.wall);
  });
});
