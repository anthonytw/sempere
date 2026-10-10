// The viewer's in-memory cache of decrypted notes (src/ui/notecache.ts).

import { describe, expect, it } from "vitest";
import { type LoadedNote } from "../src/vault/library.ts";
import { NoteCache } from "../src/ui/notecache.ts";

const note = (id: string, modified?: number): LoadedNote => {
  const n: LoadedNote = { id, failures: [], revisionCount: 1, hasAttachments: false };
  if (modified !== undefined) n.modified = modified;
  return n;
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
});
