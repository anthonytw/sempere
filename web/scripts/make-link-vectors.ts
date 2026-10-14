// Writes Tests/SempereTests/Fixtures/secret-link-vectors.json: the signed
// secret link of format.md §2.1 for fixed secrets, shared by the Swift tests
// (SecretLinkTests) and web/test/link.test.ts. Seeds and public keys are
// deterministic. The "noble" link is deterministic too (Ed25519 always is;
// ML-DSA-65 signed without hedging), so a rerun reproduces it; links made by
// other implementations (swift-crypto hedges ML-DSA) are kept as they are.
//
// Run: node scripts/make-link-vectors.ts (from web/).

import { ed25519 } from "@noble/curves/ed25519.js";
import { ml_dsa65 } from "@noble/post-quantum/ml-dsa.js";
import { hkdfSync } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const out = join(import.meta.dirname, "..", "..", "Tests", "SempereTests", "Fixtures", "secret-link-vectors.json");

const hex = (b: Uint8Array): string => Buffer.from(b).toString("hex");
const hkdf = (secret: Uint8Array, info: string): Uint8Array =>
  new Uint8Array(hkdfSync("sha256", secret, new Uint8Array(0), info, 32));
const enc = new TextEncoder();

const vaultId = "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c";
const oldSecret = new Uint8Array(32).map((_, i) => i + 1);
const newSecret = new Uint8Array(32).map((_, i) => 0xa0 + i);

const secretId = hkdf(newSecret, "sempere/1 secret id");
const message = Buffer.concat([enc.encode("sempere/1"), Uint8Array.of(0), enc.encode("secret link"), Uint8Array.of(0),
  enc.encode(vaultId), Uint8Array.of(0), secretId]);
const edSeed = hkdf(oldSecret, "sempere/1 secret link ed25519 seed");
const mlSeed = hkdf(oldSecret, "sempere/1 secret link ml-dsa-65 seed");
const ml = ml_dsa65.keygen(mlSeed);
const nobleLink = {
  by: "noble",
  ed25519: hex(ed25519.sign(message, edSeed)),
  mldsa65: hex(ml_dsa65.sign(message, ml.secretKey, { extraEntropy: false })),
};

type Link = { by: string; ed25519: string; mldsa65: string };
const kept: Link[] = existsSync(out)
  ? (JSON.parse(readFileSync(out, "utf8")) as { links: Link[] }).links.filter((l) => l.by !== "noble")
  : [];

const vectors = {
  description: "format.md §2.1 signed secret link: fixed secrets, derived seeds and public keys, and links that "
    + "must verify (both signatures) under the old secret's keys",
  vaultId,
  oldSecret: hex(oldSecret),
  newSecret: hex(newSecret),
  secretIdNew: hex(secretId),
  message: hex(message),
  ed25519Seed: hex(edSeed),
  mldsa65Seed: hex(mlSeed),
  ed25519PublicKey: hex(ed25519.getPublicKey(edSeed)),
  mldsa65PublicKey: hex(ml.publicKey),
  links: [nobleLink, ...kept],
};
writeFileSync(out, JSON.stringify(vectors, null, 2) + "\n");
console.log(`wrote ${out}`);
