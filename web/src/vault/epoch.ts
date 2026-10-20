// The key schedule of the key hierarchy (docs/design/key-hierarchy.md, KH1):
// a vault epoch key K_e, the vault identity derived from it, the §2.2
// derivations, the wrap plaintext a reader opens, listTag, epochLink and the
// root fingerprint. Mirrors Sources/Sempere/EpochKeys.swift; the shared
// vectors are Tests/SempereTests/Fixtures/epoch-vectors.json.
//
// The viewer reads only: it opens wraps (never makes one) and keeps no trust
// record, so trust records v3 and wrap sealing are Swift-only. Nothing here is
// wired into the reader yet (KH2). Pure JavaScript (@noble, @scure), so it runs
// under the strict CSP (no WebAssembly).
//
// Provisional, as in the Swift file: the wrap plaintext (the kit reads it,
// review M8'), fingerprints and listMessage's field encoding (every vault.json
// value as its JSON text inside lp(), SHA-256(wrap) as its 32 raw bytes).
// Built to docs/design/key-hierarchy.md as merged (#61).

import { ed25519 } from "@noble/curves/ed25519.js";
import { hkdf } from "@noble/hashes/hkdf.js";
import { hmac } from "@noble/hashes/hmac.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { ml_dsa65 } from "@noble/post-quantum/ml-dsa.js";
import { bech32 } from "@scure/base";
import { identityToRecipient } from "age-encryption";
import { concat } from "./bytes.ts";
import { type LinkPublicKeys, type SecretLink, sizes, unhex } from "./link.ts";

const encoder = new TextEncoder();

/** The HKDF `info` strings of design §2.2 (RFC 5869, empty salt, L = 32). */
export const epochInfo = {
  identitySeed: "sempere/1 vault identity seed",
  tagKey: "sempere/1 body tag",
  blobNameKey: "sempere/1 blob name",
  listKey: "sempere/1 list key",
  markersKey: "sempere/1 markers key",
  epochId: "sempere/1 epoch id",
  linkEd25519Seed: "sempere/1 epoch link ed25519 seed",
  linkMLDSA65Seed: "sempere/1 epoch link ml-dsa-65 seed",
  pendingKey: "sempere/1 reencrypt pending key",
  deviceCaptureKey: "sempere/1 device capture key",
} as const;

/** HKDF-SHA256 of the 32-byte epoch key with an empty salt. */
export function deriveEpoch(key: Uint8Array, info: string | Uint8Array, length = 32): Uint8Array {
  if (key.length !== 32) throw new Error("a vault epoch key is 32 bytes");
  return hkdf(sha256, key, new Uint8Array(0), typeof info === "string" ? encoder.encode(info) : info, length);
}

/** Every key of design §2.2 for one epoch key. */
export interface EpochKeys {
  identitySeed: Uint8Array;
  /** `AGE-SECRET-KEY-PQ-1…`, the vault identity V_e. */
  identity: string;
  tagKey: Uint8Array;
  blobNameKey: Uint8Array;
  listKey: Uint8Array;
  markersKey: Uint8Array;
  epochId: Uint8Array;
  linkEd25519Seed: Uint8Array;
  linkMLDSA65Seed: Uint8Array;
  pendingKey: Uint8Array;
}

/** The vault identity string of a 32-byte X-Wing seed (as `age-keygen -pq` writes it). */
export function pqIdentity(seed: Uint8Array): string {
  return bech32.encodeFromBytes("AGE-SECRET-KEY-PQ-", seed).toUpperCase();
}

/** The keys of `key` (no X-Wing work: the recipient is `vaultRecipient`). */
export function epochKeys(key: Uint8Array): EpochKeys {
  const d = (info: string): Uint8Array => deriveEpoch(key, info);
  const identitySeed = d(epochInfo.identitySeed);
  return {
    identitySeed,
    identity: pqIdentity(identitySeed),
    tagKey: d(epochInfo.tagKey),
    blobNameKey: d(epochInfo.blobNameKey),
    listKey: d(epochInfo.listKey),
    markersKey: d(epochInfo.markersKey),
    epochId: d(epochInfo.epochId),
    linkEd25519Seed: d(epochInfo.linkEd25519Seed),
    linkMLDSA65Seed: d(epochInfo.linkMLDSA65Seed),
    pendingKey: d(epochInfo.pendingKey),
  };
}

/** The vault recipient v_e (`age1pq1…`). */
export async function vaultRecipient(key: Uint8Array): Promise<string> {
  return identityToRecipient(epochKeys(key).identity);
}

/** The device capture key of the device whose fingerprint is `fingerprint` (format.md §11.1). */
export function epochCaptureKey(key: Uint8Array, fingerprint: string): Uint8Array {
  return deriveEpoch(key, concat([encoder.encode(epochInfo.deviceCaptureKey), Uint8Array.of(0), encoder.encode(fingerprint)]));
}

/** The link public keys of an epoch (Ed25519 RFC 8032, ML-DSA-65 FIPS 204 KeyGen_internal). */
export function epochLinkPublicKeys(key: Uint8Array): LinkPublicKeys {
  const k = epochKeys(key);
  return { ed25519: ed25519.getPublicKey(k.linkEd25519Seed), mldsa65: ml_dsa65.keygen(k.linkMLDSA65Seed).publicKey };
}

/** `SHA-256("sempere/1" ‖ 0 ‖ "root" ‖ 0 ‖ vaultId ‖ 0 ‖ ed25519 ‖ mldsa65)` over epoch 1's link public keys. */
export function rootFingerprint(vaultId: string, epochOne: LinkPublicKeys): Uint8Array {
  return sha256(concat([encoder.encode("sempere/1"), Uint8Array.of(0), encoder.encode("root"), Uint8Array.of(0),
    encoder.encode(vaultId.toLowerCase()), Uint8Array.of(0), epochOne.ed25519, epochOne.mldsa65]));
}

/** `"sempere/1" ‖ 0 ‖ "epoch link" ‖ 0 ‖ vaultId ‖ 0 ‖ e ‖ 0 ‖ epochId(K_e)`, `e` in decimal. */
export function epochLinkMessage(vaultId: string, epoch: number, epochId: Uint8Array): Uint8Array {
  return concat([encoder.encode("sempere/1"), Uint8Array.of(0), encoder.encode("epoch link"), Uint8Array.of(0),
    encoder.encode(vaultId.toLowerCase()), Uint8Array.of(0), encoder.encode(String(epoch)), Uint8Array.of(0), epochId]);
}

/**
 * True when `link` is signed and BOTH signatures verify under the parent
 * epoch's link public keys over the link into epoch `epoch` (at least 2)
 * whose epochId is `childEpochId`.
 */
export function verifyEpochLink(link: SecretLink | undefined, keys: LinkPublicKeys, epoch: number,
  childEpochId: Uint8Array, vaultId: string): boolean {
  if (link?.kind !== "signed" || !Number.isSafeInteger(epoch) || epoch < 2 || childEpochId.length !== 32) return false;
  if (keys.ed25519.length !== sizes.ed25519PublicKey || keys.mldsa65.length !== sizes.mldsa65PublicKey) return false;
  const message = epochLinkMessage(vaultId, epoch, childEpochId);
  const check = (f: () => boolean): boolean => {
    try {
      return f();
    } catch {
      return false;
    }
  };
  const edValid = check(() => ed25519.verify(link.ed25519, message, keys.ed25519));
  const mlValid = check(() => ml_dsa65.verify(link.mldsa65, message, keys.mldsa65));
  return edValid && mlValid;
}

/** Why a wrap's plaintext was refused (design §4.3). */
export type WrapProblem = "malformed" | "otherEpoch" | "identityMismatch";

/**
 * The epoch key in a wrap's plaintext (design §3): exactly three lines, the
 * first naming `vaultId` and `epoch`, the identity the one derived from the
 * key. Returns the key or the problem.
 */
export function parseEpochWrap(plaintext: Uint8Array, vaultId: string, epoch: number):
  { key: Uint8Array } | { problem: WrapProblem } {
  if (plaintext.length > 1024) return { problem: "malformed" };
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(plaintext);
  } catch {
    return { problem: "malformed" };
  }
  if (!text.endsWith("\n")) return { problem: "malformed" };
  const lines = text.slice(0, -1).split("\n");
  const keyPrefix = "# sempere-epoch-key: ";
  const [first, second, third] = lines;
  if (lines.length !== 3 || first === undefined || second === undefined || third === undefined
    || !first.startsWith("# sempere vault key: ") || !second.startsWith(keyPrefix)) return { problem: "malformed" };
  const key = unhex(second.slice(keyPrefix.length), 32);
  if (!key || !/^AGE-SECRET-KEY-PQ-1[0-9A-Z]+$/.test(third)) return { problem: "malformed" };
  let seed: Uint8Array;
  try {
    const decoded = bech32.decodeToBytes(third);
    if (decoded.prefix.toUpperCase() !== "AGE-SECRET-KEY-PQ-" || decoded.bytes.length !== 32) return { problem: "malformed" };
    seed = decoded.bytes;
  } catch {
    return { problem: "malformed" };
  }
  if (first !== `# sempere vault key: vault ${vaultId.toLowerCase()}, epoch ${epoch}`) return { problem: "otherEpoch" };
  const derived = epochKeys(key).identitySeed;
  let diff = 0;
  for (let i = 0; i < 32; i++) diff |= (derived[i] ?? 0) ^ (seed[i] ?? 0);
  return diff === 0 ? { key } : { problem: "identityMismatch" };
}

/** `lp(x)` (design §3): the 4-byte big-endian length of `x`, then `x`; a string is its UTF-8, a number its decimal ASCII. */
export function lp(x: Uint8Array | string | number): Uint8Array {
  const b = typeof x === "number" ? encoder.encode(String(x)) : typeof x === "string" ? encoder.encode(x) : x;
  const out = new Uint8Array(4 + b.length);
  new DataView(out.buffer).setUint32(0, b.length);
  out.set(b, 4);
  return out;
}

/** `SHA-256("sempere/1 device" ‖ lp(key) ‖ lp(sign.p256) ‖ lp(sign.mldsa65))`, the signing keys as their hex text. */
export function deviceFingerprint(key: string, signP256: string, signMLDSA65: string): Uint8Array {
  return sha256(concat([encoder.encode("sempere/1 device"), lp(key), lp(signP256), lp(signMLDSA65)]));
}

/** `SHA-256("sempere/1 recovery" ‖ lp(key))`. */
export function recoveryFingerprint(key: string): Uint8Array {
  return sha256(concat([encoder.encode("sempere/1 recovery"), lp(key)]));
}

/** One `keys[]` entry as listMessage covers it: each field's JSON text, "" when absent. */
export interface ListTagEntry {
  role: string; key: string; id: string; signP256: string; signMLDSA65: string; kind: string; added: string;
  addedEpoch: string; addedBy: string; addSigP256: string; addSigMLDSA65: string; name: string; wrap: string;
}

const hexOf = (b: Uint8Array): string => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");

/** `listMessage` (design §4); `SHA-256(wrap)` as its 32 raw bytes. */
export function listTagMessage(vaultId: string, root: string, epoch: number, epochId: string, epochRecordHash: string,
  entries: ListTagEntry[]): Uint8Array {
  const parts = [encoder.encode("sempere/1 list"), lp(vaultId.toLowerCase()), lp(root), lp(epoch), lp(epochId),
    lp(epochRecordHash), lp(entries.length)];
  for (const e of entries) {
    for (const f of [e.role, e.key, e.id, e.signP256, e.signMLDSA65, e.kind, e.added, e.addedEpoch, e.addedBy,
      e.addSigP256, e.addSigMLDSA65, e.name]) parts.push(lp(f));
    parts.push(lp(sha256(encoder.encode(e.wrap))));
  }
  return concat(parts);
}

/** listTag (64 lowercase hex digits) under the epoch key. */
export function listTag(key: Uint8Array, vaultId: string, root: string, epoch: number, epochId: string,
  epochRecordHash: string, entries: ListTagEntry[]): string {
  return hexOf(hmac(sha256, epochKeys(key).listKey,
    listTagMessage(vaultId, root, epoch, epochId, epochRecordHash, entries)));
}
