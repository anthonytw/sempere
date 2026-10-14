// Clock values, device ids, stamps, revision names, origins and `included`
// (format.md §5, §5.3, §5.5), ported from the pure-model cases of
// Tests/SempereTests/ClockTests.swift. (HybridClock ticking is writer-side.)

import { describe, expect, it } from "vitest";
import {
  Included, cmpName, cmpOrigin, cmpStamp, entryCovers, isDeviceID, isHLC, maxSeq, normalizeEntry, originString,
  parseOrigin, parseRevisionName, parseStamp, revisionFilename, stampString, zeroStamp,
} from "../src/format/ids.ts";
import { decodeRevision } from "../src/format/model.ts";
import { reconstruct } from "../src/format/reducer.ts";
import { LogBuilder, baseMillis, delta, devA, devB, hlcString, op, snapshotParts, testNote } from "./builders.ts";

function must<T>(v: T | undefined): T {
  if (v === undefined) throw new Error("expected a value");
  return v;
}

describe("HLC", () => {
  it("is exactly 17 ASCII digits, ordered as strings", () => {
    expect(hlcString(1_759_632_000_000, 3)).toBe("17596320000000003");
    expect(isHLC("17596320000000003")).toBe(true);
    expect(hlcString(5, 0)).toBe("00000000000050000");
    for (const bad of ["1759632000000000", "175963200000000033", "1759632000000000x", "-7596320000000003",
      "１7596320000000003", "+7596320000000003", " 17596320000000003", ""]) {
      expect(isHLC(bad), bad).toBe(false);
    }
    expect("17596320000000003" < "17596320000000004").toBe(true);
    expect("17596320000009999" < "17596320000010000").toBe(true);
  });

  it("merges a revision stamped far ahead by its stamp as written", () => {
    const log = new LogBuilder();
    const farAhead = hlcString(baseMillis + 24 * 60 * 60 * 1000 + 1);
    const future = delta(devB, 1, farAhead, baseMillis, [op.title("future")]);
    const now = log.delta(devA, 0, [op.title("now")]);
    expect(reconstruct([now, future]).meta.title).toBe("future");
  });
});

describe("device ids and stamps", () => {
  it("accepts 8 lowercase hex digits only", () => {
    expect(isDeviceID("a1b2c3d4")).toBe(true);
    for (const bad of ["A1B2C3D4", "a1b2c3d", "a1b2c3dg", "a1b2c3d4e", ""]) expect(isDeviceID(bad), bad).toBe(false);
  });

  it("parses, prints and orders stamps", () => {
    const s = must(parseStamp("17596320000000003-a1b2c3d4"));
    expect(s).toEqual({ hlc: "17596320000000003", device: "a1b2c3d4" });
    expect(stampString(s)).toBe("17596320000000003-a1b2c3d4");
    expect(parseStamp("17596320000000003a1b2c3d4")).toBeUndefined();
    expect(parseStamp("17596320000000003-a1b2c3d4-1")).toBeUndefined();
    expect(parseStamp("17596320000000003-A1B2C3D4")).toBeUndefined();
    expect(cmpStamp(s, { hlc: s.hlc, device: "a1b2c3d5" })).toBeLessThan(0);
    expect(cmpStamp({ hlc: s.hlc, device: "ffffffff" }, { hlc: "17596320000000004", device: "00000000" })).toBeLessThan(0);
    expect(cmpStamp(zeroStamp, s)).toBeLessThan(0);
    expect(cmpStamp(s, { ...s })).toBe(0);
  });
});

describe("revision names", () => {
  it("parses canonical names and rejects the rest", () => {
    const n = must(parseRevisionName("17596320000000003-a1b2c3d4-12.delta.age"));
    expect(n.seq).toBe(12);
    expect(n.kind).toBe("delta");
    expect(revisionFilename(n)).toBe("17596320000000003-a1b2c3d4-12.delta.age");
    expect(parseRevisionName("17596320000000003-a1b2c3d4-1.snapshot.age")?.kind).toBe("snapshot");
    for (const bad of ["17596320000000003-a1b2c3d4-012.delta.age", "17596320000000003-a1b2c3d4-0.delta.age",
      "17596320000000003-a1b2c3d4-12.delta", "17596320000000003-a1b2c3d4-12.diff.age",
      "1759632000000003-a1b2c3d4-12.delta.age", "17596320000000003-A1B2C3D4-12.delta.age",
      "17596320000000003-a1b2c3d4--12.delta.age", "17596320000000003-a1b2c3d4-12.delta.age.tmp",
      "17596320000000003-a1b2c3d4-+12.delta.age", "17596320000000003-a1b2c3d4-.delta.age"]) {
      expect(parseRevisionName(bad), bad).toBeUndefined();
    }
  });

  it("bounds seq at 2^53 - 1", () => {
    expect(parseRevisionName(`17596320000000003-a1b2c3d4-${maxSeq}.delta.age`)?.seq).toBe(maxSeq);
    expect(parseRevisionName("17596320000000003-a1b2c3d4-9007199254740992.delta.age")).toBeUndefined();
    expect(parseRevisionName("17596320000000003-a1b2c3d4-99999999999999999999999.delta.age")).toBeUndefined();
  });

  it("orders names by (hlc, device, seq, kind) with numeric seq", () => {
    const names = ["17596320000000003-bbbbbbbb-1.delta.age", "17596320000000003-aaaaaaaa-10.delta.age",
      "17596320000000003-aaaaaaaa-9.delta.age", "17596320000000002-ffffffff-50.snapshot.age"].map((s) => must(parseRevisionName(s)));
    expect(names.sort(cmpName).map(revisionFilename)).toEqual([
      "17596320000000002-ffffffff-50.snapshot.age", "17596320000000003-aaaaaaaa-9.delta.age",
      "17596320000000003-aaaaaaaa-10.delta.age", "17596320000000003-bbbbbbbb-1.delta.age",
    ]);
  });
});

describe("origins", () => {
  it("parses, prints and orders origins", () => {
    const o = must(parseOrigin("17596320000000003-a1b2c3d4-12-0"));
    expect(o.seq).toBe(12);
    expect(o.op).toBe(0);
    expect(originString(o)).toBe("17596320000000003-a1b2c3d4-12-0");
    for (const bad of ["17596320000000003-a1b2c3d4-12", "17596320000000003-a1b2c3d4-12-01",
      "17596320000000003-a1b2c3d4-x-0", "17596320000000003-a1b2c3d4-12-0-1", "17596320000000003-a1b2c3d4-012-0",
      "17596320000000003-a1b2c3d4--0"]) {
      expect(parseOrigin(bad), bad).toBeUndefined();
    }
    expect(cmpOrigin(must(parseOrigin("17596320000000003-a1b2c3d4-12-1")),
      must(parseOrigin("17596320000000003-a1b2c3d4-12-2")))).toBeLessThan(0);
    expect(cmpOrigin(must(parseOrigin("17596320000000003-a1b2c3d4-9-5")),
      must(parseOrigin("17596320000000003-a1b2c3d4-10-0")))).toBeLessThan(0);
    expect(parseOrigin("17596320000000003-a1b2c3d4-0-0")).toBeUndefined(); // seq starts at 1
    expect(parseOrigin("17596320000000003-a1b2c3d4-1-0")).toBeDefined();
  });

});

describe("included", () => {
  it("inserts, covers and unions", () => {
    const inc = new Included();
    expect(inc.covers(devA, 1)).toBe(false);
    for (const s of [1, 2, 5, 6, 3]) inc.insert(devA, s);
    expect(inc.entries.get(devA)).toEqual({ upTo: 3, extra: [5, 6] });
    expect(inc.covers(devA, 5)).toBe(true);
    expect(inc.covers(devA, 4)).toBe(false);
    inc.insert(devA, 4);
    expect(inc.entries.get(devA)).toEqual({ upTo: 6, extra: [] });
    expect(inc.covers(devA, 0)).toBe(false);
    expect(inc.covers(devA, -3)).toBe(false);
    inc.insert(devA, 0); // ignored
    expect(inc.entries.get(devA)?.upTo).toBe(6);

    const other = new Included();
    other.entries.set(devA, { upTo: 2, extra: [8] });
    other.entries.set(devB, { upTo: 1, extra: [3] });
    const u = inc.union(other);
    expect(u.entries.get(devA)).toEqual({ upTo: 6, extra: [8] });
    expect(u.entries.get(devB)).toEqual({ upTo: 1, extra: [3] });
    expect(u.toJSON()).toEqual(other.union(inc).toJSON());
  });

  it("normalises entries", () => {
    expect(normalizeEntry(2, [4, 3, 1, 7])).toEqual({ upTo: 4, extra: [7] });
    expect(normalizeEntry(0, [3, 3, 2])).toEqual({ upTo: 0, extra: [2, 3] });
    expect(entryCovers({ upTo: 4, extra: [7, 9] }, 9)).toBe(true);
    expect(entryCovers({ upTo: 4, extra: [7, 9] }, 8)).toBe(false);
  });

  it("decodes from a snapshot and re-encodes sorted", () => {
    const snap = (included: unknown) => decodeRevision({
      noteId: testNote, device: devA, seq: 1, hlc: "17596320000000009", wall: "2026-10-04T16:20:00Z", app: "x",
      type: "snapshot", included,
      state: {
        deleted: false, pages: [],
        meta: { title: "", tags: [], favorite: false, created: "2026-10-04T16:20:00Z", paper: { kind: "blank" },
          pageSize: { width: 612, height: 792, infinite: false } },
        tagSet: { instances: [], removed: [] },
      },
    });
    const decoded = snapshotParts(snap({ a1b2c3d4: { upTo: 12, extra: [15, 16] }, "99ee00ff": { upTo: 3, extra: [] } })).included;
    expect(decoded.covers("a1b2c3d4", 16)).toBe(true);
    expect(decoded.covers("a1b2c3d4", 13)).toBe(false);
    expect(JSON.stringify(decoded.toJSON())).toBe('{"99ee00ff":{"extra":[],"upTo":3},"a1b2c3d4":{"extra":[15,16],"upTo":12}}');
    // Normalised on decode.
    expect(snapshotParts(snap({ a1b2c3d4: { upTo: 2, extra: [4, 3, 1, 7] } })).included.entries.get("a1b2c3d4"))
      .toEqual({ upTo: 4, extra: [7] });
    expect(() => snap({ XYZ: { upTo: 1, extra: [] } })).toThrow();
    expect(() => snap({ a1b2c3d4: { upTo: 9007199254740992, extra: [] } })).toThrow();
    expect(() => snap({ a1b2c3d4: { upTo: 1 } })).toThrow();
    expect(() => snap({ a1b2c3d4: { upTo: 1.5, extra: [] } })).toThrow();
  });
});
