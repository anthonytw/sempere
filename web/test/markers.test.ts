// Authenticated version markers (format.md §2.1 "Version markers"; security
// review 2026-10, N3): the same tag as Swift's, and a changed or stripped one
// reported. The viewer never writes; it reports what the tag says.

import { join } from "node:path";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { UnlockedVault, checkRecipients, markersTag, parseManifest, recipientsWarningText } from "../src/vault/vault.ts";
import { knownFeatures } from "../src/format/newer.ts";
import { fixtures, sampleIdentity, unlockFixture } from "./support.ts";

const secret = Uint8Array.from({ length: 32 }, (_, i) => i + 1);
const vaultId = "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c";

describe("version markers", () => {
  it("matches the Swift known-answer vector, whatever the features' order", async () => {
    // MarkersAuthTests.testKnownAnswerVectorAndCanonicalFeatures.
    const kat = "015d9f46c6560d1d087b0ad3bb4696179fc2a7fb917a453285ce92b3569f4ace";
    expect(await markersTag(vaultId, "sempere/1", ["recipients-tag", "attachments", "markers-tag"], secret)).toBe(kat);
    expect(await markersTag(vaultId, "sempere/1", ["markers-tag", "attachments", "recipients-tag", "attachments"], secret)).toBe(kat);
    expect(await markersTag(vaultId, "sempere/2", ["attachments", "markers-tag", "recipients-tag"], secret)).not.toBe(kat);
    expect(await markersTag(vaultId, "sempere/1", ["a\0b"], secret)).toBeUndefined();
    expect(knownFeatures.has("markers-tag")).toBe(true);
  });

  it("verifies the fixture Swift tagged, and reports a change made without the key", async () => {
    const dir = join(fixtures, "sample.sempere");
    const { vault } = await unlockFixture(dir);
    expect(vault.manifest.markersTag).toMatch(/^[0-9a-f]{64}$/);
    expect(vault.recipientsStatus).toEqual({ status: "verified" });

    const raw = JSON.parse(readFileSync(join(dir, "vault.json"), "utf8")) as Record<string, unknown>;
    const unlock = async (json: unknown) =>
      UnlockedVault.unlock(parseManifest(new TextEncoder().encode(JSON.stringify(json))), sampleIdentity());
    const v2 = await unlock({ ...raw, features: (raw.features as string[]).filter((f) => f !== "attachments") });
    expect(v2.recipientsStatus).toEqual({ status: "tampered", reason: "markersMismatch" });
    expect(recipientsWarningText(v2.recipientsStatus)).toContain("sempere vault markers repair");

    const { markersTag: _drop, ...stripped } = raw;
    void _drop;
    const v3 = await unlock(stripped);
    expect(v3.recipientsStatus).toEqual({ status: "tampered", reason: "markersRemoved" });

    // Both stripped: an older vault (a device without a record cannot tell).
    const older = { ...stripped, features: (raw.features as string[]).filter((f) => f !== "markers-tag") };
    const v4 = await unlock(older);
    expect(v4.recipientsStatus).toEqual({ status: "verified" });
  });

  it("checks the markers only once the list checks", async () => {
    const m = parseManifest(new TextEncoder().encode(JSON.stringify({
      format: "sempere/1", vaultId, created: "2026-10-04T16:20:00Z", vaultSecret: "x",
      recipients: [{ key: "age1pq1" + "q".repeat(40), label: "", added: "2026-10-04T16:20:00Z" }],
      features: ["recipients-tag", "markers-tag"], recipientsTag: "0".repeat(64), markersTag: "0".repeat(64),
    })));
    expect(await checkRecipients(m, secret)).toEqual({ status: "tampered", reason: "tagMismatch" });
  });
});
