// Timing checks of the viewer's hot paths at a realistic vault size. They print numbers and assert
// nothing about time, so they are skipped unless SEMPERE_WEB_PERF=1 (`SEMPERE_WEB_PERF=1 npx vitest run
// test/perf.test.ts`); correctness of the same code is covered by the ordinary tests.

import { describe, expect, it } from "vitest";
import { CachingSource, FileCache, MemoryFileStore } from "../src/vault/cache.ts";
import { type VaultSource } from "../src/vault/source.ts";
import { type SearchableNote, isWithinNotebook, notebookCounts, notebookTree, refinesQuery, search } from "../src/format/search.ts";

const enabled = process.env.SEMPERE_WEB_PERF === "1";

/** A deterministic pseudo-random generator (mulberry32). */
function rng(seed: number): () => number {
  let a = seed;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const vocabulary = ["the", "energy", "momentum", "café", "Straße", "notes", "lecture", "integral", "résumé", "vector",
  "matrix", "über", "field", "proof", "lemma", "theorem", "graph", "naïve", "data", "model"];

function text(r: () => number, length: number): string {
  const out: string[] = [];
  let n = 0;
  while (n < length) {
    const w = vocabulary[Math.floor(r() * vocabulary.length)] ?? "x";
    out.push(w);
    n += w.length + 1;
  }
  return out.join(" ");
}

function vault(notes: number, pages: number, pageLength: number): SearchableNote[] {
  const r = rng(1);
  return Array.from({ length: notes }, (_, i) => ({
    id: `n${i}`, title: `Note ${i} ${text(r, 20)}`, notebook: `School/Term ${i % 10}/Course ${i % 37}`,
    tags: [`tag${i % 50}`, "work"], modified: i,
    pageTexts: Array.from({ length: pages }, (_, p) => ({ number: p + 1, text: text(r, pageLength) })),
  }));
}

function time(label: string, f: () => unknown): number {
  const t0 = performance.now();
  f();
  const ms = performance.now() - t0;
  console.log(`PERF ${label}: ${ms.toFixed(1)} ms`);
  return ms;
}

describe.skipIf(!enabled)("perf", () => {
  it("search over 2,000 notes × 10 pages × 1 KB", () => {
    const notes = vault(2000, 10, 1000);
    let hits = 0;
    time("search first query", () => (hits = search("momentum cafe", notes).length));
    time("search second query", () => search("momentum cafe x", notes));
    time("search typing 'theorem' one letter at a time", () => {
      for (let k = 1; k <= "theorem".length; k++) search(`lemma ${"theorem".slice(0, k)}`, notes);
    });
    time("search typing 'theorem', narrowing to the last hits (as the app does)", () => {
      let last = "", ids: Set<string> | undefined;
      for (let k = 1; k <= "theorem".length; k++) {
        const q = `lemma ${"theorem".slice(0, k)}`;
        const from = ids && refinesQuery(last, q) ? notes.filter((n) => ids?.has(n.id)) : notes;
        ids = new Set(search(q, from).map((h) => h.id));
        last = q;
      }
    });
    expect(hits).toBeGreaterThan(0);
  }, 600_000);

  it("sidebar notebook counts, 5,000 notes in about 100 nested notebooks", () => {
    const names = Array.from({ length: 5000 }, (_, i) => `School/Term ${i % 10}/Course ${i % 9}`);
    const walk = (nodes: ReturnType<typeof notebookTree>): string[] => nodes.flatMap((n) => [n.path, ...walk(n.children)]);
    let paths: string[] = [];
    time("notebookTree", () => (paths = walk(notebookTree(names))));
    console.log(`PERF (${paths.length} notebooks)`);
    let before: number[] = [], after: number[] = [];
    time("counts, one filter per notebook (before)", () => (before = paths.map((p) => names.filter((n) => isWithinNotebook(n, p)).length)));
    time("counts, notebookCounts (after)", () => {
      const c = notebookCounts(names);
      after = paths.map((p) => c.get(p) ?? 0);
    });
    expect(after).toEqual(before);
  }, 600_000);

  it("cache puts with a full index of 100,000 files", async () => {
    let clock = 0;
    const cache = new FileCache(new MemoryFileStore(), { maxBytes: 100_000 * 10, maxEntryBytes: 100 }, () => ++clock);
    const bytes = new Uint8Array(10);
    for (let i = 0; i < 100_000; i++) await cache.put(`k${i}`, bytes);
    const t0 = performance.now();
    for (let i = 0; i < 1000; i++) await cache.put(`n${i}`, bytes);
    console.log(`PERF 1,000 puts over a full cache: ${(performance.now() - t0).toFixed(1)} ms`);
    expect((await cache.size()).files).toBe(100_000);
  }, 600_000);

  it("retain over 300 notes × 300 cached revisions", async () => {
    const cache = new FileCache(new MemoryFileStore(), { maxBytes: 1 << 30, maxEntryBytes: 100 });
    const ns = "https://example\nvault\nkey";
    const listing = new Map<string, string[]>();
    const bytes = new Uint8Array(1);
    for (let n = 0; n < 300; n++) {
      const id = `${n}`.padStart(8, "0") + "-0000-4000-8000-000000000000";
      const files = Array.from({ length: 300 }, (_, r) => `${17911308010000000 + r}-a1b2c3d4-${r}.delta.age`);
      listing.set(id, files);
      for (const f of files) await cache.put(`${ns}\nnotes/${id}/${f}`, bytes);
    }
    const src = new CachingSource({} as VaultSource, cache, ns);
    const t0 = performance.now();
    const dropped = await src.retain(listing);
    console.log(`PERF retain of 90,000 cached revisions: ${(performance.now() - t0).toFixed(1)} ms`);
    expect(dropped).toBe(0);
  }, 600_000);
});
