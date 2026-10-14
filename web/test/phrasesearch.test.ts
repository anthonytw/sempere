// The viewer's port of `sempere search --transcripts` against the CLI: for
// every term of web/scripts/golden.sh and every fixture vault, the hits the
// TypeScript code finds in the decrypted notes and transcripts must equal
// test/golden/search/<vault>/<term in hex>.json, which the Swift CLI wrote.

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { trimTerm } from "../src/format/occurrences.ts";
import { type PhraseHit, noteHits, phraseQuery, sortHits } from "../src/format/phrasesearch.ts";
import { readBlob } from "../src/vault/blobs.ts";
import { loadNote } from "../src/vault/library.ts";
import { readTranscripts } from "../src/vault/transcripts.ts";
import { fixtures, golden, unlockFixture, webFixtures } from "./support.ts";

const vaults: Record<string, string> = {
  sample: join(fixtures, "sample.sempere"),
  render: join(webFixtures, "render.sempere"),
  search: join(webFixtures, "search.sempere"),
};

async function searchVault(dir: string, term: string): Promise<{ hits: PhraseHit[]; problems: number }> {
  const { source, vault } = await unlockFixture(dir);
  const q = phraseQuery(trimTerm(term));
  if (!q) throw new Error("empty term");
  const hits: PhraseHit[] = [];
  let problems = 0;
  for (const id of await source.listNotes()) {
    const note = await loadNote(source, vault, id);
    if (!note.state) {
      problems++;
      continue;
    }
    if (note.state.deleted) continue;
    const transcripts = await readTranscripts(note.state, (ref, max) => readBlob(source, vault, id, ref, max));
    problems += transcripts.filter((t) => t.error !== undefined).length;
    hits.push(...noteHits(id, note.state, q, transcripts));
  }
  return { hits: sortHits(hits), problems };
}

for (const [name, dir] of Object.entries(vaults)) {
  describe(`sempere search --transcripts on ${name}.sempere`, () => {
    const dest = join(golden, "search", name);
    const files = readdirSync(dest).filter((f) => f.endsWith(".meta.json"));
    it("has goldens", () => expect(files.length).toBeGreaterThan(10));
    for (const f of files) {
      const meta = JSON.parse(readFileSync(join(dest, f), "utf8")) as { term: string; exit: number };
      it(JSON.stringify(meta.term), async () => {
        const expected = JSON.parse(readFileSync(join(dest, f.replace(".meta.json", ".json")), "utf8")) as unknown;
        const { hits, problems } = await searchVault(dir, meta.term);
        // JSON round trip: absent optionals are omitted, as in Swift's output.
        expect(JSON.parse(JSON.stringify(hits))).toEqual(expected);
        expect(problems > 0 ? 1 : 0).toBe(meta.exit);
      });
    }
  });
}
