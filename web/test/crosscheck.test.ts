// Cross-check against the Swift CLI: for every note of every fixture vault,
// the TypeScript reducer must equal `sempere export --format json` and the
// TypeScript renderer must write `sempere export --format svg` byte for byte
// (web/scripts/golden.sh writes test/golden; CI regenerates and diffs it).

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { encodeState } from "../src/format/model.ts";
import { formatRFC3339 } from "../src/format/rfc3339.ts";
import { renderSVG } from "../src/render/page.ts";
import { loadNote } from "../src/vault/library.ts";
import { UnlockedVault, parseManifest } from "../src/vault/vault.ts";
import { NodeDirSource, fixtures, golden, sampleIdentity, webFixtures } from "./support.ts";

const vaults: [string, string][] = [
  ["sample", join(fixtures, "sample.sempere")],
  ["render", join(webFixtures, "render.sempere")],
];

/** Sorted-key JSON, so property order never matters. */
function canonical(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(canonical);
  if (v && typeof v === "object") {
    return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canonical((v as Record<string, unknown>)[k])]));
  }
  return v;
}

/**
 * An SVG export without its `<g id="items">` group (format.md §8.2.3: it
 * sits between paper and strokes) and the `xlink` namespace its images use.
 * items-crosscheck.test.ts compares the group itself.
 */
function withoutItems(svg: string): string {
  return svg.replace(/<g id="items">\n[\s\S]*?<\/g>\n(?=<g id="strokes">)/, "")
    .replace(" xmlns:xlink=\"http://www.w3.org/1999/xlink\"", "");
}

for (const [name, dir] of vaults.filter(([, d]) => existsSync(d))) {
  describe(`cross-check ${name}`, async () => {
    const source = new NodeDirSource(dir);
    const manifest = parseManifest(await source.read("vault.json", 1 << 24));
    const vault = await UnlockedVault.unlock(manifest, sampleIdentity());
    const ids = await source.listNotes();
    const goldenIds = readdirSync(join(golden, name)).filter((f) => f.endsWith(".json")).map((f) => f.slice(0, -5)).sort();

    it("lists the same notes as the golden export", () => {
      expect(ids).toEqual(goldenIds);
    });

    for (const id of ids) {
      it(`reconstructs ${id} like the Swift CLI`, async () => {
        const note = await loadNote(source, vault, id);
        expect(note.failures).toEqual([]);
        if (!note.state) throw new Error(note.error);
        const want = JSON.parse(readFileSync(join(golden, name, `${id}.json`), "utf8")) as unknown;
        expect(canonical(encodeState(note.state, formatRFC3339))).toEqual(canonical(want));
      });

      it(`renders ${id} like the Swift CLI`, async () => {
        const note = await loadNote(source, vault, id);
        if (!note.state) throw new Error(note.error);
        const state = note.state;
        const pageFiles = existsSync(join(golden, name, id)) ? readdirSync(join(golden, name, id)).sort() : [];
        expect(pageFiles.length).toBe(state.pages.length);
        state.pages.forEach((page, i) => {
          const want = readFileSync(join(golden, name, id, pageFiles[i] ?? ""), "utf8");
          // Paper, extent and ink byte for byte; the items group is checked
          // structurally in items-crosscheck.test.ts (the glyphs differ by design).
          expect(renderSVG(page, state.meta)).toBe(page.items.length > 0 ? withoutItems(want) : want);
        });
      });
    }
  });
}
