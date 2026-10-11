// The signed secret link (format.md §2.1): the vectors shared with
// Tests/SempereTests/SecretLinkTests.swift (links made by noble and by
// swift-crypto), both-signatures-only, and the journal check.

import { ed25519 } from "@noble/curves/ed25519.js";
import { ml_dsa65 } from "@noble/post-quantum/ml-dsa.js";
import { Decrypter, Encrypter, armor, identityToRecipient } from "age-encryption";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  type SecretLink, linkConnects, linkMessage, linkPublicKeys, linkSeeds, parseSecretLink, verifySignedLink,
} from "../src/vault/link.ts";
import { UnlockedVault, parseManifest, rewrapPendingTag } from "../src/vault/vault.ts";
import { fixtures } from "./support.ts";

interface Vectors {
  vaultId: string; oldSecret: string; newSecret: string; message: string;
  ed25519Seed: string; mldsa65Seed: string; ed25519PublicKey: string; mldsa65PublicKey: string; legacyLink: string;
  links: { by: string; ed25519: string; mldsa65: string }[];
}

const v = JSON.parse(readFileSync(join(fixtures, "secret-link-vectors.json"), "utf8")) as Vectors;
const bytes = (h: string): Uint8Array => Uint8Array.from(Buffer.from(h, "hex"));
const hex = (b: Uint8Array): string => Buffer.from(b).toString("hex");
const oldSecret = bytes(v.oldSecret);
const newSecret = bytes(v.newSecret);
const signed = (l: { ed25519: string; mldsa65: string }): SecretLink =>
  ({ kind: "signed", ed25519: bytes(l.ed25519), mldsa65: bytes(l.mldsa65) });

describe("signed secret link (format.md §2.1)", () => {
  it("derives the shared vectors' seeds, public keys and message", async () => {
    const seeds = await linkSeeds(oldSecret);
    expect(hex(seeds.ed25519)).toBe(v.ed25519Seed);
    expect(hex(seeds.mldsa65)).toBe(v.mldsa65Seed);
    const keys = await linkPublicKeys(oldSecret);
    expect(hex(keys.ed25519)).toBe(v.ed25519PublicKey);
    expect(hex(keys.mldsa65)).toBe(v.mldsa65PublicKey);
    expect(hex(await linkMessage(newSecret, v.vaultId))).toBe(v.message);
  });

  it("verifies the links made by noble and by swift-crypto", async () => {
    const keys = await linkPublicKeys(oldSecret);
    expect(v.links.map((l) => l.by).sort()).toEqual(["noble", "swift-crypto"]);
    for (const l of v.links) {
      expect(await verifySignedLink(signed(l), keys, newSecret, v.vaultId)).toBe(true);
      expect(await verifySignedLink(signed(l), keys, oldSecret, v.vaultId)).toBe(false);
      expect(await verifySignedLink(signed(l), keys, newSecret, "00000000-0000-4000-8000-000000000000")).toBe(false);
      expect(await verifySignedLink(signed(l), await linkPublicKeys(newSecret), newSecret, v.vaultId)).toBe(false);
      expect(await linkConnects(signed(l), oldSecret, newSecret, v.vaultId)).toBe(true);
    }
  });

  it("refuses a link with only one valid signature", async () => {
    const keys = await linkPublicKeys(oldSecret);
    const [noble] = v.links;
    if (!noble) throw new Error("no vector");
    const other = Uint8Array.from({ length: 32 }, (_, i) => 0x55 ^ i);
    const otherSeeds = await linkSeeds(other);
    const message = await linkMessage(newSecret, v.vaultId);
    const edOtherKey = ed25519.sign(message, otherSeeds.ed25519);
    const mlOtherKey = ml_dsa65.sign(message, ml_dsa65.keygen(otherSeeds.mldsa65).secretKey);
    const flipped = bytes(noble.mldsa65);
    flipped[100] = (flipped[100] ?? 0) ^ 1;
    const cases: SecretLink[] = [
      { kind: "signed", ed25519: bytes(noble.ed25519), mldsa65: mlOtherKey },
      { kind: "signed", ed25519: edOtherKey, mldsa65: bytes(noble.mldsa65) },
      { kind: "signed", ed25519: bytes(noble.ed25519), mldsa65: new Uint8Array(3309) },
      { kind: "signed", ed25519: new Uint8Array(64), mldsa65: bytes(noble.mldsa65) },
      { kind: "signed", ed25519: bytes(noble.ed25519), mldsa65: flipped },
      { kind: "legacy", hex: v.legacyLink },
      { kind: "malformed" },
    ];
    for (const c of cases) expect(await verifySignedLink(c, keys, newSecret, v.vaultId)).toBe(false);
  });

  it("reads secretLink strictly", () => {
    const [l] = v.links;
    if (!l) throw new Error("no vector");
    expect(parseSecretLink({ ed25519: l.ed25519, mldsa65: l.mldsa65 })?.kind).toBe("signed");
    expect(parseSecretLink(v.legacyLink)).toEqual({ kind: "legacy", hex: v.legacyLink });
    for (const bad of [42, [], {}, { ed25519: l.ed25519 }, { ed25519: l.ed25519.toUpperCase(), mldsa65: l.mldsa65 },
      { ed25519: l.ed25519, mldsa65: l.mldsa65.slice(2) }]) {
      expect(parseSecretLink(bad)).toEqual({ kind: "malformed" });
    }
    expect(parseSecretLink(null)).toBeUndefined();
  });

  it("accepts a journal's previous secret through a signed link only when it verifies", async () => {
    const identity = readFileSync(join(fixtures, "sample.key"), "utf8").split("\n").find((x) => x.startsWith("AGE-SECRET-KEY-PQ-"));
    if (!identity) throw new Error("no identity");
    const manifest = parseManifest(readFileSync(join(fixtures, "sample.sempere", "vault.json")));
    const d = new Decrypter();
    d.addIdentity(identity);
    const current = await d.decrypt(armor.decode(manifest.vaultSecret));
    const previous = Uint8Array.from({ length: 32 }, (_, i) => 200 - i);
    const e = new Encrypter();
    e.addRecipient(await identityToRecipient(identity));
    const journal = new TextEncoder().encode(JSON.stringify({ previousVaultSecret: armor.encode(await e.encrypt(previous)) }));
    const seeds = await linkSeeds(previous);
    const message = await linkMessage(current, manifest.vaultId);
    const good: SecretLink = { kind: "signed", ed25519: ed25519.sign(message, seeds.ed25519),
      mldsa65: ml_dsa65.sign(message, ml_dsa65.keygen(seeds.mldsa65).secretKey) };
    const gcm = { name: "AES-GCM", length: 256 } as const;
    // Bound by vault.json, as every unfinished change's journal is (format.md §3.3.1).
    const rewrapPending = await rewrapPendingTag(manifest.vaultId, journal, current);
    const linked = await UnlockedVault.unlock({ ...manifest, secretLink: good, rewrapPending }, identity, journal);
    expect(await linked.derivedKeys("sempere/1 test", gcm, ["decrypt"])).toHaveLength(2);
    if (good.kind !== "signed") throw new Error("unreachable");
    const half: SecretLink = { ...good, mldsa65: new Uint8Array(3309) };
    const unlinked = await UnlockedVault.unlock({ ...manifest, secretLink: half, rewrapPending }, identity, journal);
    expect(await unlinked.derivedKeys("sempere/1 test", gcm, ["decrypt"])).toHaveLength(1);
  });
});
