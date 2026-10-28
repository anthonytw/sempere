// Authenticated version markers (format.md §2.1 "Version markers", keyed by `markersKey` of K_e, §15.2;
// security review 2026-10, N3): the same tag as Swift's, and a changed or stripped one reported. The
// viewer never writes; it reports what the tag says.

import { join } from "node:path";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { UnlockedVault, listWarningText, markersTag, parseManifest } from "../src/vault/vault.ts";
import { deriveEpoch, epochInfo } from "../src/vault/epoch.ts";
import { knownFeatures } from "../src/format/newer.ts";
import { fixtures, sampleIdentity, unlockFixture } from "./support.ts";

const epochKey = Uint8Array.from({ length: 32 }, (_, i) => i + 1);
const markersKey = deriveEpoch(epochKey, epochInfo.markersKey);
const vaultId = "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c";

describe("version markers", () => {
  it("is canonical in the features' order and repeats, and depends on the format and the key", async () => {
    const tag = await markersTag(vaultId, "sempere/1", ["recipients-tag", "attachments", "markers-tag"], markersKey);
    expect(tag).toMatch(/^[0-9a-f]{64}$/);
    expect(await markersTag(vaultId, "sempere/1", ["markers-tag", "attachments", "recipients-tag", "attachments"], markersKey)).toBe(tag);
    expect(await markersTag(vaultId, "sempere/2", ["attachments", "markers-tag", "recipients-tag"], markersKey)).not.toBe(tag);
    expect(await markersTag(vaultId, "sempere/1", ["attachments"], markersKey)).not.toBe(tag);
    expect(await markersTag(vaultId, "sempere/1", ["attachments", "markers-tag", "recipients-tag"], deriveEpoch(epochKey, "other"))).not.toBe(tag);
    expect(await markersTag(vaultId, "sempere/1", ["a\0b"], markersKey)).toBeUndefined();
    expect(knownFeatures.size).toBe(0);
  });

  it("verifies the fixture Swift tagged, and reports a change made without the key", async () => {
    const dir = join(fixtures, "sample.sempere");
    const { vault } = await unlockFixture(dir);
    expect(vault.manifest.markersTag).toMatch(/^[0-9a-f]{64}$/);
    expect(vault.listStatus).toEqual({ status: "verified" });

    // `features` is part of vault.json's authorSig and of this tag: either reads as a failed check. The list
    // tag does not cover it, so the vault still opens and is read.
    const raw = JSON.parse(readFileSync(join(dir, "vault.json"), "utf8")) as Record<string, unknown>;
    const unlock = async (json: unknown) =>
      UnlockedVault.unlock(parseManifest(new TextEncoder().encode(JSON.stringify(json))), sampleIdentity());
    const v2 = await unlock({ ...raw, features: ["tables"] });
    expect(v2.listStatus).toEqual({ status: "tampered", reason: "markersTag" });
    expect(listWarningText(v2.listStatus)).toContain("sempere vault markers repair");

    // A tag in the wrong case or of the wrong value never verifies; a missing one is not a manifest.
    const v3 = await unlock({ ...raw, markersTag: String(raw.markersTag).toUpperCase() });
    expect(v3.listStatus).toEqual({ status: "tampered", reason: "markersTag" });
    const { markersTag: _drop, ...stripped } = raw;
    void _drop;
    expect(() => parseManifest(new TextEncoder().encode(JSON.stringify(stripped)))).toThrow(/markersTag/);
  });
});
