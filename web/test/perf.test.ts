// Timing checks of the viewer's hot paths at a realistic vault size. They print numbers and assert
// nothing about time, so they are skipped unless SEMPERE_WEB_PERF=1 (`SEMPERE_WEB_PERF=1 npx vitest run
// test/perf.test.ts`); correctness of the same code is covered by the ordinary tests.

import { describe, expect, it } from "vitest";
import { type SearchableNote, refinesQuery, search } from "../src/format/search.ts";

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
});
