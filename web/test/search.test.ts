// Ports of Tests/SempereTests/NoteSearchTests.swift and NotebookTests.swift.

import { describe, expect, it } from "vitest";
import {
  type PageTextEntry, type SearchableNote, canonicalNotebook, equationMarker, fold, foldText, isWithinNotebook, maxWords,
  notebookComponents, notebookTree, pageSnippet, refinesQuery, search,
} from "../src/format/search.ts";

let counter = 0;
function note(title: string, o: { notebook?: string; tags?: string[]; pages?: string[]; modified?: number } = {}): SearchableNote {
  const n: SearchableNote = {
    id: `n${counter++}`, title, tags: o.tags ?? [], modified: o.modified ?? 0,
    pageTexts: (o.pages ?? []).flatMap((t, i) => (t ? [{ number: i + 1, text: t }] : [])),
  };
  if (o.notebook !== undefined) n.notebook = o.notebook;
  return n;
}

function matched(hit: { snippet?: { text: string; matches: [number, number][] } }): string[] {
  const s = hit.snippet;
  return s ? s.matches.map(([a, b]) => s.text.slice(a, b)) : [];
}

describe("search", () => {
  it("finds handwriting and names the page", () => {
    const a = note("Physics", { pages: ["Newton's laws", "", "Kinetic energy and momentum"] });
    const b = note("Chemistry", { pages: ["Periodic table"] });
    const hits = search("momentum", [a, b]);
    expect(hits.map((h) => h.id)).toEqual([a.id]);
    expect(hits[0]?.page?.number).toBe(3);
    expect(hits[0]?.fields).toEqual(["text"]);
    expect(matched(hits[0] ?? {})).toEqual(["momentum"]);
  });

  it("does not trap on a note listed twice", () => {
    const a = note("Physics", { pages: ["momentum"] });
    expect(search("momentum", [a, a]).map((h) => h.id)).toEqual([a.id, a.id]);
  });

  it("ignores case, accents and width", () => {
    const a = note("Reunión", { pages: ["Café con leche", "ＦＵＬＬ width"] });
    expect(search("reunion", [a])).toHaveLength(1);
    expect(search("CAFE", [a])[0]?.page?.number).toBe(1);
    expect(search("full", [a])[0]?.page?.number).toBe(2);
    expect(matched(search("cafe", [a])[0] ?? {})).toEqual(["Café"]);
  });

  it("needs every word, across fields", () => {
    const a = note("Linear algebra", { notebook: "School/Math", tags: ["exam"], pages: ["eigenvalues of a matrix"] });
    const b = note("Cooking", { pages: ["matrix of flavours"] });
    expect(search("matrix eigenvalues", [a, b]).map((h) => h.id)).toEqual([a.id]);
    const hit = search("linear exam math matrix", [a, b]);
    expect(hit.map((h) => h.id)).toEqual([a.id]);
    expect(hit[0]?.fields).toEqual(["title", "tag", "notebook", "text"]);
    expect(search("matrix unicorn", [a, b])).toEqual([]);
    expect(search("   ", [a])).toEqual([]);
    expect(search("", [a])).toEqual([]);
  });

  it("matches #words against tags only", () => {
    const tagged = note("A", { tags: ["Physics"] });
    const titled = note("Physics notes", { pages: ["physics"] });
    expect(search("#physics", [tagged, titled]).map((h) => h.id)).toEqual([tagged.id]);
    expect(search("#phys", [tagged, titled]).map((h) => h.id)).toEqual([tagged.id]);
    expect(new Set(search("physics", [tagged, titled]).map((h) => h.id))).toEqual(new Set([tagged.id, titled.id]));
    expect(search("#", [tagged])).toEqual([]);
  });

  it("ranks title over tag over notebook over text, then newest", () => {
    const text = note("Misc", { pages: ["history of art"], modified: 100 });
    const nb = note("Misc 2", { notebook: "History", modified: 100 });
    const tag = note("Misc 3", { tags: ["history"], modified: 100 });
    const title = note("History", { modified: 0 });
    expect(search("history", [text, nb, tag, title]).map((h) => h.id)).toEqual([title.id, tag.id, nb.id, text.id]);
    const old = note("Same", { modified: 10 }), recent = note("Same", { modified: 20 });
    expect(search("same", [old, recent]).map((h) => h.id)).toEqual([recent.id, old.id]);
  });

  it("picks the page with most words, then the earliest", () => {
    const n = note("N", { pages: ["alpha", "alpha beta", "beta alpha", "gamma"] });
    const hit = search("alpha beta", [n])[0];
    expect(hit?.page?.number).toBe(2);
    expect(hit?.matchedPages).toBe(3);
    expect(search("alpha", [n])[0]?.page?.number).toBe(1);
    const t = search("budget", [note("Budget", { pages: ["unrelated"] })])[0];
    expect(t?.page).toBeUndefined();
    expect(t?.fields).toEqual(["title"]);
  });

  it("flattens, trims and marks snippets", () => {
    const long = "word ".repeat(60) + "needle\nsecond line " + "tail ".repeat(60);
    const s = search("needle", [note("N", { pages: [long] })])[0]?.snippet;
    expect(s?.text.startsWith("…") && s.text.endsWith("…")).toBe(true);
    expect(s?.text.includes("\n")).toBe(false);
    expect([...(s?.text ?? "")].length).toBeLessThan(160);
    expect(s?.text.includes("second line")).toBe(true);
    expect(matched({ snippet: s ?? { text: "", matches: [] } })).toEqual(["needle"]);
  });

  it("caps and deduplicates query words", () => {
    const n = note("N", { pages: [Array.from({ length: 100 }, (_, i) => String(i)).join(" ")] });
    expect(search(Array.from({ length: 100 }, (_, i) => String(i)).join(" "), [n])).toHaveLength(1);
    expect(maxWords).toBe(12);
    expect(search("a a a a", [note("N", { pages: ["a b c"] })])).toHaveLength(1);
  });
});

describe("folding cache", () => {
  it("foldText is fold without the map", () => {
    const samples = ["", "ASCII Only 123", "Café", "STRASSE straße", "ΣΑΣ σας", "İstanbul", "ﬁne ＦＵＬＬ", "e\u0301", "🎉 x", "\u212a", "Ǆ ǅ"];
    let seed = 7;
    for (let i = 0; i < 200; i++) {
      let t = "";
      for (let k = 0; k < 12; k++) {
        seed = (seed * 1103515245 + 12345) % 2147483648;
        const c = seed % 0x2fff;
        t += c >= 0xd800 && c < 0xe000 ? "x" : String.fromCodePoint(c);
      }
      samples.push(t);
    }
    for (const s of samples) expect(foldText(s)).toBe(fold(s).text);
  });

  it("knows when a query only narrows the previous one", () => {
    expect(refinesQuery("mom", "momentum")).toBe(true);
    expect(refinesQuery("momentum", "momentum energy")).toBe(true);
    expect(refinesQuery("cafe", "CAFÉS")).toBe(true);
    expect(refinesQuery("#work", "#workshop")).toBe(true);
    expect(refinesQuery("work", "#workshop")).toBe(true);
    expect(refinesQuery("#work", "workshop")).toBe(false);
    expect(refinesQuery("momentum", "mom")).toBe(false);
    expect(refinesQuery("energy momentum", "momentum")).toBe(false);
    expect(refinesQuery("", "a")).toBe(false);
    expect(refinesQuery("a", " ")).toBe(false);
    // Narrowing by refinement gives exactly the full search's hits, in the same order.
    const notes = [
      note("Momentum notes", { tags: ["workshop"], modified: 3 }), note("Moment", { pages: ["momentum here"], modified: 2 }),
      note("Other", { notebook: "Mom/Work", modified: 1 }), note("Workshop", { tags: ["work"], modified: 4 }),
      note("Momentous", { tags: ["workshop", "mom"], modified: 5 }),
    ];
    const queries = ["m", "mo", "mom", "mom #w", "mom #work", "mom #works", "momentum"];
    let previous = queries[0] ?? "", hits = search(previous, notes);
    for (const q of queries.slice(1)) {
      const full = search(q, notes);
      if (refinesQuery(previous, q)) {
        const ids = new Set(hits.map((h) => h.id));
        expect(search(q, notes.filter((n) => ids.has(n.id)))).toEqual(full);
      }
      previous = q;
      hits = full;
    }
  });

  it("folds a changed field again", () => {
    const a = note("Physics", { tags: ["one"], notebook: "School", pages: ["momentum"] });
    expect(search("physics", [a]).length).toBe(1);
    a.title = "Chemistry";
    a.tags = ["two"];
    a.notebook = "Work";
    const page = a.pageTexts[0];
    if (page) page.text = "energy";
    expect(search("physics", [a])).toEqual([]);
    expect(search("#one", [a])).toEqual([]);
    expect(search("school", [a])).toEqual([]);
    expect(search("momentum", [a])).toEqual([]);
    expect(search("chemistry #two work energy", [a]).length).toBe(1);
    a.tags.push("three");
    expect(search("#three", [a]).length).toBe(1);
  });
});

describe("notebooks", () => {
  it("trims components and drops empty segments", () => {
    expect(notebookComponents(" A//B / ")).toEqual(["A", "B"]);
    expect(notebookComponents("/Research/Daily log/")).toEqual(["Research", "Daily log"]);
    expect(notebookComponents(undefined)).toEqual([]);
    expect(notebookComponents(" / // ")).toEqual([]);
    expect(canonicalNotebook(" A//B / ")).toBe("A/B");
    expect(canonicalNotebook("//")).toBeUndefined();
  });

  it("compares whole segments", () => {
    expect(isWithinNotebook("A/B/C", "A")).toBe(true);
    expect(isWithinNotebook("A/B/C", "A/B")).toBe(true);
    expect(isWithinNotebook(" A / B ", "A/B")).toBe(true);
    expect(isWithinNotebook("A/Bc", "A/B")).toBe(false);
    expect(isWithinNotebook("A", "A/B")).toBe(false);
    expect(isWithinNotebook("B/A", "A")).toBe(false);
    expect(isWithinNotebook(undefined, "A")).toBe(false);
    expect(isWithinNotebook("A", "")).toBe(false);
  });

  it("builds intermediate levels and sorts numerically", () => {
    const tree = notebookTree(["School/Math 10", "School/Math 9", "Research/Daily log/2026", "School", undefined, "  ",
      "/School/ Math 9 /", "Archive"]);
    expect(tree.map((n) => n.path)).toEqual(["Archive", "Research", "School"]);
    expect(tree[1]?.children.map((n) => n.path)).toEqual(["Research/Daily log"]);
    expect(tree[1]?.children[0]?.children.map((n) => n.name)).toEqual(["2026"]);
    expect(tree[2]?.children.map((n) => n.name)).toEqual(["Math 9", "Math 10"]);
    expect(notebookTree([])).toEqual([]);
    const twins = notebookTree(["A/Notes", "B/Notes"]);
    expect(twins.flatMap((n) => [n.path, ...n.children.map((c) => c.path)])).toEqual(["A", "A/Notes", "B", "B/Notes"]);
  });
});

// Ports of NoteSearchTests "Snippets leave equations out" (#147): the parts of a page are spans, a snippet stays
// inside one prose part and an equation's LaTeX is searched but never quoted.
describe("snippets leave equations out", () => {
  const prose = "For small angles a pendulum is a harmonic oscillator";
  const latex = String.raw`T = 2\pi\sqrt{\frac{L}{g}}`;
  const box = "Period depends on the length";
  const page: PageTextEntry = {
    number: 1, text: [prose, latex, box].join("\n"),
    spans: [
      { start: 0, end: prose.length, isMath: false },
      { start: prose.length + 1, end: prose.length + 1 + latex.length, isMath: true },
      { start: prose.length + latex.length + 2, end: prose.length + latex.length + 2 + box.length, isMath: false },
    ],
  };
  const pendulum: SearchableNote = { id: "p", title: "Pendulum", tags: [], modified: 0, pageTexts: [page] };

  it("quotes the prose part and nothing of its neighbours", () => {
    for (const q of ["oscillator", "pendulum", "small"]) {
      const s = search(q, [pendulum])[0]?.snippet;
      expect(s?.isEquation ?? false).toBe(false);
      expect(s?.text).toBe(prose);
    }
    expect(search("length", [pendulum])[0]?.snippet?.text).toBe(box);
  });

  it("shows the marker for a match only inside an equation, which stays searchable", () => {
    for (const q of ["frac", "sqrt", String.raw`\pi`]) {
      const hits = search(q, [pendulum]);
      expect(hits.length).toBe(1);
      expect(hits[0]?.snippet).toEqual({ text: equationMarker, matches: [], isEquation: true });
      expect(hits[0]?.page?.number).toBe(1);
    }
    expect(search("pendulum frac", [pendulum])[0]?.snippet?.isEquation ?? false).toBe(false);
  });

  it("starts and ends at word boundaries", () => {
    const words = Array.from({ length: 120 }, (_, i) => `word${i}`);
    const s = search("word60", [note("Long", { pages: [words.join(" ")] })])[0]?.snippet;
    expect(s?.text.startsWith("…") && s.text.endsWith("…")).toBe(true);
    const shown = (s?.text ?? "").replace(/…/g, "").split(" ");
    expect(shown.every((w) => words.includes(w))).toBe(true);
    expect(shown).toContain("word60");
    expect(matched({ snippet: s ?? { text: "", matches: [] } })).toEqual(["word60"]);
  });

  it("treats text without spans (published summaries) as one prose part", () => {
    expect(pageSnippet({ number: 1, text: "plain words only" }, ["words"])?.text).toBe("plain words only");
    expect(pageSnippet({ number: 1, text: "plain words only" }, ["absent"])).toBeUndefined();
  });
});
