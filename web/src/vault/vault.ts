// Opening a vault (format.md §2, §3.1) and reading one revision file (§4, §5):
// age decryption with typage, the `SMPR` framing, the HMAC tag under the
// vault secret, gunzip and JSON. Nothing here touches the network or the DOM.

import { t } from "../i18n/index.ts";
import { Decrypter, armor, identityToRecipient } from "age-encryption";
import { DecodeError, arr, arrayOf, isObject, obj, opt, optWith, reqWith, str, uuid } from "../format/json.ts";
import { cmpUTF8, parseRevisionName, revisionFilename } from "../format/ids.ts";
import { type Revision, decodeRevision } from "../format/model.ts";
import { formatMajor, majorOf, manifestReadOnlyReasons, revisionMarkersNewer } from "../format/newer.ts";
import { parseRFC3339 } from "../format/rfc3339.ts";
import { concat } from "./bytes.ts";
import { gunzip } from "./gzip.ts";
import { type SecretLink, linkConnects, parseSecretLink } from "./link.ts";

/** format.md §9 limits. */
export const limits = {
  revisionBytes: 256 * 1024 * 1024,
  manifestBytes: 16 * 1024 * 1024,
};

export type VaultErrorCode =
  | "manifestCorrupt" | "unsupportedFormat" | "legacyVault" | "badIdentity" | "classicIdentity" | "wrongKey"
  | "invalidVaultSecret";

/** Why a vault cannot be opened or unlocked. */
export class VaultError extends Error {
  constructor(public readonly code: VaultErrorCode, message: string) {
    super(message);
    this.name = "VaultError";
  }
}

/** `newer`: written by a newer version and not readable by this one (format.md §7.2, §7.4). */
export type RevisionErrorCode = "undecryptable" | "tagMismatch" | "corruptBody" | "undecodable" | "newer";

/** Why one revision file could not be read; reported, never silently dropped (§4). */
export class RevisionReadError extends Error {
  constructor(public readonly code: RevisionErrorCode, message: string) {
    super(message);
    this.name = "RevisionReadError";
  }
}

export interface ManifestRecipient {
  key: string;
  label: string;
}

export interface VaultManifest {
  format: string;
  vaultId: string;
  recipients: ManifestRecipient[];
  vaultSecret: string;
  features: string[];
  /**
   * `recipientsTag` (format.md §2.1): undefined when absent or null; a value
   * that is not a string reads as "" (a tag that never verifies).
   */
  recipientsTag?: string;
  /** `secretLink` (format.md §2.1): undefined when absent or null. */
  secretLink?: SecretLink;
  /** `markersTag` (format.md §2.1 "Version markers"): read like `recipientsTag`. */
  markersTag?: string;
}

const bech32 = /^[02-9ac-hj-np-z]+$/;

/** An age recipient's type by its Bech32 prefix, or undefined if malformed. */
export function recipientType(key: string): "mlkem768x25519" | "x25519" | undefined {
  const k = key.toLowerCase();
  if (key !== k && key !== key.toUpperCase()) return undefined;
  if (k.startsWith("age1pq1") && bech32.test(k.slice(7)) && k.length > 20) return "mlkem768x25519";
  if (k.startsWith("age1") && bech32.test(k.slice(4)) && k.length === 62) return "x25519";
  return undefined;
}

/** Parses and validates `vault.json` (format.md §2). */
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
    const recipients = reqWith(o, "recipients", "$", (v, p) => arr(v, p).map((r, i) => {
      const ro = obj(r, `${p}[${i}]`);
      const added = reqWith(ro, "added", `${p}[${i}]`, str);
      if (parseRFC3339(added) === undefined) throw new DecodeError(`${p}[${i}].added: bad date`);
      return { key: reqWith(ro, "key", `${p}[${i}]`, str), label: reqWith(ro, "label", `${p}[${i}]`, str) };
    }));
    const created = reqWith(o, "created", "$", str);
    if (parseRFC3339(created) === undefined) throw new DecodeError("$.created: bad date");
    const tag = opt(o, "recipientsTag");
    const markersTag = opt(o, "markersTag");
    m = {
      format: reqWith(o, "format", "$", str),
      vaultId: reqWith(o, "vaultId", "$", uuid),
      recipients,
      vaultSecret: reqWith(o, "vaultSecret", "$", str),
      // An array of strings (§2) or absent, as Swift's decodeIfPresent([String]).
      features: optWith(o, "features", "$", (v, p) => arrayOf(v, p, str)) ?? [],
    };
    if (tag !== undefined && tag !== null) m.recipientsTag = typeof tag === "string" ? tag : "";
    if (markersTag !== undefined && markersTag !== null) m.markersTag = typeof markersTag === "string" ? markersTag : "";
    const link = parseSecretLink(opt(o, "secretLink"));
    if (link) m.secretLink = link;
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
  if (m.recipients.length === 0) throw new VaultError("manifestCorrupt", "no recipients");
  // A later major may list recipient types this viewer does not know.
  for (const r of major <= formatMajor ? m.recipients : []) {
    if (!recipientType(r.key)) throw new VaultError("manifestCorrupt", `invalid recipient ${r.key.slice(0, 24)}…`);
  }
  if (new Set(m.recipients.map((r) => r.key)).size !== m.recipients.length) {
    throw new VaultError("manifestCorrupt", "duplicate recipient");
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

/** True when the vault lists an X25519 recipient: migrate-only (format.md §3.3.2). */
export function isLegacy(m: VaultManifest): boolean {
  return m.recipients.some((r) => recipientType(r.key) === "x25519");
}

/**
 * The identity in pasted text: an `age-keygen -pq` file or the bare
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

/**
 * How `vault.json`'s recipients list checked (format.md §2.1). The viewer
 * writes nothing and keeps no trust record, so it reports only what the tag
 * says: `verified` (the tag verifies under the vault secret), `untagged` (an
 * older vault), or `tampered` (`tagMismatch`: the tag does not verify;
 * `tagRemoved`: the `recipients-tag` feature is listed but the tag is gone;
 * `markersMismatch` / `markersRemoved`: the same for `format` and `features`,
 * "Version markers"). Without a trust record it cannot see a rolled-back
 * `vault.json`.
 */
export type RecipientsStatus =
  | { status: "verified" }
  | { status: "untagged" }
  | { status: "tampered"; reason: "tagMismatch" | "tagRemoved" | "markersMismatch" | "markersRemoved" };

export const recipientsTagFeature = "recipients-tag";
export const markersTagFeature = "markers-tag";

async function hkdf(secret: Uint8Array, info: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", buf(secret), "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: encoder.encode(info) },
    key, 256);
  return new Uint8Array(bits);
}

/** `recipientsTag` (lowercase hex) of `keys`, in order, under the vault secret (format.md §2.1). */
export async function recipientsTag(vaultId: string, keys: string[], secret: Uint8Array): Promise<string> {
  const parts: Uint8Array[] = [encoder.encode("sempere/1"), Uint8Array.of(0), encoder.encode("recipients"), Uint8Array.of(0),
    encoder.encode(vaultId.toLowerCase())];
  for (const k of keys) parts.push(Uint8Array.of(0), encoder.encode(k));
  const key = await hmacKey(await hkdf(secret, "sempere/1 recipients key"));
  return hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, buf(concat(parts)))));
}

function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  let diff = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

/**
 * True when `link` (a `secretLink`, format.md §2.1) links the secret `previous`
 * to `current`: the rotation from `previous` was made by a holder of it.
 */
export async function verifySecretLink(link: SecretLink | undefined, previous: Uint8Array, current: Uint8Array,
  vaultId: string): Promise<boolean> {
  return linkConnects(link, previous, current, vaultId);
}

function equalStrings(given: string, expected: string): boolean {
  let diff = given.length ^ expected.length;
  for (let i = 0; i < expected.length; i++) diff |= (given.charCodeAt(i) || 0) ^ expected.charCodeAt(i);
  return diff === 0;
}

/**
 * `markersTag` (lowercase hex) of `format` and `features` (format.md §2.1
 * "Version markers": the distinct features sorted by UTF-8 bytes); undefined
 * when a marker holds a NUL (never tagged).
 */
export async function markersTag(vaultId: string, format: string, features: string[], secret: Uint8Array): Promise<string | undefined> {
  if (format.includes("\0") || features.some((f) => f.includes("\0"))) return undefined;
  // Code point order is UTF-8 byte order (as Swift sorts them).
  const sorted = [...new Set(features)].sort(cmpUTF8).map((f) => encoder.encode(f));
  const parts: Uint8Array[] = [encoder.encode("sempere/1"), Uint8Array.of(0), encoder.encode("markers"), Uint8Array.of(0),
    encoder.encode(vaultId.toLowerCase()), Uint8Array.of(0), encoder.encode(format)];
  for (const f of sorted) parts.push(Uint8Array.of(0), f);
  const key = await hmacKey(await hkdf(secret, "sempere/1 markers key"));
  return hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, buf(concat(parts)))));
}

/** Classifies the manifest's recipients and version markers under the vault secret (format.md §2.1, without a trust record). */
export async function checkRecipients(m: VaultManifest, secret: Uint8Array): Promise<RecipientsStatus> {
  let status: RecipientsStatus;
  if (m.recipientsTag === undefined) {
    status = m.features.includes(recipientsTagFeature) ? { status: "tampered", reason: "tagRemoved" } : { status: "untagged" };
  } else {
    const expected = await recipientsTag(m.vaultId, m.recipients.map((r) => r.key), secret);
    status = equalStrings(m.recipientsTag, expected) ? { status: "verified" } : { status: "tampered", reason: "tagMismatch" };
  }
  if (status.status === "tampered") return status;
  if (m.markersTag === undefined) {
    return m.features.includes(markersTagFeature) ? { status: "tampered", reason: "markersRemoved" } : status;
  }
  const expected = await markersTag(m.vaultId, m.format, m.features, secret);
  return expected !== undefined && equalStrings(m.markersTag, expected) ? status : { status: "tampered", reason: "markersMismatch" };
}

/**
 * What the viewer says about a list that does not check (format.md §2.1),
 * or undefined. The viewer only reads, so it reports; the app or
 * `sempere vault recipients repair` fixes it.
 */
export function recipientsWarningText(status: RecipientsStatus | undefined): string | undefined {
  if (status?.status !== "tampered") return undefined;
  if (status.reason === "markersMismatch" || status.reason === "markersRemoved") {
    return status.reason === "markersRemoved"
      ? t("This vault's format and features lost their authentication tag. Notes still read correctly here, but the Sempere app and CLI will not write to it until they are repaired (sempere vault markers repair).")
      : t("This vault's format and features were changed without the vault's key. Notes still read correctly here, but the Sempere app and CLI will not write to it until they are repaired (sempere vault markers repair).");
  }
  const reason = status.reason === "tagRemoved" ? "tagRemoved" : "changed";
  return reason === "tagRemoved"
    ? t("This vault's device list lost its authentication tag. Notes still read correctly here, but the Sempere app and CLI will not write to it until it is repaired (sempere vault recipients repair).")
    : t("This vault's device list was changed without the vault's key. Notes still read correctly here, but the Sempere app and CLI will not write to it until it is repaired (sempere vault recipients repair).");
}

/** An unlocked vault: the identity and the vault secret, in memory only. */
export class UnlockedVault {
  private constructor(
    readonly manifest: VaultManifest,
    private readonly decrypter: Decrypter,
    private readonly secret: CryptoKey,
    private readonly previous: CryptoKey | undefined,
    /** The recipient of the pasted identity. */
    readonly recipient: string,
    /** How the recipients list checked (format.md §2.1); reported, the viewer never writes. */
    readonly recipientsStatus: RecipientsStatus = { status: "untagged" },
    /** The vault secret (then the previous one) as HKDF input, for derived keys (format.md §12). */
    private readonly derivation: CryptoKey[] = [],
  ) {}

  /**
   * The keys derived for `info` (HKDF-SHA256, empty salt, format.md §10, §12)
   * under the current secret and, during an unfinished rewrap, the previous one.
   */
  async derivedKeys(info: string, algorithm: AesKeyGenParams, usages: KeyUsage[]): Promise<CryptoKey[]> {
    return Promise.all(this.derivation.map((k) => crypto.subtle.deriveKey(
      { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: encoder.encode(info) }, k, algorithm, false, usages)));
  }

  /**
   * Decrypts `vault.json`'s secret with `identity` (and, while a rewrap is
   * unfinished, the journal's previous secret, §3.3.1).
   */
  static async unlock(manifest: VaultManifest, identity: string, journal?: Uint8Array): Promise<UnlockedVault> {
    if (isLegacy(manifest)) {
      throw new VaultError("legacyVault",
        "this vault still lists a classic X25519 key; migrate it with the app or `sempere vault` first (format.md §3.3.2)");
    }
    let recipient: string;
    const decrypter = new Decrypter();
    try {
      recipient = await identityToRecipient(identity);
      decrypter.addIdentity(identity);
    } catch (e) {
      throw new VaultError("badIdentity", `the key is not a valid age identity: ${String(e)}`);
    }
    const secretBytes = await decryptSecret(decrypter, manifest.vaultSecret);
    const secret = await hmacKey(secretBytes);
    const derivation = [await hkdfKey(secretBytes)];
    const recipientsStatus = await checkRecipients(manifest, secretBytes);
    let previous: CryptoKey | undefined;
    if (journal) {
      try {
        const o = obj(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(journal)), "$");
        const p = opt(o, "previousVaultSecret");
        if (typeof p === "string") {
          // Plaintext anyone who can write the folder can plant, with a secret
          // anyone can encrypt to the public keys: it counts only when
          // `secretLink` links it to the current secret, or it is the current
          // one (security review 2026-10, R4; Vault.readJournal in Swift).
          const bytes = await decryptSecret(decrypter, p);
          if (equalBytes(bytes, secretBytes)
            || await verifySecretLink(manifest.secretLink, bytes, secretBytes, manifest.vaultId)) {
            previous = await hmacKey(bytes);
            derivation.push(await hkdfKey(bytes));
          }
        }
      } catch {
        // An unreadable journal only matters for files not yet re-tagged; they
        // then fail their tag check and are reported.
      }
    }
    return new UnlockedVault(manifest, decrypter, secret, previous, recipient, recipientsStatus, derivation);
  }

  /**
   * The keyed blob names (format.md §8.1.2) for a content hash (32 raw
   * bytes): under the current vault secret, then, while a rewrap is
   * unfinished, under the previous one (§8.1.5).
   */
  async blobNames(sha256: Uint8Array): Promise<string[]> {
    const message = concat([encoder.encode("sempere/1"), Uint8Array.of(0), encoder.encode("blob"), Uint8Array.of(0), sha256]);
    const keys = this.previous ? [this.secret, this.previous] : [this.secret];
    const out: string[] = [];
    for (const k of keys) out.push(hex(new Uint8Array(await crypto.subtle.sign("HMAC", k, buf(message)))));
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
    try {
      plain = await this.decrypter.decrypt(data);
    } catch (e) {
      throw new RevisionReadError("undecryptable", e instanceof Error ? e.message : String(e));
    }
    if (plain.length < headerSize) throw new RevisionReadError("corruptBody", "body shorter than its header");
    if (!magic.every((b, i) => plain[i] === b)) throw new RevisionReadError("corruptBody", "body does not start with SMPR");
    if ((plain[4] ?? 0) > 1) throw new RevisionReadError("newer", `written by a newer version (body version ${plain[4]})`);
    if (plain[4] !== 1) throw new RevisionReadError("corruptBody", `unsupported body version ${plain[4]}`);
    const tag = plain.subarray(5, headerSize);
    const gz = plain.subarray(headerSize);
    const message = concat([encoder.encode("sempere/1"), Uint8Array.of(0), encoder.encode(noteId), Uint8Array.of(0),
      encoder.encode(filename), Uint8Array.of(0), gz]);
    let ok = await crypto.subtle.verify("HMAC", this.secret, buf(tag), buf(message));
    if (!ok && this.previous) ok = await crypto.subtle.verify("HMAC", this.previous, buf(tag), buf(message));
    if (!ok) throw new RevisionReadError("tagMismatch", "authentication tag does not match (file altered, moved or renamed)");
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

async function decryptSecret(decrypter: Decrypter, armored: string): Promise<Uint8Array> {
  let bytes: Uint8Array;
  try {
    bytes = await decrypter.decrypt(armor.decode(armored));
  } catch (e) {
    throw new VaultError("wrongKey", `this key does not open the vault (${e instanceof Error ? e.message : String(e)})`);
  }
  if (bytes.length !== 32) throw new VaultError("invalidVaultSecret", "the vault secret is not 32 bytes");
  return bytes;
}

/** True for JSON objects; re-exported for the sources. */
export { isObject };
