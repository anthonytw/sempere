// The attachments of a shared note: verified once when the payload was parsed (the name is the content's
// SHA-256), so a reference only has to match name, size and a size limit.

import { type BlobReader, type BlobRef, BlobError } from "../vault/blobs.ts";

export class ShareBlobs implements BlobReader {
  constructor(private readonly blobs: ReadonlyMap<string, Uint8Array>) {}

  get(ref: BlobRef, maxBytes?: number): Promise<Blob> {
    const content = this.blobs.get(ref.sha256);
    if (!content) return Promise.reject(new BlobError("missing", "attachment file is missing"));
    if (content.length !== ref.size) return Promise.reject(new BlobError("corrupt", "the attachment's size does not match its reference"));
    if (maxBytes !== undefined && content.length > maxBytes) return Promise.reject(new BlobError("tooLarge", "attachment is too large"));
    return Promise.resolve(new Blob([content as Uint8Array<ArrayBuffer>], { type: ref.type }));
  }
}
