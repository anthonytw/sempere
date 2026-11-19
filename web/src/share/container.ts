// The payload of a share file (`sempere-share/1`, docs/web-viewer.md "Share files"): the bytes inside the age
// file. `"SHRE" ‖ 0x01 ‖ u32 gzipLength ‖ gzip(JSON) ‖ { u32 nameLength ‖ name ‖ u64 length ‖ bytes } *`, all
// integers big-endian. The JSON is `{ format, shareId, generator, note }` where `note` is a note state as
// `sempere export --format json` writes it (src/format/model.ts `decodeState`), flattened by the sender
// (no history, ids or clocks). Each blob's name is the SHA-256 of its content in lowercase hex, which is how an
// item's `{ sha256, size, type }` reference finds it. Everything here is untrusted: a hostile sender made it.

import { sha256 } from "@noble/hashes/sha2.js";
import { gunzip } from "../vault/gzip.ts";

export const payloadFormat = "sempere-share/1";
const magic = [0x53, 0x48, 0x52, 0x45];
const version = 1;

/** Largest JSON document accepted after gunzip. */
export const maxJSONBytes = 64 * 1024 * 1024;
/** Largest payload accepted (the sender's own limit is 200 MiB for the file; the payload is smaller). */
export const maxPayloadBytes = 256 * 1024 * 1024;
/** Most blobs in one payload (a note holds at most 200 pages; each has few images). */
export const maxBlobs = 4096;

export class ShareFormatError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ShareFormatError";
  }
}

export interface SharePayload {
  shareId: string;
  /** The note's state as JSON, to be validated by `decodeState`. */
  note: unknown;
  /** Attachment contents by lowercase hex SHA-256. */
  blobs: Map<string, Uint8Array>;
}

function hex(b: Uint8Array): string {
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}

/** Parses and checks a payload. Throws `ShareFormatError` for anything that is not one. */
export async function parsePayload(bytes: Uint8Array): Promise<SharePayload> {
  if (bytes.length > maxPayloadBytes) throw new ShareFormatError("the shared note is too large");
  if (bytes.length < 9 || magic.some((m, i) => bytes[i] !== m)) throw new ShareFormatError("not a Sempere share");
  if (bytes[4] !== version) throw new ShareFormatError("this share was made by a newer version of Sempere");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const gzipLength = view.getUint32(5);
  let at = 9;
  if (gzipLength > bytes.length - at) throw new ShareFormatError("the shared note is cut short");
  const jsonBytes = await gunzip(bytes.subarray(at, at + gzipLength), maxJSONBytes).catch(() => {
    throw new ShareFormatError("the shared note's text is damaged");
  });
  at += gzipLength;
  let doc: unknown;
  try {
    doc = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(jsonBytes));
  } catch {
    throw new ShareFormatError("the shared note's text is damaged");
  }
  if (typeof doc !== "object" || doc === null || Array.isArray(doc)) throw new ShareFormatError("the shared note's text is damaged");
  const o = doc as Record<string, unknown>;
  if (o.format !== payloadFormat) throw new ShareFormatError("this share was made by a newer version of Sempere");
  if (typeof o.shareId !== "string" || o.note === undefined) throw new ShareFormatError("the shared note's text is damaged");
  const blobs = new Map<string, Uint8Array>();
  while (at < bytes.length) {
    if (blobs.size >= maxBlobs) throw new ShareFormatError("the shared note has too many attachments");
    if (bytes.length - at < 4) throw new ShareFormatError("the shared note is cut short");
    const nameLength = view.getUint32(at);
    at += 4;
    if (nameLength !== 64 || bytes.length - at < nameLength + 8) throw new ShareFormatError("the shared note is cut short");
    const name = new TextDecoder("ascii").decode(bytes.subarray(at, at + nameLength));
    at += nameLength;
    if (!/^[0-9a-f]{64}$/.test(name) || blobs.has(name)) throw new ShareFormatError("the shared note's attachments are damaged");
    const length = view.getBigUint64(at);
    at += 8;
    if (length > BigInt(bytes.length - at)) throw new ShareFormatError("the shared note is cut short");
    const n = Number(length);
    const content = bytes.subarray(at, at + n);
    at += n;
    // Hashed once, here: an item then cannot name content that is not its own.
    if (hex(sha256(content)) !== name) throw new ShareFormatError("the shared note's attachments are damaged");
    blobs.set(name, content);
  }
  return { shareId: o.shareId, note: o.note, blobs };
}
