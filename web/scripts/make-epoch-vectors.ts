// Writes Tests/SempereTests/Fixtures/epoch-vectors.json: the key schedule of
// the key hierarchy (docs/design/key-hierarchy.md §2, §3, §4; phase KH1) for
// fixed epoch keys, shared by the Swift tests (EpochKeysTests, CLI `keys
// derive`) and web/test/epoch.test.ts. It computes everything with node:crypto,
// noble, @scure/base and typage, independently of Sources/ and web/src/.
//
// Deterministic: derived keys, identities, recipients, the root, listTag and
// the "noble" link (Ed25519 always is; ML-DSA-65 signed without hedging), the fingerprints. Kept
// as they are on a rerun: the link and the wrap made by Swift (written by
// `SEMPERE_WRITE_EPOCH_VECTORS=1 swift test --filter EpochKeysTests`). The
// "typage" wrap is made again (age encryption is randomized).
//
// Run: node scripts/make-epoch-vectors.ts (from web/).

import { ed25519 } from "@noble/curves/ed25519.js";
import { p256 } from "@noble/curves/nist.js";
import { ml_dsa65 } from "@noble/post-quantum/ml-dsa.js";
import { bech32 } from "@scure/base";
import { Encrypter, armor, identityToRecipient } from "age-encryption";
import { createHash, createHmac, hkdfSync } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const out = join(import.meta.dirname, "..", "..", "Tests", "SempereTests", "Fixtures", "epoch-vectors.json");

const hex = (b: Uint8Array): string => Buffer.from(b).toString("hex");
const enc = new TextEncoder();
const hkdf = (key: Uint8Array, info: string | Uint8Array): Uint8Array =>
  new Uint8Array(hkdfSync("sha256", key, new Uint8Array(0), info, 32));
const sha256 = (b: Uint8Array | string): Uint8Array => new Uint8Array(createHash("sha256").update(b).digest());
const z = Uint8Array.of(0);

const vaultId = "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c";
const keys = [new Uint8Array(32).map((_, i) => 0x10 + i), new Uint8Array(32).map((_, i) => 0x40 + i)];
const deviceSeed = new Uint8Array(32).map((_, i) => 0x80 + i);
const deviceIdentity = bech32.encodeFromBytes("AGE-SECRET-KEY-PQ-", deviceSeed).toUpperCase();
const deviceRecipient = await identityToRecipient(deviceIdentity);
// format.md §11.1's fingerprint, which capture keys keep using.
const captureFingerprint = hex(sha256(deviceRecipient));
const lp = (x: Uint8Array | string): Uint8Array => {
  const b = typeof x === "string" ? enc.encode(x) : x;
  const len = Buffer.alloc(4);
  len.writeUInt32BE(b.length);
  return Buffer.concat([len, b]);
};
// Stand-ins for signing public keys and signatures: listMessage and the
// fingerprint cover them as hex text, whatever they are.
const stand = (label: string, n: number): string => {
  let s = "";
  for (let i = 0; s.length < 2 * n; i++) s += hex(sha256(`${label} ${i}`));
  return s.slice(0, 2 * n);
};
const deviceSignP256 = "04" + stand("p256", 64);
const deviceSignMLDSA65 = stand("mldsa65", 1952);
// Design §3: SHA-256("sempere/1 device" ‖ lp(key) ‖ lp(sign.p256) ‖ lp(sign.mldsa65)), signing keys as hex text.
const deviceFingerprint = hex(sha256(Buffer.concat([enc.encode("sempere/1 device"), lp(deviceRecipient),
  lp(deviceSignP256), lp(deviceSignMLDSA65)])));

async function epoch(n: number, key: Uint8Array) {
  const identitySeed = hkdf(key, "sempere/1 vault identity seed");
  const identity = bech32.encodeFromBytes("AGE-SECRET-KEY-PQ-", identitySeed).toUpperCase();
  const edSeed = hkdf(key, "sempere/1 epoch link ed25519 seed");
  const mlSeed = hkdf(key, "sempere/1 epoch link ml-dsa-65 seed");
  return {
    epoch: n,
    key: hex(key),
    identitySeed: hex(identitySeed),
    identity,
    recipient: await identityToRecipient(identity),
    tagKey: hex(hkdf(key, "sempere/1 body tag")),
    blobNameKey: hex(hkdf(key, "sempere/1 blob name")),
    listKey: hex(hkdf(key, "sempere/1 list key")),
    markersKey: hex(hkdf(key, "sempere/1 markers key")),
    epochId: hex(hkdf(key, "sempere/1 epoch id")),
    pendingKey: hex(hkdf(key, "sempere/1 reencrypt pending key")),
    captureKey: hex(hkdf(key, Buffer.concat([enc.encode("sempere/1 device capture key"), z, enc.encode(captureFingerprint)]))),
    linkEd25519Seed: hex(edSeed),
    linkMLDSA65Seed: hex(mlSeed),
    ed25519PublicKey: hex(ed25519.getPublicKey(edSeed)),
    mldsa65PublicKey: hex(ml_dsa65.keygen(mlSeed).publicKey),
    wrapPlaintext: `# sempere vault key: vault ${vaultId}, epoch ${n}\n# sempere-epoch-key: ${hex(key)}\n${identity}\n`,
  };
}

const [k1, k2] = keys;
if (!k1 || !k2) throw new Error("keys");
const epochs = [await epoch(1, k1), await epoch(2, k2)];
const [e1, e2] = epochs;
if (!e1 || !e2) throw new Error("epochs");

const root = sha256(Buffer.concat([enc.encode("sempere/1"), z, enc.encode("root"), z, enc.encode(vaultId), z,
  Buffer.from(e1.ed25519PublicKey, "hex"), Buffer.from(e1.mldsa65PublicKey, "hex")]));

const linkMessage = Buffer.concat([enc.encode("sempere/1"), z, enc.encode("epoch link"), z, enc.encode(vaultId), z,
  enc.encode("2"), z, Buffer.from(e2.epochId, "hex")]);
const nobleLink = {
  by: "noble",
  ed25519: hex(ed25519.sign(linkMessage, Buffer.from(e1.linkEd25519Seed, "hex"))),
  mldsa65: hex(ml_dsa65.sign(linkMessage, ml_dsa65.keygen(Buffer.from(e1.linkMLDSA65Seed, "hex")).secretKey,
    { extraEntropy: false })),
};

// listTag over a list at epoch 2: a device whose name has non-ASCII, a slash
// and an emoji (review M2'), and the recovery entry with its absent fields
// empty. The signing keys, addSig and wraps are fixed stand-ins: listMessage
// covers them as hex text (SHA-256(wrap) as raw bytes).
const recoverySeed = new Uint8Array(32).map((_, i) => 0xc0 + i);
const recoveryRecipient = await identityToRecipient(bech32.encodeFromBytes("AGE-SECRET-KEY-PQ-", recoverySeed).toUpperCase());
const recoveryFingerprint = hex(sha256(Buffer.concat([enc.encode("sempere/1 recovery"), lp(recoveryRecipient)])));
const entries = [
  { role: "device", key: deviceRecipient, id: deviceFingerprint.slice(0, 8), signP256: deviceSignP256,
    signMLDSA65: deviceSignMLDSA65, kind: "ipad", added: "2026-10-04T16:20:00Z", addedEpoch: "1",
    addedBy: "recovery", addSigP256: stand("addSig p256", 64), addSigMLDSA65: stand("addSig mldsa65", 3309),
    name: "Ñandú's iPad / Café ☕️📓",
    wrap: "-----BEGIN AGE ENCRYPTED FILE-----\nZGV2aWNlIHdyYXAgc3RhbmQtaW4=\n-----END AGE ENCRYPTED FILE-----\n" },
  { role: "recovery", key: recoveryRecipient, id: "", signP256: "", signMLDSA65: "", kind: "",
    added: "2026-10-04T16:20:00Z", addedEpoch: "", addedBy: "", addSigP256: "", addSigMLDSA65: "",
    name: "Recovery kit",
    wrap: "-----BEGIN AGE ENCRYPTED FILE-----\ncmVjb3Zlcnkgd3JhcCBzdGFuZC1pbg==\n-----END AGE ENCRYPTED FILE-----\n" },
];
const epochRecordHash = hex(sha256("epoch record stand-in"));
const parts = [enc.encode("sempere/1 list"), lp(vaultId), lp(hex(root)), lp("2"), lp(e2.epochId), lp(epochRecordHash),
  lp(String(entries.length))];
for (const e of entries) {
  for (const f of [e.role, e.key, e.id, e.signP256, e.signMLDSA65, e.kind, e.added, e.addedEpoch, e.addedBy,
    e.addSigP256, e.addSigMLDSA65, e.name]) parts.push(lp(f));
  parts.push(lp(sha256(e.wrap)));
}
const listMessage = Buffer.concat(parts);
const tag = createHmac("sha256", Buffer.from(e2.listKey, "hex")).update(listMessage).digest("hex");

const e2Encrypter = new Encrypter();
e2Encrypter.addRecipient(deviceRecipient);
const typageWrap = armor.encode(await e2Encrypter.encrypt(e2.wrapPlaintext));

type Signed = { by: string; ed25519: string; mldsa65: string };
type Wrap = { by: string; epoch: number; armored: string };
type AuthorSig = { by: string; p256: string; mldsa65: string };
type SignedMessage = { message: string; signatures: AuthorSig[] };
const previous = existsSync(out)
  ? JSON.parse(readFileSync(out, "utf8")) as {
    link: { links: Signed[] }; wraps: Wrap[];
    signatures?: { entry: SignedMessage; epoch: SignedMessage; manifest: SignedMessage };
  }
  : undefined;

// The three author signatures of design §4.1, by a fixed software signing pair (P-256 scalar and
// ML-DSA-65 seed). "noble" signatures are deterministic (RFC 6979, low-S; ML-DSA without hedging);
// the Swift test appends swift-crypto's.
const signerScalar = new Uint8Array(32).map((_, i) => 0x20 + i);
const signerSeed = new Uint8Array(32).map((_, i) => 0x60 + i);
const signerML = ml_dsa65.keygen(signerSeed);
const signerP256 = hex(p256.getPublicKey(signerScalar, false));
const signerMLDSA65 = hex(signerML.publicKey);
const signerFingerprint = hex(sha256(Buffer.concat([enc.encode("sempere/1 device"), lp(deviceRecipient), lp(signerP256),
  lp(signerMLDSA65)])));
const lpList = (l: string[]): Buffer => Buffer.concat([lp(String(l.length)), ...[...l].sort().map((f) => lp(f))]);
const entryClaim = { key: deviceRecipient, signP256: signerP256, signMLDSA65: signerMLDSA65, kind: "ipad",
  added: "2026-10-04T16:20:00Z", addedEpoch: 1, addedBy: "recovery" };
const entryMessage = Buffer.concat([enc.encode("sempere/1 author entry"), lp(vaultId), lp(String(entryClaim.addedEpoch)),
  lp(entryClaim.key), lp(entryClaim.signP256), lp(entryClaim.signMLDSA65), lp(entryClaim.kind), lp(entryClaim.added),
  lp(entryClaim.addedBy)]);
// A resolve epoch, so that `recovery` and `rejected` (review M1, M2) are both in the signed bytes.
const epochFields = { root: hex(root), epoch: 2, epochId: e2.epochId, parent: e1.epochId, reason: "resolve",
  recovery: recoveryFingerprint, rejected: deviceFingerprint,
  list: [signerFingerprint, recoveryFingerprint], parentList: [signerFingerprint, recoveryFingerprint] };
const epochMessage = Buffer.concat([enc.encode("sempere/1 author epoch"), lp(vaultId), lp(epochFields.root),
  lp(String(epochFields.epoch)), lp(epochFields.epochId), lp(epochFields.parent), lp(epochFields.reason),
  lp(epochFields.recovery), lp(epochFields.rejected), lpList(epochFields.list), lpList(epochFields.parentList)]);
const features = ["zeta", "ñ/emoji ☕️", "zeta"];
const distinct = [...new Set(features)].sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
const manifestFields = { root: hex(root), epoch: 2, epochId: e2.epochId, epochRecordHash, format: "sempere/1", features };
const manifestMessage = Buffer.concat([enc.encode("sempere/1 author manifest"), lp(vaultId), lp(manifestFields.root),
  lp("2"), lp(manifestFields.epochId), lp(epochRecordHash), lp(sha256(listMessage)), lp("sempere/1"),
  lp(String(distinct.length)), ...distinct.map((f) => lp(f))]);
const nobleSig = (m: Uint8Array): AuthorSig => ({
  by: "noble",
  p256: hex(p256.sign(m, signerScalar, { prehash: true })),
  mldsa65: hex(ml_dsa65.sign(m, signerML.secretKey, { extraEntropy: false })),
});
const signed = (name: "entry" | "epoch" | "manifest", m: Uint8Array): SignedMessage => ({
  message: hex(m),
  signatures: [nobleSig(m), ...(previous?.signatures?.[name].signatures.filter((s) => s.by !== "noble") ?? [])],
});

// Join codes (design §6.2): the signer's device joins.
const words = readFileSync(join(import.meta.dirname, "..", "src", "vault", "bip39.ts"), "utf8")
  .split("\n").filter((l) => l.startsWith("  \"")).map((l) => l.trim().replace(/^"|",?$/g, "")).join(" ").split(" ");
if (words.length !== 2048) throw new Error("word list");
const sixWords = (d: Uint8Array): string[] => {
  const bits = Array.from(d.subarray(0, 9), (b) => b.toString(2).padStart(8, "0")).join("");
  return [0, 1, 2, 3, 4, 5].map((i) => words[parseInt(bits.slice(i * 11, i * 11 + 11), 2)] ?? "");
};
const joinKind = "iphone";
const commitment = sha256(Buffer.concat([enc.encode("sempere/1 join"), lp(vaultId), lp(deviceRecipient), lp(signerP256),
  lp(signerMLDSA65), lp(joinKind)]));
const reply = sha256(Buffer.concat([enc.encode("sempere/1 join reply"), lp(vaultId), lp(commitment), lp(hex(root))]));
const uuidBytes = Buffer.from(vaultId.replace(/-/g, ""), "hex");

const vectors = {
  description: "key-hierarchy design §2–§4 (KH1): fixed vault epoch keys → identity seed → vault identity and "
    + "recipient → §2.2 derived keys → link public keys; the root fingerprint of epoch 1; an epochLink from epoch 1 "
    + "into epoch 2 (both signatures must verify); device and recovery fingerprints; listMessage and listTag of an "
    + "epoch-2 list (lp() fields); wraps of K_2 to a fixed device key, made by two implementations; the three author "
    + "signatures (addSig, epochSig, authorSig) by a fixed signing pair, made by noble and swift-crypto; join codes. "
    + "Built to the "
    + "merged design (#61); the encodings it leaves open are format.md §15.1.",
  vaultId,
  device: { identity: deviceIdentity, recipient: deviceRecipient, signP256: deviceSignP256,
    signMLDSA65: deviceSignMLDSA65, fingerprint: deviceFingerprint, id: deviceFingerprint.slice(0, 8),
    captureFingerprint },
  recovery: { recipient: recoveryRecipient, fingerprint: recoveryFingerprint },
  epochs,
  root: hex(root),
  link: {
    epoch: 2,
    message: hex(linkMessage),
    links: [nobleLink, ...(previous?.link.links.filter((l) => l.by !== "noble") ?? [])],
  },
  listTag: { epoch: 2, root: hex(root), epochId: e2.epochId, epochRecordHash, entries, message: hex(listMessage), tag },
  wraps: [{ by: "typage", epoch: 2, armored: typageWrap }, ...(previous?.wraps.filter((w) => w.by !== "typage") ?? [])],
  signer: { p256Scalar: hex(signerScalar), mldsa65Seed: hex(signerSeed), p256: signerP256, mldsa65: signerMLDSA65,
    key: deviceRecipient, fingerprint: signerFingerprint },
  signatures: {
    entry: { claim: entryClaim, ...signed("entry", entryMessage) },
    epoch: { fields: epochFields, ...signed("epoch", epochMessage) },
    manifest: { fields: manifestFields, ...signed("manifest", manifestMessage) },
  },
  join: {
    request: { vaultId, key: deviceRecipient, sign: { p256: signerP256, mldsa65: signerMLDSA65 }, name: "Ñandú's iPhone",
      kind: joinKind, created: "2026-10-20T16:20:00Z" },
    commitment: hex(commitment), words: sixWords(commitment), qr: hex(Buffer.concat([uuidBytes, commitment])),
    root: hex(root), reply: hex(reply), replyWords: sixWords(reply),
    replyQR: `sempere-root:${vaultId}:${hex(root)}`,
  },
};
writeFileSync(out, JSON.stringify(vectors, null, 2) + "\n");
console.log(`wrote ${out}`);
