// Opening a vault (format.md §15.3, §15.2) and reading one revision file (§4, §5): vault.json of the
// key hierarchy, the wrap a key the user supplies opens, the epoch key K_e and what derives from it,
// age decryption with typage under the vault identity V_e, the `SMPR` framing, the HMAC tag under
// `tagKey`, gunzip and JSON. Nothing here touches the network or the DOM.
//
// Above epoch 1 the viewer also reads files under earlier epochs' keys, by the acceptance rule of
// format.md §15.14: the keys come from the epoch records (each holds its parent's key and sealed set),
// and a file under an earlier key is read only when the record that closed its epoch seals its path with
// exactly its bytes; anything else under an old key is "set aside" (reported, never shown). A record that
// does not arrive or open stops the walk: files under the keys below it are reported as unreadable. It
// keeps no trust record, so it reports what vault.json says by itself (`ListStatus`).

import { t } from "../i18n/index.ts";
import { Decrypter, armor, identityToRecipient } from "age-encryption";
import { sha256 } from "@noble/hashes/sha2.js";
import { DecodeError, arrayOf, int, isObject, obj, opt, optWith, reqWith, str, uuid } from "../format/json.ts";
import { cmpUTF8, parseRevisionName, revisionFilename } from "../format/ids.ts";
import { type Revision, decodeRevision } from "../format/model.ts";
import { formatMajor, majorOf, manifestReadOnlyReasons, revisionMarkersNewer } from "../format/newer.ts";
import { parseRFC3339 } from "../format/rfc3339.ts";
import { concat } from "./bytes.ts";
import {
  type EpochKeys, deviceFingerprint, entryMessage, epochKeys, epochLinkPublicKeys, epochMessage, listTag, listTagMessage,
  manifestMessage, parseEpochWrap, recoveryFingerprint, rootFingerprint, verifyAuthorSignature, verifyEpochLink,
} from "./epoch.ts";
import { gunzip } from "./gzip.ts";
import { type SecretLink, parseSecretLink, unhex } from "./link.ts";

/** format.md §9 limits. */
export const limits = {
  revisionBytes: 256 * 1024 * 1024,
  manifestBytes: 16 * 1024 * 1024,
  /** An epoch record, file and gunzipped JSON (format.md §15.6). */
  epochRecordBytes: 64 * 1024 * 1024,
  /** One wrap (format.md §15.3). */
  wrapBytes: 16 * 1024,
};

export type VaultErrorCode =
  | "manifestCorrupt" | "unsupportedFormat" | "badIdentity" | "classicIdentity" | "wrongKey"
  | "keyNotListed" | "invalidWrap" | "tamperedList";

/** Why a vault cannot be opened or unlocked. */
export class VaultError extends Error {
  constructor(public readonly code: VaultErrorCode, message: string) {
    super(message);
    this.name = "VaultError";
  }
}

/** `newer`: written by a newer version and not readable by this one (format.md §7.2, §7.4). */
/** `setAside`: under an earlier epoch's key and not sealed with these bytes (format.md §15.14): never read. */
export type RevisionErrorCode = "undecryptable" | "tagMismatch" | "corruptBody" | "undecodable" | "newer" | "setAside";

/** Why one revision file could not be read; reported, never silently dropped (§4). */
export class RevisionReadError extends Error {
  constructor(public readonly code: RevisionErrorCode, message: string) {
    super(message);
    this.name = "RevisionReadError";
  }
}

/** A pair of hex signatures or signing keys, as `vault.json` writes them. */
export interface HexPair {
  p256: string;
  mldsa65: string;
}

/** One entry of `keys` (format.md §15.3). */
export interface ManifestKey {
  role: "device" | "recovery";
  key: string;
  /** Devices only. */
  id?: string;
  sign?: HexPair;
  kind?: string;
  added: string;
  addedEpoch?: number;
  addedBy?: string;
  addSig?: HexPair;
  /** The device's name (the recovery entry's is "Recovery kit"). */
  name: string;
  wrap: string;
}

/** `vault.json` of the key hierarchy (format.md §15.3). Hex values are lowercase text, as written. */
export interface VaultManifest {
  format: string;
  vaultId: string;
  created: string;
  root: string;
  epoch: number;
  epochId: string;
  parent?: string;
  epochRecord: string;
  epochRecordHash: string;
  keys: ManifestKey[];
  listTag: string;
  epochLink?: SecretLink;
  epochAuthor: string;
  epochSig: HexPair;
  markersTag: string;
  author: string;
  authorSig: HexPair;
  features: string[];
  label?: string;
  /** Binds an unfinished re-encryption journal (format.md §15.8); the viewer does not read the journal. */
  reencryptPending?: string;
  parentList: string[];
  epochReason: string;
  home: string;
  recoverySig?: HexPair;
}

/** The epoch reasons of format.md §15.7. */
const reasons = new Set(["create", "remove", "recovery", "reencrypt", "handoff", "takeover"]);
const sizes = { p256Sig: 128, mldsaSig: 6618, p256Key: 130, mldsaKey: 3904 };
const bech32 = /^[02-9ac-hj-np-z]+$/;

/** True for a post-quantum age recipient (`age1pq1…`) that is well formed on its face. */
export function isPQRecipient(key: string): boolean {
  const k = key.toLowerCase();
  return key === k && k.startsWith("age1pq1") && bech32.test(k.slice(7)) && k.length > 20;
}

function hexField(v: unknown, path: string, bytes: number): string {
  const s = str(v, path);
  if (!unhex(s, bytes)) throw new DecodeError(`${path}: expected ${2 * bytes} lowercase hex digits`);
  return s;
}

function pair(v: unknown, path: string, p: number, m: number): HexPair {
  const o = obj(v, path);
  return { p256: hexField(o.p256, `${path}.p256`, p / 2), mldsa65: hexField(o.mldsa65, `${path}.mldsa65`, m / 2) };
}

const sigPair = (v: unknown, path: string): HexPair => pair(v, path, sizes.p256Sig, sizes.mldsaSig);
const keyPair = (v: unknown, path: string): HexPair => pair(v, path, sizes.p256Key, sizes.mldsaKey);

function manifestKey(v: unknown, path: string): ManifestKey {
  const o = obj(v, path);
  const role = reqWith(o, "role", path, str);
  if (role !== "device" && role !== "recovery") throw new DecodeError(`${path}.role: unknown role`);
  const k: ManifestKey = {
    role,
    key: reqWith(o, "key", path, str),
    added: reqWith(o, "added", path, str),
    name: reqWith(o, "name", path, str),
    wrap: reqWith(o, "wrap", path, str),
  };
  if (k.wrap.length > limits.wrapBytes) throw new DecodeError(`${path}.wrap: too large`);
  const id = optWith(o, "id", path, str);
  const sign = optWith(o, "sign", path, keyPair);
  const kind = optWith(o, "kind", path, str);
  const addedEpoch = optWith(o, "addedEpoch", path, int);
  const addedBy = optWith(o, "addedBy", path, str);
  const addSig = optWith(o, "addSig", path, sigPair);
  if (id !== undefined) k.id = id;
  if (sign) k.sign = sign;
  if (kind !== undefined) k.kind = kind;
  if (addedEpoch !== undefined) k.addedEpoch = addedEpoch;
  if (addedBy !== undefined) k.addedBy = addedBy;
  if (addSig) k.addSig = addSig;
  return k;
}

/** The fingerprint of an entry (format.md §15.4), 64 hex digits; undefined without signing keys. */
export function entryFingerprint(k: ManifestKey): string | undefined {
  if (!k.sign) return undefined;
  const f = k.role === "device" ? deviceFingerprint : recoveryFingerprint;
  return hex(f(k.key, k.sign.p256, k.sign.mldsa65));
}

/** Parses and validates `vault.json`'s structure (format.md §15.3). Signatures and tags are checked by `checkManifest`. */
export function parseManifest(bytes: Uint8Array): VaultManifest {
  if (bytes.length > limits.manifestBytes) throw new VaultError("manifestCorrupt", "vault.json is larger than 16 MiB");
  let json: unknown;
  try {
    json = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch (e) {
    throw new VaultError("manifestCorrupt", `vault.json is not JSON: ${String(e)}`);
  }
  let m: VaultManifest;
  try {
    const o = obj(json, "$");
    const created = reqWith(o, "created", "$", str);
    if (parseRFC3339(created) === undefined) throw new DecodeError("$.created: bad date");
    const parent = optWith(o, "parent", "$", (v, p) => hexField(v, p, 32));
    const link = opt(o, "epochLink");
    const label = opt(o, "label");
    const recoverySig = optWith(o, "recoverySig", "$", sigPair);
    m = {
      format: reqWith(o, "format", "$", str),
      vaultId: reqWith(o, "vaultId", "$", uuid),
      created,
      root: reqWith(o, "root", "$", (v, p) => hexField(v, p, 32)),
      epoch: reqWith(o, "epoch", "$", int),
      epochId: reqWith(o, "epochId", "$", (v, p) => hexField(v, p, 32)),
      epochRecord: reqWith(o, "epochRecord", "$", str),
      epochRecordHash: reqWith(o, "epochRecordHash", "$", (v, p) => hexField(v, p, 32)),
      keys: reqWith(o, "keys", "$", (v, p) => arrayOf(v, p, manifestKey)),
      listTag: reqWith(o, "listTag", "$", str),
      epochAuthor: reqWith(o, "epochAuthor", "$", str),
      epochSig: reqWith(o, "epochSig", "$", sigPair),
      markersTag: reqWith(o, "markersTag", "$", str),
      author: reqWith(o, "author", "$", str),
      authorSig: reqWith(o, "authorSig", "$", sigPair),
      // An array of strings (§2) or absent, as Swift's decodeIfPresent([String]).
      features: optWith(o, "features", "$", (v, p) => arrayOf(v, p, str)) ?? [],
      parentList: optWith(o, "parentList", "$", (v, p) => arrayOf(v, p, (e, q) => hexField(e, q, 32))) ?? [],
      epochReason: reqWith(o, "epochReason", "$", str),
      home: reqWith(o, "home", "$", (v, p) => hexField(v, p, 32)),
    };
    if (parent) m.parent = parent;
    // Informational and covered by nothing (§2): anything but a string reads as absent.
    if (typeof label === "string") m.label = label;
    if (recoverySig) m.recoverySig = recoverySig;
    const pending = optWith(o, "reencryptPending", "$", str);
    if (pending !== undefined) m.reencryptPending = pending;
    if (link !== undefined && link !== null) {
      const parsed = parseSecretLink(link);
      if (parsed?.kind !== "signed") throw new DecodeError("$.epochLink: not a signature pair");
      m.epochLink = parsed;
    }
  } catch (e) {
    // A later major that does not decode cannot be opened even read-only (§7.2).
    if (isObject(json) && typeof json.format === "string" && (majorOf(json.format) ?? 0) > formatMajor) {
      throw new VaultError("unsupportedFormat", `vault format ${json.format} cannot be read by this viewer`);
    }
    throw new VaultError("manifestCorrupt", e instanceof Error ? e.message : String(e));
  }
  // A later major opens read-only, which the viewer always is (format.md §7.3).
  const major = majorOf(m.format);
  if (major === undefined) throw new VaultError("unsupportedFormat", `unsupported vault format ${m.format.slice(0, 64)}`);
  const bad = (why: string): never => {
    throw new VaultError("manifestCorrupt", why);
  };
  if (m.epoch < 1) bad("epoch is below 1");
  if ((m.epoch === 1) !== (m.parent === undefined) || (m.epoch === 1) !== (m.epochLink === undefined)) {
    bad("epoch, parent and epochLink disagree");
  }
  if (m.epochRecord !== `epochs/${m.epoch}-${m.epochId.slice(0, 16)}.epoch.age`) bad("epochRecord is not this epoch's record");
  if (m.keys.filter((k) => k.role === "recovery").length !== 1) bad("not one recovery entry");
  if (!m.keys.some((k) => k.role === "device")) bad("no device entry");
  if (!reasons.has(m.epochReason) || (m.epoch === 1) !== (m.epochReason === "create")
    || (m.epochReason === "takeover" && !m.recoverySig) || (m.recoverySig && !["takeover", "recovery", "reencrypt"].includes(m.epochReason))
    || (m.epoch === 1) !== (m.parentList.length === 0)) bad("epochReason, recoverySig or parentList");
  const homeEntry = m.keys.find((k) => k.role === "device" && entryFingerprint(k) === m.home);
  const homeId = m.home.slice(0, 8);
  if (!homeEntry || !(m.epochAuthor === homeId || m.epochReason === "handoff") || !(m.author === homeId || m.author === m.epochAuthor)) {
    bad("home is not a listed device, or not the author");
  }
  const seen = new Set<string>();
  for (const k of m.keys) {
    // A later major may list key types this version does not know; it opens with the entry its key opens.
    if (!(isPQRecipient(k.key) || major > formatMajor) || seen.has(k.key)) bad("a key that is not post-quantum, or listed twice");
    seen.add(k.key);
    if (!isPQRecipient(k.key)) continue;
    if (k.role === "device") {
      const f = entryFingerprint(k);
      if (!f || k.kind === undefined || k.addedEpoch === undefined || k.addedBy === undefined || !k.addSig || k.id !== f.slice(0, 8)) {
        bad(`device entry ${k.id ?? "?"}`);
      }
    } else if (!k.sign || k.id !== undefined || k.kind !== undefined || k.addedEpoch !== undefined || k.addedBy !== undefined || k.addSig) {
      bad("recovery entry without its signing keys, or with device fields");
    }
  }
  return m;
}

/**
 * Why the vault is read-only for this version (format.md §7.3): a later
 * `format`, unknown `features`. The viewer never writes; this is what it reports.
 */
export function readOnlyReasons(m: VaultManifest): string[] {
  return manifestReadOnlyReasons(m.format, m.features);
}

/** The device entries of the vault, as the capture attribution lists them (format.md §11.1). */
export function deviceEntries(m: VaultManifest): { key: string; label: string }[] {
  return m.keys.filter((k) => k.role === "device").map((k) => ({ key: k.key, label: k.name }));
}

/**
 * The identity in pasted text: an `age-keygen -pq` file, a device key file, the recovery key or the bare
 * `AGE-SECRET-KEY-PQ-1…` line. Comments and blank lines are ignored.
 */
export function parseIdentity(text: string): string {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0 && !l.startsWith("#"));
  const pq = lines.filter((l) => l.toUpperCase().startsWith("AGE-SECRET-KEY-PQ-1"));
  if (pq.length > 1) throw new VaultError("badIdentity", "paste one key, not several");
  const [key] = pq;
  if (key !== undefined) return key.toUpperCase();
  if (lines.some((l) => l.toUpperCase().startsWith("AGE-SECRET-KEY-1"))) {
    throw new VaultError("classicIdentity",
      "this is a classic (X25519) key; Sempere vaults use post-quantum keys (AGE-SECRET-KEY-PQ-1…)");
  }
  throw new VaultError("badIdentity", "no AGE-SECRET-KEY-PQ-1… key found in the pasted text");
}

const encoder = new TextEncoder();

const magic = [0x53, 0x4d, 0x50, 0x52];
const headerSize = 37;

function buf(b: Uint8Array): Uint8Array<ArrayBuffer> {
  return b as Uint8Array<ArrayBuffer>;
}

async function hmacKey(secret: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", buf(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

async function hkdfKey(secret: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", buf(secret), "HKDF", false, ["deriveKey"]);
}

function equalStrings(given: string, expected: string): boolean {
  let diff = given.length ^ expected.length;
  for (let i = 0; i < expected.length; i++) diff |= (given.charCodeAt(i) || 0) ^ expected.charCodeAt(i);
  return diff === 0;
}

/**
 * `markersTag` (lowercase hex) of `format` and `features` (format.md §2.1 "Version markers": the
 * distinct features sorted by UTF-8 bytes) under `markersKey` of `K_e`; undefined when a marker
 * holds a NUL (never tagged).
 */
export async function markersTag(vaultId: string, format: string, features: string[], markersKey: Uint8Array): Promise<string | undefined> {
  if (format.includes("\0") || features.some((f) => f.includes("\0"))) return undefined;
  // Code point order is UTF-8 byte order (as Swift sorts them).
  const sorted = [...new Set(features)].sort(cmpUTF8).map((f) => encoder.encode(f));
  const parts: Uint8Array[] = [encoder.encode("sempere/1"), Uint8Array.of(0), encoder.encode("markers"), Uint8Array.of(0),
    encoder.encode(vaultId.toLowerCase()), Uint8Array.of(0), encoder.encode(format)];
  for (const f of sorted) parts.push(Uint8Array.of(0), f);
  const key = await hmacKey(markersKey);
  return hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, buf(concat(parts)))));
}

/**
 * What vault.json says about itself, checked without a trust record or a chain: `verified`, or `tampered`
 * with the first check that failed. The viewer reports; the app or the CLI repairs.
 * - `markersTag`: `format` and `features` do not verify under `markersKey`;
 * - `root`: `root` is not the fingerprint of epoch 1's link keys (from `K_1`, or the epoch record's chain);
 * - `epochRecord`: the record is missing, does not match `epochRecordHash`, does not open, or disagrees;
 * - `epochLink`: the link into this epoch does not verify under the previous epoch's link keys (record);
 * - `epochSig`, `recoverySig`: a signature does not verify under the signing keys vault.json lists;
 * - `addSig`: an entry added in this epoch is not approved by home;
 * - `authorSig`: vault.json is not signed by home (or by the epoch author who wrote a handoff).
 * Not checked here (Swift's `EpochChain.verify` and the trust record do): the chain of earlier epochs, that the
 * signer of an epoch above 1 is the PARENT's home, a takeover's recovery rule, and that the list is the one this
 * device pinned. A viewer therefore cannot see a rolled-back or re-signed-by-a-stolen-home vault.json.
 */
export type ListProblem = "markersTag" | "root" | "epochRecord" | "epochLink" | "epochSig" | "recoverySig" | "addSig" | "authorSig";

export type ListStatus = { status: "verified" } | { status: "tampered"; reason: ListProblem };

/** What the viewer says about a list that does not check, or undefined. */
export function listWarningText(status: ListStatus | undefined): string | undefined {
  if (status?.status !== "tampered") return undefined;
  switch (status.reason) {
    case "markersTag":
      return t("This vault's format and features do not match their authentication tag. Notes still read correctly here, but the Sempere app and CLI will not write to it until it is repaired (sempere vault markers repair).");
    case "root":
    case "epochRecord":
    case "epochLink":
      return t("This vault's key history does not check (its epoch record or root). Notes still read correctly here, but the Sempere app and CLI will not trust it until it is repaired (sempere vault verify).");
    case "epochSig":
    case "recoverySig":
    case "addSig":
    case "authorSig":
      return t("This vault's device list was not signed by the vault's home device. Notes still read correctly here, but the Sempere app and CLI will not write to it until it is repaired (sempere vault verify).");
  }
}

function sigBytes(s: HexPair): { p256: Uint8Array; mldsa65: Uint8Array } {
  return { p256: unhex(s.p256, s.p256.length / 2) ?? new Uint8Array(), mldsa65: unhex(s.mldsa65, s.mldsa65.length / 2) ?? new Uint8Array() };
}

function listEntries(m: VaultManifest) {
  return m.keys.map((k) => ({
    role: k.role, key: k.key, id: k.id ?? "", signP256: k.sign?.p256 ?? "", signMLDSA65: k.sign?.mldsa65 ?? "",
    kind: k.kind ?? "", added: k.added, addedEpoch: k.addedEpoch === undefined ? "" : String(k.addedEpoch),
    addedBy: k.addedBy ?? "", addSigP256: k.addSig?.p256 ?? "", addSigMLDSA65: k.addSig?.mldsa65 ?? "", name: k.name, wrap: k.wrap,
  }));
}

/**
 * The checks that need `K_e` only (format.md §15.3): `listTag`. A manifest that fails it was not written by a
 * holder of the epoch key, so the vault is refused (`tamperedList`).
 */
export function checkListTag(m: VaultManifest, key: Uint8Array): boolean {
  return equalStrings(m.listTag, listTag(key, m.vaultId, m.root, m.epoch, m.epochId, m.epochRecordHash, listEntries(m)));
}

interface ChainLinks {
  rootKeys?: { ed25519: Uint8Array; mldsa65: Uint8Array };
  previousKeys?: { ed25519: Uint8Array; mldsa65: Uint8Array };
}

/** The link public keys the record's chain gives for epoch 1 and epoch `epoch - 1`; undefined for a record that does not parse. */
function chainLinks(record: unknown, epoch: number): ChainLinks | undefined {
  if (!isObject(record) || !Array.isArray(record.chain)) return undefined;
  const chain: unknown[] = record.chain;
  const keysAt = (i: number): ChainLinks["rootKeys"] => {
    const entry = chain[i];
    if (!isObject(entry) || !isObject(entry.linkPublicKeys)) return undefined;
    const ed = unhex(entry.linkPublicKeys.ed25519, 32), ml = unhex(entry.linkPublicKeys.mldsa65, 1952);
    return ed && ml ? { ed25519: ed, mldsa65: ml } : undefined;
  };
  const out: ChainLinks = {};
  const first = keysAt(0), previous = epoch > 1 ? keysAt(epoch - 2) : undefined;
  if (first) out.rootKeys = first;
  if (previous) out.previousKeys = previous;
  return out;
}

/**
 * The checks of `ListStatus` over a manifest whose `listTag` verified under `key` (`keys`, derived from it).
 * `record` is the epoch record file (`m.epochRecord`) as stored, undefined when it could not be read.
 */
export async function checkManifest(m: VaultManifest, key: Uint8Array, keys: EpochKeys, record: Uint8Array | undefined,
  decrypt: (data: Uint8Array) => Promise<Uint8Array>): Promise<ListStatus> {
  const tampered = (reason: ListProblem): ListStatus => ({ status: "tampered", reason });
  const expectedMarkers = await markersTag(m.vaultId, m.format, m.features, keys.markersKey);
  if (expectedMarkers === undefined || !equalStrings(m.markersTag, expectedMarkers)) return tampered("markersTag");
  // The epoch record: the file vault.json names, opened under V_e, whose chain gives the link keys.
  let chain: ChainLinks | undefined;
  if (!record || hex(sha256(record)) !== m.epochRecordHash) return tampered("epochRecord");
  try {
    const name = m.epochRecord.slice("epochs/".length);
    const plain = await decrypt(record);
    const gz = await openFrame(plain, "epochs", name, keys.tagKey);
    const json: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(await gunzip(gz, limits.epochRecordBytes)));
    if (!isObject(json) || json.vaultId !== m.vaultId || json.root !== m.root || json.epoch !== m.epoch || json.epochId !== m.epochId) {
      return tampered("epochRecord");
    }
    chain = chainLinks(json, m.epoch);
  } catch {
    return tampered("epochRecord");
  }
  // root: SHA-256 of epoch 1's link keys (K_1's at epoch 1; the record's chain above).
  const rootKeys = m.epoch === 1 ? epochLinkPublicKeys(key) : chain?.rootKeys;
  if (!rootKeys || hex(rootFingerprint(m.vaultId, rootKeys)) !== m.root) return tampered("root");
  if (m.epoch > 1) {
    if (!chain?.previousKeys || !verifyEpochLink(m.epochLink, chain.previousKeys, m.epoch, unhex(m.epochId, 32) ?? new Uint8Array(), m.vaultId)) {
      return tampered("epochLink");
    }
  }
  // Signatures, under the signing keys the file lists.
  const recoveryEntry = m.keys.find((k) => k.role === "recovery");
  const recovery = recoveryEntry ? entryFingerprint(recoveryEntry) : undefined;
  const homeEntry = m.keys.find((k) => k.role === "device" && entryFingerprint(k) === m.home);
  if (!recovery || !recoveryEntry?.sign || !homeEntry?.sign) return tampered("epochSig");
  const first = m.keys.filter((k) => k.role === "recovery" || (k.addedEpoch ?? 0) < m.epoch || entryFingerprint(k) === m.home)
    .map((k) => entryFingerprint(k) ?? "");
  const message = epochMessage(m.vaultId, m.root, m.epoch, m.epochId, m.parent ?? "", m.epochReason, recovery, m.home, first, m.parentList);
  const epochSigner = m.keys.find((k) => k.role === "device" && k.id === m.epochAuthor);
  if (!epochSigner?.sign || !verifyAuthorSignature(message, sigBytes(m.epochSig), sigBytes(epochSigner.sign))) return tampered("epochSig");
  if (m.recoverySig && !verifyAuthorSignature(message, sigBytes(m.recoverySig), sigBytes(recoveryEntry.sign))) return tampered("recoverySig");
  // An entry outside the first list is an addition of this epoch, approved by home.
  const firstSet = new Set(first);
  for (const k of m.keys) {
    const f = entryFingerprint(k);
    if (k.role !== "device" || !f || firstSet.has(f)) continue;
    const claim = k.sign && k.kind !== undefined && k.addedEpoch !== undefined && k.addedBy !== undefined && k.addSig
      ? { key: k.key, signP256: k.sign.p256, signMLDSA65: k.sign.mldsa65, kind: k.kind, added: k.added, addedEpoch: k.addedEpoch, addedBy: k.addedBy }
      : undefined;
    const approver = claim?.addedBy === "recovery" ? recoveryEntry.sign : homeEntry.id === claim?.addedBy ? homeEntry.sign : undefined;
    if (!claim || !k.addSig || claim.addedEpoch !== m.epoch || !approver
      || !verifyAuthorSignature(entryMessage(m.vaultId, claim), sigBytes(k.addSig), sigBytes(approver))) return tampered("addSig");
  }
  // authorSig: by home, or by the epoch author when it is `author` (the old home writing its handoff).
  const writer = m.author === homeEntry.id ? homeEntry : m.author === epochSigner.id ? epochSigner : undefined;
  const manifest = manifestMessage(m.vaultId, m.root, m.epoch, m.epochId, m.epochRecordHash,
    listTagMessage(m.vaultId, m.root, m.epoch, m.epochId, m.epochRecordHash, listEntries(m)), m.format, m.features);
  if (!writer?.sign || !verifyAuthorSignature(manifest, sigBytes(m.authorSig), sigBytes(writer.sign))) return tampered("authorSig");
  return { status: "verified" };
}

/**
 * Checks the framing of format.md §4 on a decrypted body and returns its gzip bytes: magic, version, then the
 * HMAC tag under `tagKey` over `"sempere/1" ‖ 0 ‖ label ‖ 0 ‖ filename ‖ 0 ‖ gzip` (`label` is the note id, or
 * `epochs` for an epoch record).
 */
async function openFrame(plain: Uint8Array, label: string, filename: string, tagKey: Uint8Array): Promise<Uint8Array> {
  if (plain.length < headerSize) throw new RevisionReadError("corruptBody", "body shorter than its header");
  if (!magic.every((b, i) => plain[i] === b)) throw new RevisionReadError("corruptBody", "body does not start with SMPR");
  if ((plain[4] ?? 0) > 1) throw new RevisionReadError("newer", `written by a newer version (body version ${plain[4]})`);
  if (plain[4] !== 1) throw new RevisionReadError("corruptBody", `unsupported body version ${plain[4]}`);
  const tag = plain.subarray(5, headerSize);
  const gz = plain.subarray(headerSize);
  const message = concat([encoder.encode("sempere/1"), Uint8Array.of(0), encoder.encode(label), Uint8Array.of(0),
    encoder.encode(filename), Uint8Array.of(0), gz]);
  if (!await crypto.subtle.verify("HMAC", await hmacKey(tagKey), buf(tag), buf(message))) {
    throw new RevisionReadError("tagMismatch", "authentication tag does not match (file altered, moved or renamed)");
  }
  return gz;
}

/** One earlier epoch of the vault's chain (format.md §15.14): its keys and the sealed set of the record that closed it. */
export interface OlderEpoch {
  epoch: number;
  decrypter: Decrypter;
  tagKey: Uint8Array;
  blobNameKey: CryptoKey;
  /** Vault path → lowercase hex SHA-256 of the exact bytes the change kept. */
  sealed: Map<string, string>;
}

/** `epochs/<e>-<first 16 hex of epochId>.epoch.age`. */
export function epochRecordPath(epoch: number, epochId: Uint8Array): string {
  return `epochs/${epoch}-${hex(epochId).slice(0, 16)}.epoch.age`;
}

/**
 * Opens one epoch record (format.md §15.6): decrypted under its epoch's identity, framed under its `tagKey`, and
 * naming that epoch; returns its parent's key and sealed set (undefined at epoch 1 or without a key).
 */
async function recordParent(bytes: Uint8Array, path: string, epoch: number, keys: EpochKeys, vaultId: string):
  Promise<{ epoch: number; key: Uint8Array; sealed: Map<string, string> } | undefined> {
  if (bytes.length > limits.epochRecordBytes) throw new Error("record too large");
  const d = new Decrypter();
  d.addIdentity(keys.identity);
  const gz = await openFrame(await d.decrypt(bytes), "epochs", path.slice("epochs/".length), keys.tagKey);
  const json: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(await gunzip(gz, limits.epochRecordBytes)));
  if (!isObject(json) || json.vaultId !== vaultId || json.epoch !== epoch || json.epochId !== hex(keys.epochId)) {
    throw new Error("the record names another epoch");
  }
  const parent = json.parent;
  if (!isObject(parent)) return undefined;
  const key = unhex(parent.key, 32);
  if (!key || typeof parent.epoch !== "number" || parent.epoch !== epoch - 1 || !isObject(parent.sealed)) return undefined;
  if (parent.epochId !== hex(epochKeys(key).epochId)) throw new Error("the parent's key is not its epoch's");
  const sealed = new Map<string, string>();
  for (const [p, v] of Object.entries(parent.sealed)) if (typeof v === "string") sealed.set(p, v);
  return { epoch: parent.epoch, key, sealed };
}

/**
 * The earlier epochs of the chain, newest first (format.md §15.14): the current record gives the parent's key and
 * sealed set, then each parent's record the next. Stops at the first record that cannot be read or opened.
 */
async function olderEpochs(manifest: VaultManifest, current: EpochKeys, record: Uint8Array,
  readRecord: (path: string) => Promise<Uint8Array | undefined>): Promise<OlderEpoch[]> {
  const out: OlderEpoch[] = [];
  let bytes: Uint8Array | undefined = record, path = manifest.epochRecord, epoch = manifest.epoch, keys = current;
  while (bytes && epoch > 1 && out.length < 4096) {
    let parent;
    try {
      parent = await recordParent(bytes, path, epoch, keys, manifest.vaultId);
    } catch {
      break;
    }
    if (!parent) break;
    const pk = epochKeys(parent.key);
    const decrypter = new Decrypter();
    decrypter.addIdentity(pk.identity);
    out.push({ epoch: parent.epoch, decrypter, tagKey: pk.tagKey, blobNameKey: await hmacKey(pk.blobNameKey), sealed: parent.sealed });
    epoch = parent.epoch;
    keys = pk;
    path = epochRecordPath(epoch, pk.epochId);
    if (epoch <= 1) break;
    try {
      bytes = await readRecord(path);
    } catch {
      bytes = undefined;
    }
  }
  return out;
}

/** An unlocked vault: the epoch key's derived keys and identity, in memory only. */
export class UnlockedVault {
  /** The earlier epochs of the chain whose keys the records gave, newest first (format.md §15.14). */
  older: OlderEpoch[] = [];

  private constructor(
    readonly manifest: VaultManifest,
    private readonly decrypter: Decrypter,
    private readonly tagKey: Uint8Array,
    private readonly blobNameKey: CryptoKey,
    /** The recipient of the key the user supplied (a device's, or the recovery key's). */
    readonly recipient: string,
    /** Which entry opened the vault. */
    readonly openedWith: ManifestKey["role"],
    /** How vault.json checked (format.md §15.3); reported, the viewer never writes. */
    readonly listStatus: ListStatus,
    /** `K_e` as HKDF input, for the keys derived from it (format.md §10, §12). */
    private readonly derivation: CryptoKey,
  ) {}

  /** The key derived for `info` (HKDF-SHA256 of `K_e`, empty salt, format.md §15.2), as an array of one. */
  async derivedKeys(info: string, algorithm: AesKeyGenParams, usages: KeyUsage[]): Promise<CryptoKey[]> {
    return [await crypto.subtle.deriveKey(
      { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: encoder.encode(info) }, this.derivation, algorithm, false, usages)];
  }

  /**
   * Opens the vault with `identity`: a device key, or the recovery key (also from its passphrase copy). The
   * entry whose key is the identity's recipient has a wrap that opens to `K_e` (format.md §15.3); `listTag` must
   * verify under it, else the vault is refused. `epochRecord` is the file `manifest.epochRecord` names, if it
   * could be read (an absent one is reported in `listStatus`).
   */
  static async unlock(manifest: VaultManifest, identity: string, epochRecord?: Uint8Array,
    readRecord?: (path: string) => Promise<Uint8Array | undefined>): Promise<UnlockedVault> {
    let recipient: string;
    try {
      recipient = await identityToRecipient(identity);
    } catch (e) {
      throw new VaultError("badIdentity", `the key is not a valid age identity: ${String(e)}`);
    }
    const entry = manifest.keys.find((k) => k.key === recipient);
    if (!entry) {
      throw new VaultError("keyNotListed", "none of the vault's keys is this key: this device has not joined the vault");
    }
    const opener = new Decrypter();
    opener.addIdentity(identity);
    let wrapped: Uint8Array;
    try {
      wrapped = await opener.decrypt(armor.decode(entry.wrap));
    } catch (e) {
      throw new VaultError("wrongKey", `this key does not open the vault (${e instanceof Error ? e.message : String(e)})`);
    }
    const wrap = parseEpochWrap(wrapped, manifest.vaultId, manifest.epoch);
    if ("problem" in wrap) throw new VaultError("invalidWrap", `this key's wrap is not one of this vault and epoch (${wrap.problem})`);
    const key = wrap.key;
    const keys = epochKeys(key);
    if (hex(keys.epochId) !== manifest.epochId || !checkListTag(manifest, key)) {
      throw new VaultError("tamperedList", "vault.json does not verify under the vault's epoch key (its key list was changed)");
    }
    const decrypter = new Decrypter();
    decrypter.addIdentity(keys.identity);
    const listStatus = await checkManifest(manifest, key, keys, epochRecord, (d) => decrypter.decrypt(d));
    const vault = new UnlockedVault(manifest, decrypter, keys.tagKey, await hmacKey(keys.blobNameKey), recipient, entry.role,
      listStatus, await hkdfKey(key));
    // Earlier keys only from a vault.json that checks (its record is the one it names, by hash).
    if (epochRecord && manifest.epoch > 1 && listStatus.status === "verified") {
      vault.older = await olderEpochs(manifest, keys, epochRecord, readRecord ?? (() => Promise.resolve(undefined)));
    }
    return vault;
  }

  /**
   * The keyed blob names (format.md §8.1.2) for a content hash (32 raw bytes) under `blobNameKey`: an array of
   * one, the epoch's (older epochs' names are not read).
   */
  async blobNames(sha256: Uint8Array): Promise<string[]> {
    return (await this.blobCandidates(sha256)).map((c) => c.name);
  }

  /**
   * The blob names of a content hash under the current epoch's key, then under each earlier epoch's
   * (format.md §15.14), with the epoch they belong to (undefined: the current one).
   */
  async blobCandidates(sha256: Uint8Array): Promise<{ name: string; older?: OlderEpoch }[]> {
    const message = concat([encoder.encode("sempere/1"), Uint8Array.of(0), encoder.encode("blob"), Uint8Array.of(0), sha256]);
    const name = async (k: CryptoKey) => hex(new Uint8Array(await crypto.subtle.sign("HMAC", k, buf(message))));
    const out: { name: string; older?: OlderEpoch }[] = [{ name: await name(this.blobNameKey) }];
    for (const o of this.older) out.push({ name: await name(o.blobNameKey), older: o });
    return out;
  }

  /** Decrypts an age file as a stream (blobs, format.md §8.1.3): authenticated chunk by chunk. */
  async decryptStream(file: ReadableStream<Uint8Array>): Promise<ReadableStream<Uint8Array>> {
    return this.decrypter.decrypt(file);
  }

  /**
   * Reads one revision file (§4, §5): decrypts, checks magic, version and
   * tag, gunzips, decodes, and checks the content names this note and file.
   */
  async readRevision(noteId: string, filename: string, data: Uint8Array): Promise<Revision> {
    const name = parseRevisionName(filename);
    if (!name || revisionFilename(name) !== filename) throw new RevisionReadError("undecodable", "not a revision file name");
    if (data.length > limits.revisionBytes) throw new RevisionReadError("undecryptable", "file larger than 256 MiB");
    let plain: Uint8Array;
    let tagKey = this.tagKey;
    let older: OlderEpoch | undefined;
    try {
      plain = await this.decrypter.decrypt(data);
    } catch (e) {
      // An earlier epoch's key (format.md §15.14), newest first: at most one decapsulation per epoch.
      let opened: Uint8Array | undefined;
      for (const o of this.older) {
        try {
          opened = await o.decrypter.decrypt(data);
          older = o;
          break;
        } catch {
          continue;
        }
      }
      if (!opened || !older) throw new RevisionReadError("undecryptable", e instanceof Error ? e.message : String(e));
      plain = opened;
      tagKey = older.tagKey;
    }
    const gz = await openFrame(plain, noteId, filename, tagKey);
    if (older && older.sealed.get(`notes/${noteId}/${filename}`) !== hex(sha256(data))) {
      throw new RevisionReadError("setAside", "written under an earlier key after the device change that closed it (set aside)");
    }
    let json: unknown;
    try {
      const text = new TextDecoder("utf-8", { fatal: true }).decode(await gunzip(gz));
      json = JSON.parse(text);
    } catch (e) {
      throw new RevisionReadError("corruptBody", e instanceof Error ? e.message : String(e));
    }
    let rev: Revision;
    try {
      rev = decodeRevision(json);
    } catch (e) {
      // A newer revision that does not decode is newer, not corrupt (§7.2).
      let newer: boolean;
      try {
        newer = isObject(json) && revisionMarkersNewer(json);
      } catch {
        newer = false;
      }
      throw new RevisionReadError(newer ? "newer" : "undecodable",
        (newer ? "written by a newer version: " : "") + (e instanceof Error ? e.message : String(e)));
    }
    if (rev.noteId !== noteId || rev.hlc !== name.hlc || rev.device !== name.device || rev.seq !== name.seq
      || rev.body.type !== name.kind) {
      throw new RevisionReadError("undecodable", `content is ${rev.noteId}/${rev.hlc}-${rev.device}-${rev.seq}.${rev.body.type}`);
    }
    return rev;
  }
}

function hex(b: Uint8Array): string {
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}

/** True for JSON objects; re-exported for the sources. */
export { isObject };
