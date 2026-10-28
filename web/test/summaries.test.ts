// Published summaries (format.md §12): the vector, the Swift goldens
// (`sempere vault summaries --plaintext`) against what the TypeScript reader
// computes from the revisions, and every way a file is refused.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { loadNote, summarize } from "../src/vault/library.ts";
import {
  SummariesError, decodeEntry, decodeSummaries, entrySummary, openSummaries, readSummaries, sealSummaries,
  summariesKeyFromSecret, summariesKeyInfo,
} from "../src/vault/summaries.ts";
import { fixtures, golden, gzip, sealFor, unlockFixture, webFixtures } from "./support.ts";

const hex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");

describe("published summaries", () => {
  it("matches the format.md §12.1 test vector", async () => {
    const secret = Uint8Array.from({ length: 32 }, (_, i) => i);
    const key = await summariesKeyFromSecret(secret);
    expect(hex(new Uint8Array(await crypto.subtle.exportKey("raw", key))))
      .toBe("4ffd10840df4dc46092a2c424919f611c1bcc355fe7526a19e25a1489bf5510a");
    const nonce = Uint8Array.from({ length: 12 }, (_, i) => 0xa0 + i);
    const file = await sealSummaries(new TextEncoder().encode("{}"), key, "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c", nonce);
    expect(hex(file)).toBe("534d505501a0a1a2a3a4a5a6a7a8a9aaabb466bcf027fe45b94f3fe195f6e0b57d9c6e");
    expect(new TextDecoder().decode(await openSummaries(file, [key], "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c"))).toBe("{}");
  });

  for (const [name, dir] of [["sample", join(fixtures, "sample.sempere")], ["render", join(webFixtures, "render.sempere")],
    ["newer", join(fixtures, "newer.sempere")]] as const) {
    it(`equals the Swift summaries of ${name} for every note it lists`, async () => {
      const { source, vault } = await unlockFixture(dir);
      const want = JSON.parse(readFileSync(join(golden, `${name}.summaries.json`), "utf8")) as { vaultId: string; notes: Record<string, unknown> };
      expect(want.vaultId).toBe(vault.manifest.vaultId);
      const entries = decodeSummaries(want, vault.manifest.vaultId);
      expect(entries.size).toBe(Object.keys(want.notes).length);   // every Swift entry validates here
      for (const id of await source.listNotes()) {
        const note = await loadNote(source, vault, id);
        const entry = entries.get(id);
        // Swift publishes exactly the notes that read cleanly and hold nothing of a newer version.
        expect(entry !== undefined, id).toBe(note.failures.length === 0 && note.state !== undefined && note.newer === undefined);
        if (!entry) continue;
        expect(entry.revisions).toEqual(await source.listRevisions(id));
        const mine = summarize(note);
        // Published summaries carry the page texts only (format.md §12), not which part is an equation.
        const texts = mine.pageTexts.map(({ number, text }) => ({ number, text }));
        expect(entrySummary(id, entry)).toEqual({ ...mine, pageTexts: texts, hasAttachments: false });
      }
    });
  }

  it("round-trips through the vault's key, and refuses tampered, foreign and wrong-vault files", async () => {
    const { vault } = await unlockFixture(join(fixtures, "sample.sempere"));
    const content = JSON.parse(readFileSync(join(golden, "sample.summaries.json"), "utf8")) as unknown;
    const sealed = await sealFor(vault, content);
    expect((await readSummaries(sealed, vault)).size).toBe(2);
    for (const i of [0, 4, 5, 20, sealed.length - 1]) {
      const bad = sealed.slice();
      bad[i] = (bad[i] ?? 0) ^ 1;
      await expect(readSummaries(bad, vault)).rejects.toBeInstanceOf(SummariesError);
    }
    await expect(readSummaries(sealed.subarray(0, 20), vault)).rejects.toBeInstanceOf(SummariesError);
    // Sealed for another vault id (same secret): the associated data differs.
    await expect(readSummaries(await sealFor(vault, content, "00000000-0000-4000-8000-000000000000"), vault))
      .rejects.toBeInstanceOf(SummariesError);
    // Authentic, but naming another vault inside.
    await expect(readSummaries(await sealFor(vault, { ...(content as object), vaultId: "00000000-0000-4000-8000-000000000000" }), vault))
      .rejects.toBeInstanceOf(SummariesError);
    // Another secret.
    const other = await summariesKeyFromSecret(new Uint8Array(32));
    const foreign = await sealSummaries(await gzip(new TextEncoder().encode(JSON.stringify(content))), other, vault.manifest.vaultId);
    await expect(readSummaries(foreign, vault)).rejects.toBeInstanceOf(SummariesError);
    // Not gzip inside.
    const [key] = await vault.derivedKeys(summariesKeyInfo, { name: "AES-GCM", length: 256 }, ["encrypt"]);
    if (!key) throw new Error("no key");
    await expect(readSummaries(await sealSummaries(new TextEncoder().encode("{}"), key, vault.manifest.vaultId), vault))
      .rejects.toBeInstanceOf(SummariesError);
  });

  it("drops malformed entries alone", () => {
    const good = {
      revisions: ["17596320000000000-a1b2c3d4-1.delta.age"], title: "T", tags: [], favorite: false, deleted: false,
      created: "2026-10-04T16:20:00.000Z", modified: "2026-10-04T16:20:00.000Z", pages: 1, pageTexts: [{ page: 1, text: "x" }],
      unknown: { kept: "ignored" },
    };
    expect(decodeEntry(good)?.pageTexts).toEqual([{ number: 1, text: "x" }]);
    // null reads as absent (Swift's `notebook: String?`).
    const nullNotebook = decodeEntry({ ...good, notebook: null });
    expect(nullNotebook).toBeDefined();
    expect(nullNotebook && "notebook" in nullNotebook).toBe(false);
    for (const bad of [
      { ...good, revisions: [] }, { ...good, revisions: ["../x"] },
      { ...good, revisions: ["17596320000000001-a1b2c3d4-1.delta.age", "17596320000000000-a1b2c3d4-1.delta.age"] },
      { ...good, created: "2026-02-30T00:00:00Z" }, { ...good, title: 7 }, { ...good, pages: -1 }, { ...good, pages: 1.5 },
      { ...good, pageTexts: [{ page: 2, text: "x" }] }, { ...good, pageTexts: [{ page: 1, text: "x" }, { page: 1, text: "y" }] },
      { ...good, notebook: 3 }, { ...good, tags: [1] }, null, [],
    ]) expect(decodeEntry(bad)).toBeUndefined();
    const vaultId = "11111111-1111-4111-8111-111111111111";
    const m = decodeSummaries({ format: "sempere-summaries/1", vaultId, notes: {
      "11111111-1111-4111-8111-111111111111": good, "11111111-1111-4111-8111-11111111111A": good,
      "22222222-2222-4222-8222-222222222222": { ...good, pages: "1" },
    } }, vaultId);
    expect([...m.keys()]).toEqual(["11111111-1111-4111-8111-111111111111"]);
    expect(() => decodeSummaries({ format: "sempere-summaries/2", vaultId, notes: {} }, vaultId)).toThrow(SummariesError);
    expect(() => decodeSummaries({ format: "sempere-summaries/1", vaultId, notes: [] }, vaultId)).toThrow(SummariesError);
  });
});
