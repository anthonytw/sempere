// Read-only access to content of a newer format version (format.md §7),
// ported from Tests/SempereTests/NewerFormatTests.swift: the committed
// `newer.sempere` fixture opens, newer revisions decode leniently, and what
// was skipped is reported. The reconstructed notes match the Swift CLI's
// export (test/golden/newer, web/scripts/golden.sh).

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { encodeState, decodeRevision } from "../src/format/model.ts";
import { countName, emptyNewer, majorOf, manifestReadOnlyReasons, maxNameLength, maxNames, newerSummary, otherName } from "../src/format/newer.ts";
import { formatRFC3339 } from "../src/format/rfc3339.ts";
import { loadNote, summarize } from "../src/vault/library.ts";
import { UnlockedVault, VaultError, parseManifest, readOnlyReasons } from "../src/vault/vault.ts";
import { NodeDirSource, fixtures, golden, sampleIdentity } from "./support.ts";

const mixed = "33333333-3333-4333-8333-333333333333";
const snapshot = "44444444-4444-4444-8444-444444444444";
const body2 = "55555555-5555-4555-8555-555555555555";

function canonical(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(canonical);
  if (v && typeof v === "object") {
    return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canonical((v as Record<string, unknown>)[k])]));
  }
  return v;
}

const envelope = (extra: Record<string, unknown>): Record<string, unknown> => ({
  type: "delta", noteId: mixed, device: "0e0e0e0e", seq: 1, hlc: "17911308020000000",
  wall: "2026-10-04T16:20:02.000Z", app: "test", ...extra,
});

describe("format identifiers", () => {
  it("parses sempere/<major>", () => {
    expect(majorOf("sempere/1")).toBe(1);
    expect(majorOf("sempere/2")).toBe(2);
    for (const bad of ["sempere/0", "sempere/01", "sempere/", "sempere/1.1", "Sempere/2", "sempere/1000000000", ""]) {
      expect(majorOf(bad)).toBeUndefined();
    }
  });

  it("opens a later major's manifest and reports why it is read-only", () => {
    const m = (format: string, features?: string[]): Uint8Array => new TextEncoder().encode(JSON.stringify({
      format, vaultId: "5a3b1e00-1000-4000-8000-000000000002", created: "2026-10-04T16:20:00Z",
      recipients: [{ key: "age1future1qqqq", label: "", added: "2026-10-04T16:20:00Z" }], vaultSecret: "x",
      ...(features ? { features } : {}),
    }));
    expect(readOnlyReasons(parseManifest(m("sempere/2", ["tables"])))).toHaveLength(2);
    expect(readOnlyReasons(parseManifest(m("sempere/2", [])))).toHaveLength(1);
    // This version defines no extension (format.md §2): any feature is newer content.
    expect(manifestReadOnlyReasons("sempere/1", [])).toEqual([]);
    expect(manifestReadOnlyReasons("sempere/1", ["attachments"])).toHaveLength(1);
    expect(() => parseManifest(m("sempere/1"))).toThrow(VaultError);
    for (const bad of ["sempere/0", "other/2"]) {
      expect(() => parseManifest(m(bad))).toThrow(expect.objectContaining({ code: "unsupportedFormat" }));
    }
  });
});

describe("newer revisions", () => {
  it("skip unknown and invalid ops only when marked newer", () => {
    const ops = [{ op: "teleport" }, { op: "setMeta", field: "title", value: "v2" }, { op: "setMeta", field: "color", value: 1 }];
    expect(() => decodeRevision(envelope({ ops }))).toThrow();
    const rev = decodeRevision(envelope({ format: "sempere/2", ops }));
    expect(rev.body.type === "delta" && rev.body.ops.length).toBe(1);
    expect(rev.newer?.skippedOps).toEqual({ teleport: 1, "setMeta.color": 1 });
    expect(decodeRevision(envelope({ format: "sempere/1", ops: [] })).newer).toBeUndefined();
    expect(decodeRevision(envelope({ features: [], ops: [] })).newer).toBeUndefined();
    expect(decodeRevision(envelope({ features: ["tables"], ops: [] })).newer?.features).toEqual({ tables: 1 });
    for (const bad of [{ format: "2" }, { format: 2 }, { format: "sempere/0" }, { features: "x" }, { features: [1] }]) {
      expect(() => decodeRevision(envelope({ ...bad, ops: [] }))).toThrow();
    }
  });

  it("bound the names they report (format.md §9)", () => {
    const ops = Array.from({ length: 200 }, (_, i) => ({ op: `op${i}${"x".repeat(100)}` }));
    const rev = decodeRevision(envelope({ format: "sempere/2", ops: [...ops, 42, null, { op: 7 }] }));
    const names = rev.newer?.skippedOps ?? {};
    expect(Object.keys(names).length).toBeLessThanOrEqual(maxNames + 1);
    expect(Object.keys(names).every((k) => [...k].length <= maxNameLength)).toBe(true);
    expect(Object.values(names).reduce((a, b) => a + b, 0)).toBe(203);
    const map: Record<string, number> = {};
    for (let i = 0; i < 100; i++) countName(map, `n${i}`);
    expect(map[otherName]).toBe(100 - maxNames);
  });

  it("count names that Object.prototype holds like any other", () => {
    const names = ["constructor", "__proto__", "toString", "hasOwnProperty", "constructor"];
    const rev = decodeRevision(envelope({ format: "sempere/2", ops: names.map((op) => ({ op })) }));
    const skipped = rev.newer?.skippedOps ?? {};
    expect(Object.keys(skipped).sort()).toEqual(["__proto__", "constructor", "hasOwnProperty", "toString"]);
    expect(Object.values(skipped).reduce((a, b) => a + b, 0)).toBe(5);
    expect(Object.hasOwn(skipped, "constructor") && skipped.constructor).toBe(2);
    expect(newerSummary(rev.newer ?? emptyNewer())).toContain("5 ops skipped (__proto__ ×1, constructor ×2, hasOwnProperty ×1, toString ×1)");
    expect(Object.getPrototypeOf(skipped)).toBe(Object.prototype);
  });
});

describe("newer.sempere fixture", async () => {
  const source = new NodeDirSource(join(fixtures, "newer.sempere"));
  const manifest = parseManifest(await source.read("vault.json", 1 << 24));
  const vault = await UnlockedVault.unlock(manifest, sampleIdentity());

  it("is read-only for its format and features", () => {
    expect(manifest.format).toBe("sempere/2");
    expect(readOnlyReasons(manifest)).toHaveLength(2);
  });

  it("shows the known parts of a newer delta", async () => {
    const note = await loadNote(source, vault, mixed);
    expect(note.failures).toEqual([]);
    expect(note.newer?.skippedOps).toEqual({ moveStroke: 1, "setMeta.color": 1, addStroke: 1 });
    expect(note.state?.meta.title).toBe("Newer fixture, edited by v2");
    expect(note.state?.pages[0]?.strokes.map((s) => s.id)).toEqual(
      ["f1c70000-0000-4000-8000-000000000101", "f1c70000-0000-4000-8000-000000000102"]);
    expect(summarize(note).newer).toBe(true);
    if (!note.newer) throw new Error("no newer content");
    expect(newerSummary(note.newer)).toContain("3 ops skipped");
  });

  it("skips undecodable snapshot elements", async () => {
    const note = await loadNote(source, vault, snapshot);
    expect(note.newer?.skippedElements).toBe(2);
    expect(note.newer?.features).toEqual({ tables: 1 });
    expect(note.state?.pages.map((p) => p.strokes.length)).toEqual([1]);
  });

  it("reports a later body version as newer and shows the rest", async () => {
    const note = await loadNote(source, vault, body2);
    expect(note.failures).toHaveLength(1);
    expect(note.failures[0]?.message).toContain("newer version");
    expect(note.newer?.unreadable).toBe(1);
    expect(note.state?.pages[0]?.strokes).toHaveLength(1);
  });

  for (const id of [mixed, snapshot, body2]) {
    it(`reconstructs ${id} like the Swift CLI`, async () => {
      const note = await loadNote(source, vault, id);
      if (!note.state) throw new Error(note.error);
      const want = JSON.parse(readFileSync(join(golden, "newer", `${id}.json`), "utf8")) as unknown;
      expect(canonical(encodeState(note.state, formatRFC3339))).toEqual(canonical(want));
    });
  }
});
