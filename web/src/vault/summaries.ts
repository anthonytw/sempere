// Published summaries (format.md §12): `sempere-summaries.sealed`, the note
// list a cold reader shows before (or instead of) decrypting every revision.
// A hint: an entry is used only while the note's listing shows exactly its
// revision names, and any problem with the file means only a slower listing.
// AES-256-GCM (WebCrypto) under HKDF(vaultSecret, "sempere/1 published
// summaries key"), the vault id in the associated data.

import { isLowercaseUUID } from "../format/json.ts";
import { parseRFC3339 } from "../format/rfc3339.ts";
import { gunzip } from "./gzip.ts";
import { type NoteSummary } from "./library.ts";
import { isRevisionFile } from "./source.ts";
import { type UnlockedVault } from "./vault.ts";

export const summariesFileName = "sempere-summaries.sealed";
export const summariesFormat = "sempere-summaries/1";
/** format.md §9. */
export const maxSummariesBytes = 64 * 1024 * 1024;
export const maxSummariesJSONBytes = 256 * 1024 * 1024;
export const summariesKeyInfo = "sempere/1 published summaries key";

const magic = [0x53, 0x4d, 0x50, 0x55, 0x01];
const nonceSize = 12, tagSize = 16;
const encoder = new TextEncoder();

/** Why a summaries file was ignored (never shown as a vault error). */
export class SummariesError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SummariesError";
  }
}

/** One note's entry (format.md §12.2). */
export interface SummaryEntry {
  /** Sorted revision file names the summary was made from. */
  revisions: string[];
  title: string;
  tags: string[];
  notebook?: string;
  favorite: boolean;
  deleted: boolean;
  /** Unix ms. */
  created: number;
  modified: number;
  pages: number;
  pageTexts: { number: number; text: string }[];
}

function bytes(b: Uint8Array): Uint8Array<ArrayBuffer> {
  return b as Uint8Array<ArrayBuffer>;
}

export function summariesAAD(vaultId: string): Uint8Array {
  const id = encoder.encode(vaultId.toLowerCase());
  const label = encoder.encode("sempere/1");
  const out = new Uint8Array(magic.length + label.length + 1 + id.length);
  out.set(magic, 0);
  out.set(label, magic.length);
  out.set(id, magic.length + label.length + 1);
  return out;
}

/** The AES-GCM key for raw secret bytes (tests and the format.md vector). */
export async function summariesKeyFromSecret(secret: Uint8Array): Promise<CryptoKey> {
  const k = await crypto.subtle.importKey("raw", bytes(secret), "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: encoder.encode(summariesKeyInfo) },
    k, { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]);
}

/** Seals a plaintext (tests; the viewer never writes). */
export async function sealSummaries(plain: Uint8Array, key: CryptoKey, vaultId: string, nonce?: Uint8Array): Promise<Uint8Array> {
  const n = nonce ?? crypto.getRandomValues(new Uint8Array(nonceSize));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: bytes(n), additionalData: bytes(summariesAAD(vaultId)) },
    key, bytes(plain)));
  const out = new Uint8Array(magic.length + n.length + ct.length);
  out.set(magic, 0);
  out.set(n, magic.length);
  out.set(ct, magic.length + n.length);
  return out;
}

/** The plaintext under the first key that authenticates it. */
export async function openSummaries(file: Uint8Array, keys: CryptoKey[], vaultId: string): Promise<Uint8Array> {
  if (file.length > maxSummariesBytes) throw new SummariesError(`larger than ${maxSummariesBytes} bytes`);
  if (file.length < magic.length + nonceSize + tagSize || !magic.every((b, i) => file[i] === b)) {
    throw new SummariesError("not a published summaries file");
  }
  const iv = file.subarray(magic.length, magic.length + nonceSize);
  const body = file.subarray(magic.length + nonceSize);
  for (const key of keys) {
    try {
      return new Uint8Array(await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: bytes(iv), additionalData: bytes(summariesAAD(vaultId)) }, key, bytes(body)));
    } catch {
      // try the next key
    }
  }
  throw new SummariesError("does not authenticate (another vault, another secret, or altered)");
}

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function stringArray(v: unknown): string[] | undefined {
  return Array.isArray(v) && v.every((x) => typeof x === "string") ? v : undefined;
}

/** One entry, or undefined when any field is malformed (format.md §12.3). */
export function decodeEntry(v: unknown): SummaryEntry | undefined {
  if (!isObj(v)) return undefined;
  const revisions = stringArray(v.revisions);
  const tags = stringArray(v.tags);
  const { title, notebook, favorite, deleted, pages } = v;
  if (!revisions || revisions.length === 0 || !tags || typeof title !== "string") return undefined;
  for (let i = 0; i < revisions.length; i++) {
    const r = revisions[i] ?? "";
    if (!isRevisionFile(r) || (i > 0 && !((revisions[i - 1] ?? "") < r))) return undefined;
  }
  if (notebook != null && typeof notebook !== "string") return undefined;   // null reads as absent
  if (typeof favorite !== "boolean" || typeof deleted !== "boolean") return undefined;
  if (typeof pages !== "number" || !Number.isSafeInteger(pages) || pages < 0) return undefined;
  const created = typeof v.created === "string" ? parseRFC3339(v.created) : undefined;
  const modified = typeof v.modified === "string" ? parseRFC3339(v.modified) : undefined;
  if (created === undefined || modified === undefined || !Array.isArray(v.pageTexts)) return undefined;
  const pageTexts: { number: number; text: string }[] = [];
  let last = 0;
  for (const p of v.pageTexts) {
    if (!isObj(p) || typeof p.page !== "number" || !Number.isSafeInteger(p.page) || typeof p.text !== "string") return undefined;
    if (p.page <= last || p.page > pages) return undefined;
    last = p.page;
    pageTexts.push({ number: p.page, text: p.text });
  }
  const e: SummaryEntry = { revisions, title, tags, favorite, deleted, created, modified, pages, pageTexts };
  if (typeof notebook === "string") e.notebook = notebook;
  return e;
}

/** The valid entries of a JSON content; throws `SummariesError` for another format or vault. */
export function decodeSummaries(json: unknown, vaultId: string): Map<string, SummaryEntry> {
  if (!isObj(json)) throw new SummariesError("not a summaries document");
  if (json.format !== summariesFormat) throw new SummariesError("unknown format");
  if (json.vaultId !== vaultId.toLowerCase()) throw new SummariesError("summaries of another vault");
  if (!isObj(json.notes)) throw new SummariesError("no notes");
  const out = new Map<string, SummaryEntry>();
  for (const [id, v] of Object.entries(json.notes)) {
    if (!isLowercaseUUID(id)) continue;
    const e = decodeEntry(v);
    if (e) out.set(id, e);
  }
  return out;
}

/** Opens, gunzips and decodes a sealed file with the vault's keys. */
export async function readSummaries(file: Uint8Array, vault: UnlockedVault): Promise<Map<string, SummaryEntry>> {
  const vaultId = vault.manifest.vaultId;
  const keys = await vault.derivedKeys(summariesKeyInfo, { name: "AES-GCM", length: 256 }, ["decrypt"]);
  const plain = await openSummaries(file, keys, vaultId);
  let json: unknown;
  try {
    json = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(await gunzip(plain, maxSummariesJSONBytes)));
  } catch (e) {
    throw new SummariesError(`unreadable content: ${e instanceof Error ? e.message : String(e)}`);
  }
  return decodeSummaries(json, vaultId);
}

/** True when the entry was made from exactly `files` (sorted revision names). */
export function entryMatches(e: SummaryEntry, files: string[]): boolean {
  return e.revisions.length === files.length && e.revisions.every((r, i) => r === files[i]);
}

/** The list row for an entry (same fields `summarize` computes from the revisions). */
export function entrySummary(id: string, e: SummaryEntry): NoteSummary {
  const s: NoteSummary = {
    id, title: e.title, tags: e.tags, favorite: e.favorite, deleted: e.deleted, created: e.created,
    modified: e.modified, pageCount: e.pages, pageTexts: e.pageTexts, failures: 0, hasAttachments: false, newer: false,
  };
  if (e.notebook !== undefined) s.notebook = e.notebook;
  return s;
}
