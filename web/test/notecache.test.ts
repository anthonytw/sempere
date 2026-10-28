// The viewer's in-memory cache of decrypted notes (src/ui/notecache.ts).

import { describe, expect, it } from "vitest";
import { type LoadedNote } from "../src/vault/library.ts";
import { type NoteState } from "../src/format/model.ts";
import { NoteCache, estimateBytes } from "../src/ui/notecache.ts";

const note = (id: string, modified?: number): LoadedNote => {
  const n: LoadedNote = { id, failures: [], revisionCount: 1, hasAttachments: false };
  if (modified !== undefined) n.modified = modified;
  return n;
};

/** A note whose one stroke holds `points` control points (72 bytes each). */
const inked = (id: string, points: number, modified?: number): LoadedNote => {
  const state = {
    deleted: false,
    meta: { title: id, tags: [] },
    pages: [{ id: "p", order: "a", items: [], strokes: [{ id: "s", ink: {}, points: new Float64Array(points * 9) }] }],
    tagSet: { instances: [], removed: [] },
    recordings: [],
  } as unknown as NoteState;
  return { ...note(id, modified), state };
};

describe("note cache", () => {
  it("evicts the least recently used note, and a read counts as a use", () => {
    const c = new NoteCache(3);
    for (const id of ["a", "b", "c"]) c.set(id, note(id));
    expect(c.get("a")?.id).toBe("a");
    c.set("d", note("d"));
    expect(c.get("b")).toBeUndefined();
    expect(["a", "c", "d"].map((id) => c.get(id)?.id)).toEqual(["a", "c", "d"]);
    expect(c.size).toBe(3);
  });

  it("keeps listed notes behind opened ones, the newest when full", () => {
    const c = new NoteCache(3);
    c.set("a", note("a"));
    c.offer(note("x", 10));
    c.offer(note("y", 30));
    expect(c.size).toBe(3);
    c.offer(note("z", 20));                       // replaces x, the oldest listed note
    expect(c.get("x")).toBeUndefined();
    c.offer(note("w", 5));                        // older than every listed note: not kept
    expect(c.get("w")).toBeUndefined();
    c.set("b", note("b"));                         // an opened note pushes a listed one out first
    expect(c.get("a")?.id).toBe("a");
    expect([c.get("y")?.id, c.get("z")?.id].filter(Boolean).length).toBe(1);
  });

  it("never lets a listed note push out an opened one", () => {
    const c = new NoteCache(2);
    c.set("a", note("a", 1));
    c.set("b", note("b", 2));
    c.offer(note("x", 100));
    expect(c.get("x")).toBeUndefined();
    expect([c.get("a")?.id, c.get("b")?.id]).toEqual(["a", "b"]);
  });

  it("an opened listed note becomes an ordinary entry", () => {
    const c = new NoteCache(2);
    c.offer(note("x", 1));
    expect(c.get("x")?.id).toBe("x");             // opened
    c.offer(note("y", 5));
    c.offer(note("z", 9));                        // replaces y, never x
    expect(c.get("x")?.id).toBe("x");
    expect(c.get("y")).toBeUndefined();
    expect(c.get("z")?.id).toBe("z");
  });

  it("keeps no note that failed to load, so the next open tries again (bug audit B14)", () => {
    const c = new NoteCache(4);
    const failed: LoadedNote = { id: "a", error: "network down", failures: [], revisionCount: 0, hasAttachments: false };
    c.set("a", failed);
    expect(c.get("a")).toBeUndefined();
    const partial = note("b", 1);
    partial.failures = [{ file: "notes/b/r1", message: "network down" }];
    c.set("b", partial);
    expect(c.get("b")).toBeUndefined();
    c.offer({ ...partial, id: "c" });
    expect(c.get("c")).toBeUndefined();
    // A listed note whose newer revisions now fail to read is dropped, not kept stale.
    c.offer(note("d", 1));
    c.offer({ ...partial, id: "d", modified: 2 });
    expect(c.get("d")).toBeUndefined();
    // A failed open forgets what was kept for that note.
    c.set("e", note("e"));
    c.set("e", { ...failed, id: "e" });
    expect(c.get("e")).toBeUndefined();
  });

  it("estimates a note by the points of its strokes, so a drawn note costs more than an empty one", () => {
    expect(estimateBytes(inked("a", 1000))).toBeGreaterThan(72_000);
    expect(estimateBytes(inked("a", 1000))).toBeGreaterThan(10 * estimateBytes(note("a")));
  });

  it("is bounded by bytes as well as by count: drawn notes push out the least recently used", () => {
    const one = estimateBytes(inked("a", 10_000));
    const c = new NoteCache(50, Math.floor(one * 2.5));
    for (const id of ["a", "b", "c"]) c.set(id, inked(id, 10_000));
    expect(c.size).toBe(2);                       // far below the count limit of 50
    expect(c.get("a")).toBeUndefined();
    expect(c.bytes).toBeLessThanOrEqual(Math.floor(one * 2.5));
    expect(c.get("b")?.id).toBe("b");
    c.set("d", inked("d", 10_000));               // b was just used: c goes
    expect(c.get("c")).toBeUndefined();
    expect([c.get("b")?.id, c.get("d")?.id]).toEqual(["b", "d"]);
  });

  it("keeps no single note that is over the whole budget, and forgets the one it replaces", () => {
    const small = estimateBytes(inked("a", 100));
    const c = new NoteCache(8, small * 3);
    c.set("a", inked("a", 100));
    c.set("a", inked("a", 100_000));
    expect(c.get("a")).toBeUndefined();
    expect(c.bytes).toBe(0);
    c.offer(inked("x", 100_000, 5));
    expect(c.size).toBe(0);
  });

  it("counts a replaced or dropped note once: the total returns to zero", () => {
    const c = new NoteCache(8, 1 << 30);
    c.set("a", inked("a", 100));
    c.set("a", inked("a", 200));
    c.offer(inked("x", 300, 1));
    c.offer(inked("x", 400, 2));                  // a listed note re-offered: its cost is updated
    expect(c.bytes).toBe(estimateBytes(inked("a", 200)) + estimateBytes(inked("x", 400)));
    c.clear();
    expect(c.bytes).toBe(0);
  });

  it("makes room for a listed note from older listed notes by bytes, and never from opened ones", () => {
    const one = estimateBytes(inked("a", 10_000));
    const c = new NoteCache(50, Math.floor(one * 2.5));
    c.set("a", inked("a", 10_000));
    c.offer(inked("x", 10_000, 10));
    c.offer(inked("y", 10_000, 20));              // over the budget: replaces x, the older listed note
    expect(c.get("x")).toBeUndefined();
    expect(c.get("y")?.id).toBe("y");
    const d = new NoteCache(50, Math.floor(one * 1.5));
    d.set("a", inked("a", 10_000));
    d.offer(inked("z", 10_000, 99));              // only an opened note could make room: not kept
    expect(d.get("z")).toBeUndefined();
    expect(d.get("a")?.id).toBe("a");
  });
});
