// Bound rewrap journals (format.md §3.3.1 "Accepting the journal"; security
// review 2026-10, stage 4, S0/S1/S4): a removed device keeps the outgoing
// secret and `secretLink` stays in vault.json, so the link alone let it plant
// a journal after its removal and have blob names, published summaries and
// revisions under its old secret accepted again. The journal now counts only
// while vault.json binds it (`rewrapPending`), as in Vault.judgeJournal.

import { ed25519 } from "@noble/curves/ed25519.js";
import { ml_dsa65 } from "@noble/post-quantum/ml-dsa.js";
import { Decrypter, Encrypter, armor, identityToRecipient } from "age-encryption";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { type SecretLink, linkMessage, linkSeeds } from "../src/vault/link.ts";
import {
  UnlockedVault, type VaultManifest, parseManifest, rewrapPendingTag,
} from "../src/vault/vault.ts";
import { fixtures } from "./support.ts";

const enc = new TextEncoder();
const gcm = { name: "AES-GCM", length: 256 } as const;

describe("rewrap journal binding", () => {
  it("matches the vector computed independently from format.md §3.3.1 (also in RewrapJournalBindingTests.swift)", async () => {
    const secret = Uint8Array.from({ length: 32 }, (_, i) => i);
    const journal = enc.encode('{"format":"sempere/1","previousVaultSecret":"x"}');
    expect(await rewrapPendingTag("0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c", journal, secret))
      .toBe("5d73a94df76ab2b2e3c4decc6ac2b9853a0823650753ca8142e584ccc9529a25");
  });

  it("accepts a linked journal's secret only while vault.json binds it", async () => {
    const identity = readFileSync(join(fixtures, "sample.key"), "utf8").split("\n").find((x) => x.startsWith("AGE-SECRET-KEY-PQ-"));
    if (!identity) throw new Error("no identity");
    const sample = parseManifest(readFileSync(join(fixtures, "sample.sempere", "vault.json")));
    const d = new Decrypter();
    d.addIdentity(identity);
    const current = await d.decrypt(armor.decode(sample.vaultSecret));
    // The outgoing secret a removed device kept, and the genuine link from the rotation that removed it.
    const previous = Uint8Array.from({ length: 32 }, (_, i) => 100 + i);
    const seeds = await linkSeeds(previous);
    const message = await linkMessage(current, sample.vaultId);
    const link: SecretLink = { kind: "signed", ed25519: ed25519.sign(message, seeds.ed25519),
      mldsa65: ml_dsa65.sign(message, ml_dsa65.keygen(seeds.mldsa65).secretKey) };
    const e = new Encrypter();
    e.addRecipient(await identityToRecipient(identity));
    const journal = enc.encode(JSON.stringify({ format: "sempere/1", previousVaultSecret: armor.encode(await e.encrypt(previous)) }));
    const bound: VaultManifest = { ...sample, secretLink: link };
    const keys = async (m: VaultManifest, j: Uint8Array = journal) =>
      (await (await UnlockedVault.unlock(m, identity, j)).derivedKeys("sempere/1 test", gcm, ["decrypt"])).length;

    // While the rotation is unfinished: bound, accepted.
    const pending = await rewrapPendingTag(sample.vaultId, journal, current);
    expect(await keys({ ...bound, rewrapPending: pending })).toBe(2);
    // The attack: the rotation finished (no rewrapPending), the removed device plants a journal. Refused.
    expect(await keys(bound)).toBe(1);
    // A binding of other bytes, or one that is not hex, does not count.
    expect(await keys({ ...bound, rewrapPending: await rewrapPendingTag(sample.vaultId, enc.encode("{}"), current) })).toBe(1);
    expect(await keys({ ...bound, rewrapPending: "" })).toBe(1);
    // Bound but not linked: refused too.
    expect(await keys({ ...sample, rewrapPending: pending })).toBe(1);
    // The blob names follow: only the current secret's once refused.
    const sha = new Uint8Array(32);
    expect(await (await UnlockedVault.unlock(bound, identity, journal)).blobNames(sha)).toHaveLength(1);
    expect(await (await UnlockedVault.unlock({ ...bound, rewrapPending: pending }, identity, journal)).blobNames(sha)).toHaveLength(2);
  });

  it("reads rewrapPending leniently", () => {
    const base = JSON.parse(readFileSync(join(fixtures, "sample.sempere", "vault.json"), "utf8")) as Record<string, unknown>;
    const parse = (v: unknown) => parseManifest(enc.encode(JSON.stringify({ ...base, rewrapPending: v })));
    expect(parse("ab").rewrapPending).toBe("ab");
    expect(parse(42).rewrapPending).toBe("");
    expect(parse(null).rewrapPending).toBeUndefined();
  });
});
