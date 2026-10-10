// Decoding the format's JSON (format.md §5.1–§5.6, §6), ported from the
// decoding cases of Tests/SempereTests/RevisionJSONTests.swift, ModelTests.swift,
// PaperModelTests.swift and the RFC 3339 cases of UntrustedInputTests.swift.

import { describe, expect, it } from "vitest";
import { Budget } from "../src/format/attachments.ts";
import { DecodeError } from "../src/format/json.ts";
import { Included, revisionFilename } from "../src/format/ids.ts";
import {
  type Paper, decodeOp, decodePaper, decodeRevision, decodeStroke, defaultPaper, encodePaper, paperKind, parseColor,
  revisionName,
} from "../src/format/model.ts";
import { earliestMillis, endMillis, formatRFC3339, parseRFC3339 } from "../src/format/rfc3339.ts";
import { SplitMix64, letter, op, page, snapshotParts, testNote } from "./builders.ts";

const pageId = "7e57c0de-0000-4000-8000-000000000001";
const gone = "7e57c0de-0000-4000-8000-000000000002";
const cream = "#FFF8E1FF";

function must<T>(v: T | undefined): T {
  if (v === undefined) throw new Error("expected a value");
  return v;
}

function decodeOne(v: unknown) {
  return decodeOp(v, "$", new Budget());
}

const goodDelta = {
  app: "x", device: "a1b2c3d4", hlc: "17596320000000003", noteId: testNote, ops: [], seq: 1, type: "delta",
  wall: "2026-10-04T16:20:00Z",
};

describe("revisions", () => {
  it("decodes the spec's delta", () => {
    const rev = decodeRevision({
      app: "sempere-ios/0.1", device: "a1b2c3d4", hlc: "17596320000000003", noteId: testNote,
      ops: [{ op: "addPage", page: { id: "7E57C0DE-0000-4000-8000-000000000001", order: "a0", strokes: [] } },
        { field: "title", op: "setMeta", value: "Lecture 3" }, { op: "deleteNote" }],
      seq: 12, type: "delta", wall: "2026-10-04T16:20:00.123Z",
    });
    expect(rev).toEqual({
      noteId: testNote, device: "a1b2c3d4", seq: 12, hlc: "17596320000000003", wall: Date.UTC(2026, 9, 4, 16, 20, 0, 123),
      app: "sempere-ios/0.1", body: { type: "delta", ops: [op.addPage(pageId, "a0"), op.title("Lecture 3"), op.deleteNote()] },
    });
    expect(revisionFilename(revisionName(rev))).toBe("17596320000000003-a1b2c3d4-12.delta.age");
  });

  it("decodes the spec's snapshot", () => {
    const rev = decodeRevision({
      app: "sempere-ios/0.1", device: "a1b2c3d4", hlc: "17596320000000009",
      included: { "99ee00ff": { extra: [], upTo: 3 }, a1b2c3d4: { extra: [15, 16], upTo: 12 } },
      noteId: testNote, seq: 17,
      state: {
        clocks: { title: "17596320000000002-99ee00ff" }, deleted: false,
        meta: { created: "2026-10-04T16:20:00.000Z", favorite: false, notebook: "School",
          pageSize: { height: 792, infinite: false, width: 612 },
          paper: { background: "#FFFFFFFF", kind: "ruled", lineColor: "#D0D8E8FF", spacing: 24 },
          tags: ["math", "fall"], title: "Lecture 3" },
        pages: [{ id: pageId, order: "a0", orderClock: "17596320000000001-a1b2c3d4", strokes: [] }],
        tombstones: { pages: [], strokes: [gone] },
      },
      type: "snapshot", wall: "2026-10-04T16:20:00.500Z",
    });
    const included = new Included();
    included.entries.set("a1b2c3d4", { upTo: 12, extra: [15, 16] });
    included.entries.set("99ee00ff", { upTo: 3, extra: [] });
    const { included: inc, state } = snapshotParts(rev);
    expect(inc.toJSON()).toEqual(included.toJSON());
    expect(state).toEqual({
      deleted: false,
      meta: { title: "Lecture 3", tags: ["math", "fall"], notebook: "School", favorite: false,
        created: Date.UTC(2026, 9, 4, 16, 20), paper: defaultPaper("ruled"), pageSize: letter },
      pages: [{ ...page(pageId, "a0"), orderClock: "17596320000000001-a1b2c3d4" }],
      clocks: { title: "17596320000000002-99ee00ff" },
      tombstones: { strokes: [gone], pages: [], items: [], recordings: [], lineage: [], superseded: [] },
      recordings: [],
    });
    expect(revisionFilename(revisionName(rev))).toBe("17596320000000009-a1b2c3d4-17.snapshot.age");
  });

  it("decodes pre-amendment snapshots without clocks or tombstones", () => {
    const rev = decodeRevision({
      ...goodDelta, type: "snapshot", included: {},
      state: { deleted: false, pages: [{ id: pageId, order: "a0", strokes: [] }],
        meta: { title: "", tags: [], favorite: false, created: "1970-01-01T00:00:00Z", paper: { kind: "blank" },
          pageSize: { width: 612, height: 792, infinite: false } } },
    });
    const { state } = snapshotParts(rev);
    expect(state.clocks).toBeUndefined();
    expect(state.tombstones).toBeUndefined();
    expect(state.tagSet).toBeUndefined();
    expect(state.pages[0]?.orderClock).toBeUndefined();
  });

  it("reads null markers and null pages as absent, as Swift's decodeIfPresent", () => {
    const meta = { title: "", tags: [], favorite: false, created: "1970-01-01T00:00:00Z", paper: { kind: "blank" },
      pageSize: { width: 612, height: 792, infinite: false } };
    const rev = decodeRevision({
      ...goodDelta, type: "snapshot", included: {}, format: null, features: null, state: { deleted: false, pages: null, meta },
    });
    expect(rev.newer).toBeUndefined();
    expect(snapshotParts(rev).state.pages).toEqual([]);
    // The key itself stays required.
    expect(() => decodeRevision({ ...goodDelta, type: "snapshot", included: {}, state: { deleted: false, meta } })).toThrow();
  });

  it("rejects an unknown type and bad fields", () => {
    expect(() => decodeRevision(goodDelta)).not.toThrow();
    for (const [k, v] of [["type", "patch"], ["hlc", "1"], ["device", "A1B2C3D4"], ["seq", 0], ["seq", 1.5],
      ["seq", 9007199254740992], ["seq", "1"], ["noteId", "nope"], ["wall", "2026-10-04"], ["ops", {}]] as const) {
      expect(() => decodeRevision({ ...goodDelta, [k]: v }), `${k}: ${JSON.stringify(v)}`).toThrow(DecodeError);
    }
    for (const k of Object.keys(goodDelta)) {
      const missing: Record<string, unknown> = { ...goodDelta };
      delete missing[k];
      expect(() => decodeRevision(missing), k).toThrow(DecodeError);
    }
    expect(() => decodeRevision({ ...goodDelta, ops: [{ op: "frobnicate" }] })).toThrow(DecodeError);
  });

  it("rejects a wall whose offset leaves the writable years", () => {
    expect(() => decodeRevision({ ...goodDelta, wall: "0001-01-01T00:00:00+00:01" })).toThrow(DecodeError);
  });
});

describe("strokes and ops", () => {
  it("decodes the stroke wire shape", () => {
    const s = decodeStroke({
      id: "0D1C6A1E-9A44-4A6C-8A6B-0E2A0E9B1F3C", ink: { tool: "pen", color: "#1A1A1AFF", width: 2.5 },
      points: [[1.235, 2, 0, 3, 3, 1, 0, 0, 1.571]],
    }, "$");
    expect(s.id).toBe("0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c");
    expect(s.ink).toEqual({ tool: "pen", color: "#1A1A1AFF", width: 2.5 });
    expect(Array.from(s.points)).toEqual([1.235, 2, 0, 3, 3, 1, 0, 0, 1.571]);
    expect(s.transform).toBeUndefined();
  });

  it("reads an unknown tool as pen", () => {
    const s = decodeStroke({ id: testNote, ink: { tool: "laser", color: "#000000FF", width: 1 }, points: [] }, "$");
    expect(s.ink.tool).toBe("pen");
  });

  it("decodes every op the format defines", () => {
    const strokeId = "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3d";
    const wire = [
      { op: "addPage", page: { id: pageId, order: "a0", strokes: [] } },
      { op: "addStroke", page: pageId,
        stroke: { id: strokeId, ink: { tool: "marker", color: "#000000FF", width: 4 }, points: [[0, 0, 0, 4, 4, 1, 0, 0, 1.571]] } },
      { op: "removeStroke", page: pageId, strokeId },
      { op: "setPageOrder", pageId, order: "a1" },
      { op: "setPageRecognition", pageId,
        recognition: { engine: "pencilkit-27.0", text: "Lecture 3", words: [{ box: [52.5, 40, 96.25, 30.5], t: "Lecture" }] } },
      { op: "setPageRecognition", pageId, recognition: null },
      { field: "title", op: "setMeta", value: "Lecture 3" },
      { field: "tags", op: "setMeta", value: ["math", "fall"] },
      { field: "notebook", op: "setMeta", value: null },
      { field: "favorite", op: "setMeta", value: true },
      { field: "paper", op: "setMeta", value: { kind: "ruled" } },
      { field: "pageSize", op: "setMeta", value: { width: 595, height: 842, infinite: false } },
      { op: "removePage", pageId },
      { op: "deleteNote" }, { op: "restoreNote" },
    ];
    const points = new Float64Array([0, 0, 0, 4, 4, 1, 0, 0, 1.571]);
    expect(wire.map(decodeOne)).toEqual([
      op.addPage(pageId, "a0"),
      op.addStroke(pageId, { id: strokeId, ink: { tool: "marker", color: "#000000FF", width: 4 }, points }),
      op.removeStroke(pageId, strokeId),
      op.setPageOrder(pageId, "a1"),
      op.setPageRecognition(pageId, { engine: "pencilkit-27.0", text: "Lecture 3", words: [{ t: "Lecture", box: [52.5, 40, 96.25, 30.5] }] }),
      op.setPageRecognition(pageId, undefined),
      op.title("Lecture 3"),
      op.tags(["math", "fall"]),
      op.notebook(undefined),
      op.favorite(true),
      op.paper(defaultPaper("ruled")),
      op.pageSize({ width: 595, height: 842, infinite: false }),
      op.removePage(pageId),
      op.deleteNote(), op.restoreNote(),
    ]);
    // A missing notebook value reads like null.
    expect(decodeOne({ field: "notebook", op: "setMeta" })).toEqual(op.notebook(undefined));
    expect(() => decodeOne({ field: "colour", op: "setMeta", value: 1 })).toThrow(DecodeError);
    expect(() => decodeOne({ op: "setPageOrder", pageId })).toThrow(DecodeError);
  });

  it("decodes setPagePaper with a paper or null", () => {
    expect(decodeOne({ op: "setPagePaper", pageId, paper: { kind: "staff" } })).toEqual(op.setPagePaper(pageId, defaultPaper("staff")));
    expect(decodeOne({ op: "setPagePaper", pageId, paper: null })).toEqual(op.setPagePaper(pageId, undefined));
  });

  it("decodes the format's example state", () => {
    const rev = decodeRevision({
      ...goodDelta, type: "snapshot", included: {},
      state: {
        deleted: false,
        meta: { title: "Lecture 3", tags: ["math", "fall"], notebook: "School", favorite: false,
          created: "2026-10-04T16:20:00Z",
          paper: { kind: "ruled", spacing: 24, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" },
          pageSize: { width: 612, height: 792, infinite: false } },
        pages: [{ id: testNote, order: "a0", strokes: [] }],
      },
    });
    const { state } = snapshotParts(rev);
    expect(state.meta.title).toBe("Lecture 3");
    expect(paperKind(state.meta.paper)).toBe("ruled");
    expect(state.pages[0]?.order).toBe("a0");
    expect(formatRFC3339(state.meta.created)).toBe("2026-10-04T16:20:00.000Z");
  });
});

describe("paper", () => {
  it("decodes legacy paper and encodes it unchanged", () => {
    const json = { background: "#FFFFFFFF", kind: "ruled", lineColor: "#D0D8E8FF", spacing: 24 };
    const p = decodePaper(json, "$");
    expect(p).toEqual(defaultPaper("ruled"));
    expect(encodePaper(p)).toEqual(json); // no new keys for a default paper
    for (const kind of ["blank", "grid", "dot"]) {
      const j = { background: "#FFFFFFFF", kind, lineColor: "#D0D8E8FF", spacing: 30 };
      expect(encodePaper(decodePaper(j, "$"))).toEqual(j);
    }
  });

  it("fills missing fields with the kind's defaults", () => {
    const p = decodePaper({ kind: "marginRuled" }, "$");
    expect(p.marginLeft).toBe(72);
    expect(p.spacing).toBe(24);
    expect(p.lineWidth).toBe(0.5);
    expect(decodePaper({ kind: "staff" }, "$").staffSpacing).toBe(7);
  });

  it("renders an unknown kind as blank and keeps its name", () => {
    const json = { background: cream, kind: "hexagons", lineColor: "#D0D8E8FF", spacing: 10 };
    const p = decodePaper(json, "$");
    expect(paperKind(p)).toBe("blank");
    expect(p.kindName).toBe("hexagons");
    expect(p.background).toBe(cream);
    expect(encodePaper(p)).toEqual(json);
    const blank: Paper = { ...defaultPaper("blank"), spacing: 10, background: cream };
    expect(p).not.toEqual(blank);
    // Through an op.
    const fromOp = decodeOne({ op: "setMeta", field: "paper", value: json });
    expect(fromOp).toEqual(op.paper(p));
    // A note whose paper is unknown still opens.
    const rev = decodeRevision({
      ...goodDelta, type: "snapshot", included: {},
      state: { deleted: false, pages: [], meta: { title: "x", tags: [], favorite: false, created: "2026-10-04T16:20:00Z",
        paper: { kind: "future" }, pageSize: { width: 612, height: 792, infinite: false } } },
    });
    expect(paperKind(snapshotParts(rev).state.meta.paper)).toBe("blank");
  });

  it("round-trips a full paper", () => {
    const p: Paper = {
      kindName: "cornell", spacing: 30, background: cream, lineColor: "#01020380", lineWidth: 1.25, dotRadius: 1.5,
      marginLeft: 50, marginTop: 40, marginColor: "#000000FF", cueWidth: 200, summaryHeight: 90, staffSpacing: 9,
      staffGap: 50,
    };
    expect(decodePaper(encodePaper(p), "$")).toEqual(p);
  });

  it("rejects a paper without a kind or with a bad colour", () => {
    expect(() => decodePaper({ spacing: 24 }, "$")).toThrow(DecodeError);
    expect(() => decodePaper({ kind: "ruled", background: "white" }, "$")).toThrow(DecodeError);
    expect(() => decodePaper({ kind: "ruled", spacing: "24" }, "$")).toThrow(DecodeError);
  });
});

describe("colours", () => {
  it("parses #RRGGBB and #RRGGBBAA to uppercase #RRGGBBAA", () => {
    expect(parseColor("#1a1a1a")).toBe("#1A1A1AFF");
    expect(parseColor("#1A1A1AFF")).toBe("#1A1A1AFF");
    expect(parseColor("01020380")).toBe("#01020380");
    expect(parseColor("#FFF8E1")).toBe(cream);
    for (const bad of ["", "#", "#FFF", "#FFFFFFF", "#FFFFFFFFF", "#GGGGGG", "white", "#12 456", "##123456"]) {
      expect(parseColor(bad), bad).toBeUndefined();
    }
  });

  it("follows UInt32(_:radix:) on a leading sign", () => {
    expect(parseColor("#+FFFFF")).toBe("#0FFFFFFF");
    expect(parseColor("#-00000")).toBe("#000000FF");
    expect(parseColor("#-00001")).toBeUndefined();
    expect(parseColor("#+-0000")).toBeUndefined();
  });
});

describe("RFC 3339", () => {
  it("rejects long fractions and malformed dates without crashing", () => {
    expect(parseRFC3339("2026-10-05T13:20:16." + "9".repeat(800) + "22Z")).toBeUndefined();
    for (const bad of ["2026-10-05T13:20:4.9e-324Z", "2026-10-05T13:20:255Z", "2026-02-30T00:00:00Z", "2026-10-04T24:00:00Z",
      "2026-10-04T23:59:60Z", "0000-01-01T00:00:00Z", "2026-10-04 18:20:00Z", "2026-10-04T18:20:00",
      "2026-10-04T18:20:00.Z", "2026-10-04T18:20:00.1234567890Z", "2026-10-04T18:20:00+24:00", "",
      "2025-02-29T00:00:00Z", "2026-10-04T18:20:00z", "2026-10-04t18:20:00Z", "2026-10-04T18:20:00+0200",
      "2026-10-04T18:20:00+02:00Z", "２026-10-04T18:20:00Z"]) {
      expect(parseRFC3339(bad), bad).toBeUndefined();
    }
    expect(parseRFC3339("2026-10-04T18:20:00+02:00")).toBe(parseRFC3339("2026-10-04T16:20:00Z"));
    expect(parseRFC3339("2026-10-04T16:20:00.123456789Z")).toBe(parseRFC3339("2026-10-04T16:20:00.123Z"));
    expect(formatRFC3339(must(parseRFC3339("2024-02-29T00:00:00Z")))).toBe("2024-02-29T00:00:00.000Z");
    expect(parseRFC3339("2026-10-04T16:20:00.5Z")).toBe(Date.UTC(2026, 9, 4, 16, 20, 0, 500));
  });

  it("keeps offsets inside the writable years", () => {
    for (const s of ["0001-01-01T00:00:00+00:01", "0001-01-01T00:59:59.999+01:00", "9999-12-31T23:59:59-00:01",
      "9999-12-31T23:00:00-01:00"]) {
      expect(parseRFC3339(s), s).toBeUndefined();
    }
    expect(formatRFC3339(must(parseRFC3339("0001-01-01T01:00:00+01:00")))).toBe("0001-01-01T00:00:00.000Z");
    expect(formatRFC3339(must(parseRFC3339("9999-12-31T22:59:59.999-01:00")))).toBe("9999-12-31T23:59:59.999Z");
    expect(parseRFC3339("0001-01-01T00:00:00Z")).toBe(earliestMillis);
    expect(parseRFC3339("9999-12-31T23:59:59.999Z")).toBe(endMillis - 1);
  });

  it("agrees with the platform's date codec on millisecond dates", () => {
    // The Swift test compares with ISO8601DateFormatter from 1583 on; here JavaScript's Date.
    const rng = new SplitMix64(3339);
    for (let i = 0; i < 5000; i++) {
      const ms = rng.int(-12_000_000_000_000, 253_000_000_000_000);
      const ours = formatRFC3339(ms);
      expect(ours).toBe(new Date(ms).toISOString());
      expect(parseRFC3339(ours)).toBe(ms);
      expect(parseRFC3339(ours)).toBe(Date.parse(ours));
    }
  });
});
