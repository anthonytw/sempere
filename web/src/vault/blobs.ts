// Attachment blobs (format.md §8.1): the path a reference resolves to, and
// reading one through a reference with every check of §8.1.4. The file is
// decrypted as a stream (age authenticates each 64 KiB chunk), the content
// hashed as it passes, and nothing is handed out before the whole blob has
// been checked: framing, length, zero padding, content hash, and the keyed
// name binding to the vault secret.

import { sha256 } from "@noble/hashes/sha2.js";
import { maxBlobSize } from "../format/attachments.ts";
import { isObject } from "../format/json.ts";
import { type UnlockedVault } from "./vault.ts";
import { SourceError, type VaultSource, openStream } from "./source.ts";

/** A blob reference (§8.1.1), from a validated item or recording. */
export interface BlobRef {
  sha256: string;
  size: number;
  type: string;
}

/** The reference in `v` (a validated JSON object), or undefined. */
export function asBlobRef(v: unknown): BlobRef | undefined {
  if (!isObject(v)) return undefined;
  const { sha256: sha, size, type } = v;
  if (typeof sha !== "string" || !/^[0-9a-f]{64}$/.test(sha) || typeof size !== "number" || typeof type !== "string") {
    return undefined;
  }
  return { sha256: sha, size, type };
}

/** The media type's type and subtype, lowercased, parameters dropped (§8.1.2). */
export function essence(type: string): string {
  return (type.split(";")[0] ?? "").trim().toLowerCase();
}

/** The `kind` of a blob file name for a reference's `type` (§8.1.2 table). */
export function blobKind(type: string): string {
  const t = essence(type);
  if (t.startsWith("image/")) return "image";
  if (t === "application/pdf") return "pdf";
  if (t.startsWith("audio/")) return "audio";
  if (t.startsWith("video/")) return "video";
  if (t === "application/vnd.sempere.transcript+json") return "transcript";
  return "bin";
}

/** Padmé padding (§8.1.3): the padded plaintext length for `n` bytes. */
export function padme(n: number): number {
  if (n < 2) return n;
  const e = Math.floor(Math.log2(n));
  const s = Math.floor(Math.log2(e)) + 1;
  const z = e - s;
  const step = 2 ** z;
  return Math.ceil(n / step) * step;
}

export function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(2 * i, 2 * i + 2), 16);
  return out;
}

function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return d === 0;
}

export type BlobErrorCode = "missing" | "tooLarge" | "undecryptable" | "corrupt" | "hashMismatch" | "unreadable";

/** Why a blob cannot be used; the item is then drawn as a placeholder (§8.5.2). */
export class BlobError extends Error {
  constructor(public readonly code: BlobErrorCode, message: string) {
    super(message);
    this.name = "BlobError";
  }
}

/** Plaintext header: `INKB`, version 1, SHA-256, length (§8.1.3). */
export const blobHeaderSize = 45;
const magic = [0x49, 0x4e, 0x4b, 0x42];

/**
 * Largest plaintext accepted for content of `size` bytes: the Padmé length
 * writers use plus 1 MiB of further padding (readers accept any padding;
 * this bounds the work a hostile file can cause).
 */
export function maxPlaintext(size: number): number {
  return Math.max(padme(blobHeaderSize + size), blobHeaderSize + size) + (1 << 20);
}

/** Largest blob file for `size` bytes of content: age header, chunk tags, plaintext. */
export function maxFileBytes(size: number): number {
  const plain = maxPlaintext(size);
  return (4 << 20) + plain + Math.ceil(plain / 65536 + 1) * 16;
}

/**
 * Checks a decrypted blob plaintext stream against `ref` and collects its
 * content. Throws `BlobError` on any violation of §8.1.3–§8.1.4.
 */
export async function verifyPlaintext(plain: ReadableStream<Uint8Array>, ref: BlobRef): Promise<Blob> {
  const want = hexToBytes(ref.sha256);
  const header = new Uint8Array(blobHeaderSize);
  let headerFill = 0;
  let content = 0;
  let total = 0;
  const limit = maxPlaintext(ref.size);
  const hash = sha256.create();
  const parts: Uint8Array[] = [];
  const reader = plain.getReader();
  let complete = false;
  try {
    for (;;) {
      let r: ReadableStreamReadResult<Uint8Array>;
      try {
        r = await reader.read();
      } catch (e) {
        if (e instanceof SourceError) throw new BlobError("tooLarge", e.message);
        throw new BlobError("undecryptable", e instanceof Error ? e.message : String(e));
      }
      if (r.done) break;
      let chunk = r.value;
      total += chunk.length;
      if (total > limit) throw new BlobError("tooLarge", "blob padding is larger than this viewer accepts");
      if (headerFill < blobHeaderSize) {
        const n = Math.min(blobHeaderSize - headerFill, chunk.length);
        header.set(chunk.subarray(0, n), headerFill);
        headerFill += n;
        chunk = chunk.subarray(n);
        if (headerFill === blobHeaderSize) {
          if (!magic.every((b, i) => header[i] === b)) throw new BlobError("corrupt", "blob does not start with INKB");
          if (header[4] !== 1) throw new BlobError("corrupt", `unsupported blob version ${header[4]}`);
          if (!equalBytes(header.subarray(5, 37), want)) {
            throw new BlobError("hashMismatch", "blob header names other content than the reference");
          }
          const view = new DataView(header.buffer, 37, 8);
          const length = view.getUint32(0) * 2 ** 32 + view.getUint32(4);
          if (length !== ref.size) throw new BlobError("corrupt", `blob holds ${length} bytes, the reference says ${ref.size}`);
        }
      }
      if (chunk.length === 0) continue;
      const take = Math.min(ref.size - content, chunk.length);
      if (take > 0) {
        const piece = chunk.slice(0, take);
        hash.update(piece);
        parts.push(piece);
        content += take;
      }
      for (let i = take; i < chunk.length; i++) {
        if (chunk[i] !== 0) throw new BlobError("corrupt", "blob padding is not zero");
      }
    }
    complete = true;
  } finally {
    // Stop reading (and close the HTTP body) as soon as the blob fails.
    if (!complete) await reader.cancel().catch(() => undefined);
    reader.releaseLock();
  }
  if (headerFill < blobHeaderSize || content < ref.size) throw new BlobError("corrupt", "blob is truncated");
  if (!equalBytes(hash.digest(), want)) throw new BlobError("hashMismatch", "blob content does not match its hash");
  return new Blob(parts as Uint8Array<ArrayBuffer>[]);
}

/**
 * Reads the blob `ref` of note `noteId` (§8.1.4). The file is looked up by
 * the name keyed from the reference's hash under the vault secret (then the
 * previous secret during a rewrap, §8.1.5); since the header's hash must
 * equal the reference's, a file that verifies is bound to its name. Content
 * over `maxBytes` is refused before anything is read.
 */
export async function readBlob(source: VaultSource, vault: UnlockedVault, noteId: string, ref: BlobRef,
  maxBytes: number = maxBlobSize): Promise<Blob> {
  if (ref.size > Math.min(maxBytes, maxBlobSize)) {
    throw new BlobError("tooLarge", `attachment of ${ref.size} bytes is over this viewer's ${Math.floor(maxBytes / 2 ** 20)} MiB limit`);
  }
  const names = await vault.blobNames(hexToBytes(ref.sha256));
  const kind = blobKind(ref.type);
  for (const name of names) {
    const path = `notes/${noteId}/att/${name}.${kind}.age`;
    try {
      return await readBlobFile(source, vault, path, ref);
    } catch (e) {
      if (e instanceof BlobError && e.code === "missing") continue;
      // A cached copy that fails is dropped and downloaded once more.
      if (!(e instanceof BlobError) || e.code === "tooLarge" || !source.evict || !(await source.evict(path))) throw e;
      try {
        return await readBlobFile(source, vault, path, ref);
      } catch (again) {
        if (again instanceof BlobError && again.code === "missing") continue;
        throw again;
      }
    }
  }
  throw new BlobError("missing", "attachment file is missing");
}

async function readBlobFile(source: VaultSource, vault: UnlockedVault, path: string, ref: BlobRef): Promise<Blob> {
  let file: ReadableStream<Uint8Array>;
  try {
    file = await openStream(source, path, maxFileBytes(ref.size));
  } catch (e) {
    if (e instanceof SourceError && e.notFound) throw new BlobError("missing", "attachment file is missing");
    if (e instanceof SourceError) throw new BlobError("unreadable", e.message);
    throw e;
  }
  let plain: ReadableStream<Uint8Array>;
  try {
    plain = await vault.decryptStream(file);
  } catch (e) {
    throw new BlobError("undecryptable", e instanceof Error ? e.message : String(e));
  }
  return await verifyPlaintext(plain, ref);
}

/**
 * The blobs of one open note, each read once however many items use it,
 * and kept until the note is closed. A failure is not kept, so a later
 * request (another Play) tries again.
 */
export class NoteBlobs {
  private readonly cache = new Map<string, Promise<Blob>>();

  constructor(private readonly source: VaultSource, private readonly vault: UnlockedVault, readonly noteId: string) {}

  get(ref: BlobRef, maxBytes?: number): Promise<Blob> {
    const key = `${ref.sha256}/${ref.size}/${blobKind(ref.type)}/${maxBytes ?? maxBlobSize}`;
    let p = this.cache.get(key);
    if (!p) {
      const read = readBlob(this.source, this.vault, this.noteId, ref, maxBytes);
      p = read;
      this.cache.set(key, read);
      read.catch(() => {
        if (this.cache.get(key) === read) this.cache.delete(key);
      });
    }
    return p;
  }
}
