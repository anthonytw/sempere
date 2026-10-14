// The phrase search of `sempere search` (src/format/occurrences.ts) against
// Foundation: test/golden/occurrence-vectors.json is what Swift finds for
// test/fixtures/occurrence-cases.json (web/scripts/occurrence-vectors.swift,
// regenerated and diffed by CI's web-golden job).

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { foldTerm, occurrences, prepare, snippet, trimTerm } from "../src/format/occurrences.ts";
import { golden } from "./support.ts";

interface Vector { text: string; term: string; ranges: [number, number][]; snippet?: string }

const vectors = JSON.parse(readFileSync(join(golden, "occurrence-vectors.json"), "utf8")) as Vector[];

describe("phrase occurrences match Foundation's range(of:options: [.caseInsensitive, .diacriticInsensitive])", () => {
  it("has vectors", () => expect(vectors.length).toBeGreaterThan(400));
  for (const [i, v] of vectors.entries()) {
    it(`#${i} ${JSON.stringify(v.term)} in ${JSON.stringify(v.text).slice(0, 40)}`, () => {
      const t = prepare(v.text);
      const found = occurrences(t, foldTerm(trimTerm(v.term)));
      expect(found.map(([a, b]) => [t.offsets[a], t.offsets[b]])).toEqual(v.ranges);
      const first = found[0];
      expect(first ? snippet(t, first) : undefined).toEqual(v.snippet);
    });
  }
});

describe("folding rules", () => {
  const find = (text: string, term: string) => {
    const t = prepare(text);
    return occurrences(t, foldTerm(term)).map(([a, b]) => text.slice(t.offsets[a], t.offsets[b]));
  };
  it("ignores case and accents, folds ß fully, never splits a folding", () => {
    expect(find("Café CAFE café", "café")).toEqual(["Café", "CAFE", "café"]);
    expect(find("Straße STRASSE", "strasse")).toEqual(["Straße", "STRASSE"]);
    expect(find("Straße", "s")).toEqual(["S"]);
    expect(find("ﬁ", "f")).toEqual([]);
  });
  it("keeps kana voicing and full-width forms distinct", () => {
    expect(find("が", "か")).toEqual([]);
    expect(find("Ａ", "a")).toEqual([]);
  });
  it("trims the term like the CLI", () => {
    expect(trimTerm("\n\t café 　")).toBe("café");
    expect(trimTerm("﻿x")).toBe("﻿x");
  });
});

describe("the cheap first check", () => {
  it("never rules out a text that has an occurrence", async () => {
    const { foldedText, mayContain } = await import("../src/format/occurrences.ts");
    for (const v of vectors) {
      const term = foldTerm(trimTerm(v.term));
      if (v.ranges.length > 0) expect(mayContain(foldedText(v.text), term)).toBe(true);
    }
  });
});
