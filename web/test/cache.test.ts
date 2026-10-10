// The ciphertext cache (docs/web-viewer.md "Opening fast"): write-once paths
// only, LRU within a size bound, eviction of files gone from the listing, a
// failing cached copy dropped and fetched again, and the IndexedDB store.

import { IDBFactory } from "fake-indexeddb";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { CachingSource, FileCache, IndexedDBFileStore, MemoryFileStore, cacheNamespace, isCacheablePath, touchInterval } from "../src/vault/cache.ts";
import { loadNote } from "../src/vault/library.ts";
import { type VaultSource } from "../src/vault/source.ts";
import { NodeDirSource, fixtures, unlockFixture } from "./support.ts";

const lecture = "11111111-1111-4111-8111-111111111111";
const blobName = "a".repeat(64);
const defaultLimits = { maxBytes: 1 << 20, maxEntryBytes: 1 << 20 };

/** Counts what reaches the network. */
export class CountingSource implements VaultSource {
  readonly reads: string[] = [];
  readonly label: string;
  constructor(readonly inner: VaultSource) {
    this.label = inner.label;
  }
  read(path: string, max: number) {
    this.reads.push(path);
    return this.inner.read(path, max);
  }
  listNotes() {
    return this.inner.listNotes();
  }
  listRevisions(id: string) {
    return this.inner.listRevisions(id);
  }
}

describe("ciphertext cache", () => {
  it("caches only write-once vault files", () => {
    expect(isCacheablePath(`notes/${lecture}/17911308010000000-a1b2c3d4-1.delta.age`)).toBe(true);
    expect(isCacheablePath(`notes/${lecture}/att/${blobName}.image.age`)).toBe(true);
    for (const p of ["vault.json", "rewrap-journal.json", "sempere-index.json", "sempere-summaries.sealed",
      `notes/${lecture}/notes.txt`, "notes/7E57C0DE-0000-4000-8000-000000000001/17911308010000000-a1b2c3d4-1.delta.age",
      `notes/${lecture}/att/x.image.age`, `notes/${lecture}/att/${blobName}.image.age/x`, "inbox/x.capture.age"]) {
      expect(isCacheablePath(p), p).toBe(false);
    }
  });

  it("evicts least recently used files beyond its bound and skips files over the entry limit", async () => {
    let clock = 0;
    const cache = new FileCache(new MemoryFileStore(), { maxBytes: 300, maxEntryBytes: 150 }, () => ++clock);
    await cache.put("a", new Uint8Array(100));
    await cache.put("b", new Uint8Array(100));
    await cache.put("c", new Uint8Array(100));
    expect(await cache.get("a")).toBeDefined();   // a is now the most recent
    await cache.put("d", new Uint8Array(100));     // over 300: b goes
    expect((await cache.keys("")).sort()).toEqual(["a", "c", "d"]);
    await cache.put("big", new Uint8Array(151));
    expect(await cache.get("big")).toBeUndefined();
    expect(await cache.size()).toEqual({ files: 3, bytes: 300 });
    await cache.clear();
    expect(await cache.size()).toEqual({ files: 0, bytes: 0 });
  });

  it("evicts in recency order across reads, rewrites and a reload", async () => {
    let clock = 1000;
    const store = new MemoryFileStore();
    const cache = new FileCache(store, { maxBytes: 400, maxEntryBytes: 150 }, () => ++clock);
    for (const k of ["a", "b", "c", "d"]) await cache.put(k, new Uint8Array(100));
    await cache.get("b");
    await cache.put("a", new Uint8Array(100));   // rewritten: now the most recent
    await cache.put("e", new Uint8Array(100));   // c is the least recently used
    expect((await cache.keys("")).sort()).toEqual(["a", "b", "d", "e"]);
    // A new tab starts from the stored times: d, then b (its read was not written, being recent), a, e.
    const again = new FileCache(store, { maxBytes: 300, maxEntryBytes: 150 }, () => ++clock);
    await again.put("f", new Uint8Array(100));
    expect((await again.keys("")).sort()).toEqual(["a", "e", "f"]);
  });

  it("writes a read's time to the store only when the stored one is stale", async () => {
    let clock = 0;
    const store = new MemoryFileStore();
    const cache = new FileCache(store, defaultLimits, () => clock);
    await cache.put("a", new Uint8Array(1));
    clock = touchInterval;
    await cache.get("a");
    expect(store.files.get("a")?.used).toBe(0);
    clock = touchInterval + 1;
    await cache.get("a");
    expect(store.files.get("a")?.used).toBe(touchInterval + 1);
    clock = touchInterval + 2;
    await cache.get("a");
    expect(store.files.get("a")?.used).toBe(touchInterval + 1);
  });

  it("serves a second read from the cache and drops a file that fails to verify", async () => {
    const dir = join(fixtures, "sample.sempere");
    const { vault } = await unlockFixture(dir);
    const net = new CountingSource(new NodeDirSource(dir));
    const store = new MemoryFileStore();
    const src = new CachingSource(net, new FileCache(store), "test\nvault");
    const first = await loadNote(src, vault, lecture);
    expect(first.failures).toEqual([]);
    const fetched = net.reads.length;
    expect(fetched).toBe(5);
    expect((await loadNote(src, vault, lecture)).state).toEqual(first.state);
    expect(net.reads.length).toBe(fetched);   // nothing downloaded again

    // A damaged cached copy is evicted and fetched again: the note still reads cleanly.
    const key = [...store.files.keys()][0] ?? "";
    const bad = store.files.get(key)?.bytes.slice() ?? new Uint8Array();
    bad[bad.length - 1] = (bad[bad.length - 1] ?? 0) ^ 1;
    store.files.set(key, { bytes: bad, used: 0 });
    const again = await loadNote(src, vault, lecture);
    expect(again.failures).toEqual([]);
    expect(net.reads.length).toBe(fetched + 1);
  });

  it("evicts what the listing no longer has", async () => {
    const store = new MemoryFileStore();
    const cache = new FileCache(store);
    const src = new CachingSource(new NodeDirSource(join(fixtures, "sample.sempere")), cache, "ns");
    const other = "22222222-2222-4222-8222-222222222222";
    for (const p of [`notes/${lecture}/17911308010000000-a1b2c3d4-1.delta.age`, `notes/${lecture}/17911308020000000-99ee00ff-1.delta.age`,
      `notes/${other}/17911308060000000-a1b2c3d4-1.delta.age`, `notes/${other}/att/${blobName}.image.age`]) {
      await cache.put(`ns\n${p}`, new Uint8Array([1]));
    }
    await cache.put(`another vault\nnotes/${other}/17911308060000000-a1b2c3d4-1.delta.age`, new Uint8Array([1]));
    // The second revision was compacted away and the other note deleted.
    expect(await src.retain(new Map([[lecture, ["17911308010000000-a1b2c3d4-1.delta.age"]]]))).toBe(3);
    expect(await cache.keys("")).toEqual([`ns\nnotes/${lecture}/17911308010000000-a1b2c3d4-1.delta.age`,
      `another vault\nnotes/${other}/17911308060000000-a1b2c3d4-1.delta.age`]);
  });

  // Security review 2026-10, P4: a copy cached before a recipient change (or
  // while its rewrap ran) is encrypted to the old recipients, a removed key
  // among them; the new key state's namespace drops it.
  it("drops copies cached under an earlier key state of the same vault", async () => {
    const cache = new FileCache(new MemoryFileStore());
    const path = `notes/${lecture}/17911308010000000-a1b2c3d4-1.delta.age`;
    const before = await cacheNamespace("https://x/v", "vault-1", "sealed secret 1");
    const journal = new TextEncoder().encode("{}");
    const during = await cacheNamespace("https://x/v", "vault-1", "sealed secret 2", journal);
    const after = await cacheNamespace("https://x/v", "vault-1", "sealed secret 2");
    expect(new Set([before, during, after]).size).toBe(3);
    expect(await cacheNamespace("https://x/v", "vault-1", "sealed secret 1")).toBe(before);
    expect(before.startsWith("https://x/v\nvault-1\n")).toBe(true);
    await cache.put(`${before}\n${path}`, new Uint8Array([1]));
    await cache.put(`https://x/v\nvault-1\n${path}`, new Uint8Array([2]));   // written before key states
    await cache.put(`https://x/v\nvault-2\n${path}`, new Uint8Array([3]));   // another vault: kept
    await cache.put(`https://x/v2\nvault-1\n${path}`, new Uint8Array([4]));  // another URL: kept
    const inner: VaultSource = {
      label: "x", listNotes: () => Promise.resolve([]), listRevisions: () => Promise.resolve([]),
      read: () => Promise.resolve(new Uint8Array([9])),
    };
    const src = new CachingSource(inner, cache, during);
    await src.read(path, 10);
    expect(await src.dropOtherNamespaces()).toBe(2);
    expect((await cache.keys("")).sort()).toEqual([`${during}\n${path}`, `https://x/v\nvault-2\n${path}`,
      `https://x/v2\nvault-1\n${path}`].sort());
    // The rewrap finishes: what was cached during it goes too.
    expect(await new CachingSource(inner, cache, after).dropOtherNamespaces()).toBe(1);
  });

  it("keeps a streamed file only once it was read to the end", async () => {
    const cache = new FileCache(new MemoryFileStore());
    const path = `notes/${lecture}/att/${blobName}.image.age`;
    const inner: VaultSource = {
      label: "x", listNotes: () => Promise.resolve([]), listRevisions: () => Promise.resolve([]),
      read: () => Promise.resolve(new Uint8Array([1, 2, 3])),
    };
    const src = new CachingSource(inner, cache, "ns");
    await (await src.stream(path, 10)).cancel();
    expect(await cache.keys("")).toEqual([]);
    expect(new Uint8Array(await new Response(await src.stream(path, 10)).arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]));
    expect(await cache.keys("")).toEqual([`ns\n${path}`]);
    expect(new Uint8Array(await new Response(await src.stream(path, 10)).arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]));
    expect(cache.stats).toEqual({ hits: 1, misses: 2 });
  });

  it("stores ciphertext in IndexedDB across tabs", async () => {
    const factory = new IDBFactory();
    const a = await IndexedDBFileStore.open(factory);
    await a.put("k1", new Uint8Array([1, 2]), 10);
    await a.put("k2", new Uint8Array([3]), 20);
    await a.touch("k1", 30);
    await a.delete(["k2"]);
    a.close();
    const b = await IndexedDBFileStore.open(factory);
    expect(await b.entries()).toEqual([{ key: "k1", size: 2, used: 30 }]);
    expect(await b.get("k1")).toEqual(new Uint8Array([1, 2]));
    expect(await b.get("k2")).toBeUndefined();
    const cache = new FileCache(b);
    expect(await cache.size()).toEqual({ files: 1, bytes: 2 });
    await cache.clear();
    expect(await b.entries()).toEqual([]);
    b.close();
    await IndexedDBFileStore.destroy(factory);
  });
});
