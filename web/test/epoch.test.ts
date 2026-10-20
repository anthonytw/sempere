// The key schedule of the key hierarchy (docs/design/key-hierarchy.md §2–§4,
// KH1): web/src/vault/epoch.ts against the vectors shared with
// Tests/SempereTests/EpochKeysTests.swift (links made by noble and by
// swift-crypto, wraps made by typage and by Swift).

import { Decrypter, armor } from "age-encryption";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  type ListTagEntry, deviceFingerprint, epochCaptureKey, epochKeys, epochLinkMessage, epochLinkPublicKeys, listTag,
  listTagMessage, lp, parseEpochWrap, recoveryFingerprint, rootFingerprint, vaultRecipient, verifyEpochLink,
  entryMessage, epochMessage, joinCommitment, joinReply, manifestMessage, sixWords, verifyAuthorSignature,
} from "../src/vault/epoch.ts";
import type { SecretLink } from "../src/vault/link.ts";
import { fixtures } from "./support.ts";

interface Epoch {
  epoch: number; key: string; identitySeed: string; identity: string; recipient: string; tagKey: string;
  blobNameKey: string; listKey: string; markersKey: string; epochId: string; pendingKey: string; captureKey: string;
  linkEd25519Seed: string; linkMLDSA65Seed: string; ed25519PublicKey: string; mldsa65PublicKey: string;
  wrapPlaintext: string;
}
interface Vectors {
  vaultId: string;
  device: { identity: string; recipient: string; signP256: string; signMLDSA65: string; fingerprint: string; id: string;
    captureFingerprint: string };
  recovery: { recipient: string; fingerprint: string };
  epochs: Epoch[];
  root: string;
  link: { epoch: number; message: string; links: { by: string; ed25519: string; mldsa65: string }[] };
  listTag: { epoch: number; root: string; epochId: string; epochRecordHash: string; entries: ListTagEntry[];
    message: string; tag: string };
  wraps: { by: string; epoch: number; armored: string }[];
}

const v = JSON.parse(readFileSync(join(fixtures, "epoch-vectors.json"), "utf8")) as Vectors;
const bytes = (h: string): Uint8Array => Uint8Array.from(Buffer.from(h, "hex"));
const hex = (b: Uint8Array): string => Buffer.from(b).toString("hex");
const [e1, e2] = v.epochs;
if (!e1 || !e2) throw new Error("vectors need two epochs");
const enc = new TextEncoder();

describe("key hierarchy key schedule (design §2–§4)", () => {
  it("derives every key of the vectors", async () => {
    for (const e of v.epochs) {
      const k = epochKeys(bytes(e.key));
      expect(hex(k.identitySeed)).toBe(e.identitySeed);
      expect(k.identity).toBe(e.identity);
      expect(await vaultRecipient(bytes(e.key))).toBe(e.recipient);
      expect(hex(k.tagKey)).toBe(e.tagKey);
      expect(hex(k.blobNameKey)).toBe(e.blobNameKey);
      expect(hex(k.listKey)).toBe(e.listKey);
      expect(hex(k.markersKey)).toBe(e.markersKey);
      expect(hex(k.epochId)).toBe(e.epochId);
      expect(hex(k.pendingKey)).toBe(e.pendingKey);
      expect(hex(k.linkEd25519Seed)).toBe(e.linkEd25519Seed);
      expect(hex(k.linkMLDSA65Seed)).toBe(e.linkMLDSA65Seed);
      expect(hex(epochCaptureKey(bytes(e.key), v.device.captureFingerprint))).toBe(e.captureKey);
      const pub = epochLinkPublicKeys(bytes(e.key));
      expect(hex(pub.ed25519)).toBe(e.ed25519PublicKey);
      expect(hex(pub.mldsa65)).toBe(e.mldsa65PublicKey);
    }
  });

  it("computes the root and the fingerprints", () => {
    expect(hex(rootFingerprint(v.vaultId, epochLinkPublicKeys(bytes(e1.key))))).toBe(v.root);
    expect(hex(rootFingerprint(v.vaultId.toUpperCase(), epochLinkPublicKeys(bytes(e1.key))))).toBe(v.root);
    expect(hex(rootFingerprint(v.vaultId, epochLinkPublicKeys(bytes(e2.key))))).not.toBe(v.root);
    const d = v.device;
    expect(hex(deviceFingerprint(d.recipient, d.signP256, d.signMLDSA65))).toBe(d.fingerprint);
    expect(d.fingerprint.slice(0, 8)).toBe(d.id);
    expect(hex(recoveryFingerprint(v.recovery.recipient))).toBe(v.recovery.fingerprint);
    expect(Array.from(lp("ab"))).toEqual([0, 0, 0, 2, 0x61, 0x62]);
    expect(Array.from(lp(12))).toEqual([0, 0, 0, 2, 0x31, 0x32]);
  });

  it("verifies the epoch links made by noble and by swift-crypto", () => {
    const parent = epochLinkPublicKeys(bytes(e1.key));
    const childId = bytes(e2.epochId);
    expect(hex(epochLinkMessage(v.vaultId, 2, childId))).toBe(v.link.message);
    expect(v.link.links.map((l) => l.by).sort()).toEqual(["noble", "swift-crypto"]);
    for (const l of v.link.links) {
      const link: SecretLink = { kind: "signed", ed25519: bytes(l.ed25519), mldsa65: bytes(l.mldsa65) };
      expect(verifyEpochLink(link, parent, 2, childId, v.vaultId)).toBe(true);
      expect(verifyEpochLink(link, parent, 3, childId, v.vaultId)).toBe(false);
      expect(verifyEpochLink(link, parent, 1, childId, v.vaultId)).toBe(false);
      expect(verifyEpochLink(link, parent, 2, bytes(e1.epochId), v.vaultId)).toBe(false);
      expect(verifyEpochLink(link, parent, 2, childId, "00000000-0000-4000-8000-000000000000")).toBe(false);
      expect(verifyEpochLink(link, epochLinkPublicKeys(bytes(e2.key)), 2, childId, v.vaultId)).toBe(false);
      const flipped = bytes(l.mldsa65);
      flipped[100] = (flipped[100] ?? 0) ^ 1;
      expect(verifyEpochLink({ ...link, mldsa65: flipped }, parent, 2, childId, v.vaultId)).toBe(false);
      expect(verifyEpochLink({ ...link, ed25519: new Uint8Array(64) }, parent, 2, childId, v.vaultId)).toBe(false);
    }
    expect(verifyEpochLink({ kind: "malformed" }, parent, 2, childId, v.vaultId)).toBe(false);
    expect(verifyEpochLink(undefined, parent, 2, childId, v.vaultId)).toBe(false);
  });

  it("computes listMessage and listTag", () => {
    const t = v.listTag;
    const [device] = t.entries;
    expect([...(device?.name ?? "")].some((c) => (c.codePointAt(0) ?? 0) > 0x7f)).toBe(true);
    expect(device?.name).toContain("/");
    expect(device?.id).toBe(v.device.id);
    expect(hex(listTagMessage(v.vaultId, t.root, t.epoch, t.epochId, t.epochRecordHash, t.entries))).toBe(t.message);
    expect(listTag(bytes(e2.key), v.vaultId, t.root, t.epoch, t.epochId, t.epochRecordHash, t.entries)).toBe(t.tag);
    expect(listTag(bytes(e1.key), v.vaultId, t.root, t.epoch, t.epochId, t.epochRecordHash, t.entries)).not.toBe(t.tag);
    expect(listTag(bytes(e2.key), v.vaultId, t.root, t.epoch, t.epochId, t.epochRecordHash, [...t.entries].reverse()))
      .not.toBe(t.tag);
    if (!device) throw new Error("no entry");
    const renamed = [{ ...device, name: device.name + " " }, ...t.entries.slice(1)];
    expect(listTag(bytes(e2.key), v.vaultId, t.root, t.epoch, t.epochId, t.epochRecordHash, renamed)).not.toBe(t.tag);
  });

  it("opens the wraps made by typage and by Swift, and checks their plaintext", async () => {
    expect(v.wraps.map((w) => w.by).sort()).toEqual(["swift", "typage"]);
    for (const w of v.wraps) {
      const d = new Decrypter();
      d.addIdentity(v.device.identity);
      const plaintext = await d.decrypt(armor.decode(w.armored));
      expect(new TextDecoder().decode(plaintext)).toBe(e2.wrapPlaintext);
      const opened = parseEpochWrap(plaintext, v.vaultId, w.epoch);
      expect("key" in opened && hex(opened.key)).toBe(e2.key);
    }
    for (const e of v.epochs) {
      const opened = parseEpochWrap(enc.encode(e.wrapPlaintext), v.vaultId, e.epoch);
      expect("key" in opened && hex(opened.key)).toBe(e.key);
    }
    const p = e2.wrapPlaintext;
    const lines = p.split("\n");
    const swapped = [lines[0], lines[1], e1.identity, ""].join("\n");
    expect(parseEpochWrap(enc.encode(swapped), v.vaultId, 2)).toEqual({ problem: "identityMismatch" });
    expect(parseEpochWrap(enc.encode(p), v.vaultId, 3)).toEqual({ problem: "otherEpoch" });
    for (const bad of [p.slice(0, -1), p + "\n", p.replace(e2.key, e2.key.toUpperCase()), p.replace(/\n/g, "\r\n"),
      p.replace(e2.identity, e2.identity.toLowerCase()), "", "#".repeat(2000) + "\n"]) {
      expect(parseEpochWrap(enc.encode(bad), v.vaultId, 2)).toEqual({ problem: "malformed" });
    }
    expect(parseEpochWrap(Uint8Array.of(0xff, 0xfe, 0x0a), v.vaultId, 2)).toEqual({ problem: "malformed" });
  });
});

interface AuthorSig { by: string; p256: string; mldsa65: string }
interface Signatures {
  signer: { p256: string; mldsa65: string; key: string; fingerprint: string };
  signatures: {
    entry: { claim: { key: string; signP256: string; signMLDSA65: string; kind: string; added: string; addedEpoch: number;
      addedBy: string }; message: string; signatures: AuthorSig[] };
    epoch: { fields: { root: string; epoch: number; epochId: string; parent: string; reason: string; recovery: string;
      rejected: string; list: string[]; parentList: string[] }; message: string; signatures: AuthorSig[] };
    manifest: { fields: { root: string; epoch: number; epochId: string; epochRecordHash: string; format: string;
      features: string[] }; message: string; signatures: AuthorSig[] };
  };
  join: { request: { vaultId: string; key: string; sign: { p256: string; mldsa65: string }; kind: string };
    commitment: string; words: string[]; root: string; reply: string; replyWords: string[] };
}
const s = JSON.parse(readFileSync(join(fixtures, "epoch-vectors.json"), "utf8")) as Vectors & Signatures;

describe("author signatures and join codes (design §4.1, §6.2)", () => {
  const keys = { p256: bytes(s.signer.p256), mldsa65: bytes(s.signer.mldsa65) };
  const sig = (x: AuthorSig): { p256: Uint8Array; mldsa65: Uint8Array } => ({ p256: bytes(x.p256), mldsa65: bytes(x.mldsa65) });

  it("builds the three messages and verifies noble's and swift-crypto's signatures", () => {
    expect(hex(deviceFingerprint(s.signer.key, s.signer.p256, s.signer.mldsa65))).toBe(s.signer.fingerprint);
    const c = s.signatures.entry.claim;
    const entry = entryMessage(v.vaultId, c);
    expect(hex(entry)).toBe(s.signatures.entry.message);
    const f = s.signatures.epoch.fields;
    const epoch = epochMessage(v.vaultId, f.root, f.epoch, f.epochId, f.parent, f.reason, f.recovery, f.rejected, f.list,
      f.parentList);
    expect(hex(epoch)).toBe(s.signatures.epoch.message);
    expect(hex(epochMessage(v.vaultId, f.root, f.epoch, f.epochId, f.parent, f.reason, f.recovery, f.rejected,
      [...f.list].reverse(), [...f.parentList].reverse()))).toBe(s.signatures.epoch.message);
    const m = s.signatures.manifest.fields;
    const manifest = manifestMessage(v.vaultId, m.root, m.epoch, m.epochId, m.epochRecordHash, bytes(v.listTag.message),
      m.format, m.features);
    expect(hex(manifest)).toBe(s.signatures.manifest.message);
    const all: [Uint8Array, AuthorSig[]][] = [[entry, s.signatures.entry.signatures], [epoch, s.signatures.epoch.signatures],
      [manifest, s.signatures.manifest.signatures]];
    for (const [message, list] of all) {
      expect(list.map((x) => x.by).sort()).toEqual(["noble", "swift-crypto"]);
      for (const x of list) {
        expect(verifyAuthorSignature(message, sig(x), keys)).toBe(true);
        expect(verifyAuthorSignature(Uint8Array.of(...message, 0), sig(x), keys)).toBe(false);
        const flipped = sig(x);
        flipped.mldsa65[7] = (flipped.mldsa65[7] ?? 0) ^ 1;
        expect(verifyAuthorSignature(message, flipped, keys)).toBe(false);
        expect(verifyAuthorSignature(message, { ...sig(x), p256: new Uint8Array(64) }, keys)).toBe(false);
      }
    }
  });

  it("computes the join commitment, words and reverse code", () => {
    const r = s.join.request;
    const c = joinCommitment(r.vaultId, r.key, r.sign.p256, r.sign.mldsa65, r.kind);
    expect(hex(c)).toBe(s.join.commitment);
    expect(sixWords(c)).toEqual(s.join.words);
    const reply = joinReply(r.vaultId, c, s.join.root);
    expect(hex(reply)).toBe(s.join.reply);
    expect(sixWords(reply)).toEqual(s.join.replyWords);
  });
});

interface ChainEntryJSON {
  epoch: number; epochId: string; parent?: string; linkPublicKeys: { ed25519: string; mldsa65: string };
  link?: { ed25519: string; mldsa65: string }; reason: string; list: string[]; parentList: string[];
  recovery: string; rejected?: string;
  author: { key: string; p256: string; mldsa65: string }; epochSig: { p256: string; mldsa65: string };
  additions?: { key: string; sign: { p256: string; mldsa65: string }; kind: string; added: string; addedEpoch: number;
    addedBy: string; addSig: { p256: string; mldsa65: string } }[];
}
interface ChainCase { name: string; root: string; expect: string; chain: ChainEntryJSON[] }

describe("the shared chain vectors (design §4.1, §4.3)", () => {
  const cv = JSON.parse(readFileSync(join(fixtures, "epoch-chain-vectors.json"), "utf8")) as
    { vaultId: string; cases: ChainCase[] };
  const linkKeys = (e: ChainEntryJSON): { ed25519: Uint8Array; mldsa65: Uint8Array } =>
    ({ ed25519: bytes(e.linkPublicKeys.ed25519), mldsa65: bytes(e.linkPublicKeys.mldsa65) });

  it("verifies every link, epochSig and addSig of the chain that verifies in Swift", () => {
    const ok = cv.cases[0];
    if (!ok) throw new Error("no case");
    expect(ok.expect.startsWith("ok")).toBe(true);
    const [first] = ok.chain;
    if (!first) throw new Error("empty chain");
    expect(hex(rootFingerprint(cv.vaultId, linkKeys(first)))).toBe(ok.root);
    let additions = 0;
    ok.chain.forEach((e, i) => {
      const author = { p256: bytes(e.author.p256), mldsa65: bytes(e.author.mldsa65) };
      const m = epochMessage(cv.vaultId, ok.root, e.epoch, e.epochId, e.parent ?? "", e.reason, e.recovery, e.rejected ?? "",
        e.list, e.parentList);
      expect(verifyAuthorSignature(m, { p256: bytes(e.epochSig.p256), mldsa65: bytes(e.epochSig.mldsa65) }, author)).toBe(true);
      const prev = ok.chain[i - 1];
      if (prev && e.link) {
        const link: SecretLink = { kind: "signed", ed25519: bytes(e.link.ed25519), mldsa65: bytes(e.link.mldsa65) };
        expect(verifyEpochLink(link, linkKeys(prev), e.epoch, bytes(e.epochId), cv.vaultId)).toBe(true);
      }
      for (const a of e.additions ?? []) {
        const claim = { key: a.key, signP256: a.sign.p256, signMLDSA65: a.sign.mldsa65, kind: a.kind, added: a.added,
          addedEpoch: a.addedEpoch, addedBy: a.addedBy };
        const own = { p256: bytes(a.sign.p256), mldsa65: bytes(a.sign.mldsa65) };
        // In this vector the approver of every non-kit addition is epoch 1's author.
        const signedBy = a.addedBy === "recovery" ? own : author;
        expect(verifyAuthorSignature(entryMessage(cv.vaultId, claim), { p256: bytes(a.addSig.p256),
          mldsa65: bytes(a.addSig.mldsa65) }, signedBy)).toBe(true);
        additions++;
      }
    });
    expect(additions).toBe(2);
  });

  it("finds the broken link of the negative vector", () => {
    const broken = cv.cases.find((c) => c.expect === "brokenLink:2");
    const [e1, e2] = broken?.chain ?? [];
    if (!e1 || !e2?.link) throw new Error("no case");
    const link: SecretLink = { kind: "signed", ed25519: bytes(e2.link.ed25519), mldsa65: bytes(e2.link.mldsa65) };
    expect(verifyEpochLink(link, linkKeys(e1), 2, bytes(e2.epochId), cv.vaultId)).toBe(false);
  });
});
