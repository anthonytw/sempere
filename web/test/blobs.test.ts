// Blobs (format.md §8.1): names, kinds, Padmé, framing checks, and reading
// through a reference from the fixture vault (missing, forged, a name under
// another key, size limits).

import { cpSync, mkdtempSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash, createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  BlobError, NoteBlobs, asBlobRef, blobKind, hexToBytes, maxFileBytes, padme, readBlob, verifyPlaintext,
} from "../src/vault/blobs.ts";
import { deriveEpoch, epochInfo } from "../src/vault/epoch.ts";
import { UnlockedVault, parseManifest } from "../src/vault/vault.ts";
import { NodeDirSource, sampleIdentity, webFixtures } from "./support.ts";

const enc = new TextEncoder();

function frame(content: Uint8Array, opts: { sha?: Uint8Array; length?: number; padding?: Uint8Array; magic?: string; version?: number } = {}): Uint8Array {
  const sha = opts.sha ?? createHash("sha256").update(content).digest();
  const pad = opts.padding ?? new Uint8Array(3);
  const out = new Uint8Array(45 + content.length + pad.length);
  out.set(enc.encode(opts.magic ?? "INKB"), 0);
  out[4] = opts.version ?? 1;
  out.set(sha, 5);
  new DataView(out.buffer).setBigUint64(37, BigInt(opts.length ?? content.length));
  out.set(content, 45);
  out.set(pad, 45 + content.length);
  return out;
}

function stream(bytes: Uint8Array, chunk = 7): ReadableStream<Uint8Array> {
  let at = 0;
  return new ReadableStream({
    pull(c) {
      if (at >= bytes.length) return c.close();
      c.enqueue(bytes.slice(at, at + chunk));
      at += chunk;
    },
  });
}

function ref(content: Uint8Array, type = "text/plain") {
  return { sha256: createHash("sha256").update(content).digest("hex"), size: content.length, type };
}

async function code(p: Promise<unknown>): Promise<string> {
  try {
    await p;
    return "ok";
  } catch (e) {
    if (e instanceof BlobError) return e.code;
    throw e;
  }
}

describe("blob names and framing", () => {
  it("matches the test vector of §8.1.3", () => {
    // The epoch key K_e = 00 01 … 1f; the name is keyed by blobNameKey = HKDF-SHA256(K_e, "sempere/1 blob name").
    const epochKey = Uint8Array.from({ length: 32 }, (_, i) => i);
    const content = enc.encode("hello, sempere!\n");
    const sha = createHash("sha256").update(content).digest();
    expect(sha.toString("hex")).toBe("8ff2ca4079cee96a407a038a996ef5d0dd317f201fddc04174f0d89b763add65");
    const name = createHmac("sha256", deriveEpoch(epochKey, epochInfo.blobNameKey)).update(Buffer.concat([enc.encode("sempere/1"), Uint8Array.of(0), enc.encode("blob"), Uint8Array.of(0), sha])).digest("hex");
    // BlobStoreTests.testBlobNameKnownAnswer (Swift).
    expect(name).toBe("540202258da1b7aa71188692543fcd1704765f5f52a89f9a7649e6d36878dda9");
    expect(blobKind("text/plain")).toBe("bin");
    expect([61, 1000, 482158, 28311597].map(padme)).toEqual([64, 1024, 483328, 28835840]);
    expect([0, 1, 2, 3].map(padme)).toEqual([0, 1, 2, 3]);
  });

  it("derives kinds from the media type, case and parameters ignored", () => {
    expect(blobKind("IMAGE/JPEG")).toBe("image");
    expect(blobKind("audio/mp4; codecs=mp4a.40.2")).toBe("audio");
    expect(blobKind("application/pdf")).toBe("pdf");
    expect(blobKind("Application/PDF ; x=y")).toBe("pdf");
    expect(blobKind("video/mp4")).toBe("video");
    expect(blobKind("application/vnd.sempere.transcript+json")).toBe("transcript");
    expect(blobKind("application/zip")).toBe("bin");
  });

  it("reads references only when well formed", () => {
    expect(asBlobRef({ sha256: "a".repeat(64), size: 3, type: "image/png" })).toBeDefined();
    expect(asBlobRef({ sha256: "A".repeat(64), size: 3, type: "image/png" })).toBeUndefined();
    expect(asBlobRef({ sha256: "a".repeat(64), size: "3", type: "image/png" })).toBeUndefined();
    expect(asBlobRef(null)).toBeUndefined();
  });

  it("accepts a valid plaintext, in any chunking", async () => {
    const content = enc.encode("hello, sempere!\n");
    for (const n of [1, 7, 45, 1000]) {
      const b = await verifyPlaintext(stream(frame(content), n), ref(content));
      expect(new Uint8Array(await b.arrayBuffer())).toEqual(content);
    }
    const empty = new Uint8Array(0);
    expect((await verifyPlaintext(stream(frame(empty, { padding: new Uint8Array(0) })), ref(empty))).size).toBe(0);
  });

  it("rejects every broken framing with a typed error", async () => {
    const content = enc.encode("hello, sempere!\n");
    const r = ref(content);
    const other = createHash("sha256").update("other").digest();
    const tampered = enc.encode("hello, Sempere!\n");
    expect(await code(verifyPlaintext(stream(frame(content, { magic: "SMPR" })), r))).toBe("corrupt");
    expect(await code(verifyPlaintext(stream(frame(content, { version: 2 })), r))).toBe("corrupt");
    expect(await code(verifyPlaintext(stream(frame(content, { sha: other })), r))).toBe("hashMismatch");
    expect(await code(verifyPlaintext(stream(frame(content, { length: 15 })), r))).toBe("corrupt");
    expect(await code(verifyPlaintext(stream(frame(content, { padding: Uint8Array.of(0, 1) })), r))).toBe("corrupt");
    expect(await code(verifyPlaintext(stream(frame(content).subarray(0, 50)), r))).toBe("corrupt");
    expect(await code(verifyPlaintext(stream(frame(content).subarray(0, 20)), r))).toBe("corrupt");
    // Header claims the referenced hash, but the content was changed.
    expect(await code(verifyPlaintext(stream(frame(tampered, { sha: hexToBytes(r.sha256) })), r))).toBe("hashMismatch");
    // Padding far beyond what any writer produces.
    expect(await code(verifyPlaintext(stream(frame(content, { padding: new Uint8Array(2 << 20) }), 65536), r))).toBe("tooLarge");
  });

  it("cancels the source as soon as a blob fails", async () => {
    const content = enc.encode("hello, sempere!\n");
    let cancelled = false;
    const bytes = frame(content, { magic: "XXXX" });
    let at = 0;
    const src = new ReadableStream<Uint8Array>({
      pull(c) {
        c.enqueue(bytes.slice(at, at + 8));
        at += 8;
      },
      cancel() {
        cancelled = true;
      },
    });
    expect(await code(verifyPlaintext(src, ref(content)))).toBe("corrupt");
    expect(cancelled).toBe(true);
  });

  it("bounds the file it reads by the content size", () => {
    expect(maxFileBytes(0)).toBeGreaterThan(45);
    expect(maxFileBytes(1 << 30)).toBeLessThan((1 << 30) * 1.2);
  });
});

describe("reading blobs from a vault", async () => {
  const dir = join(webFixtures, "render.sempere");
  const source = new NodeDirSource(dir);
  const manifest = parseManifest(await source.read("vault.json", 1 << 24));
  const vault = await UnlockedVault.unlock(manifest, sampleIdentity());
  const note = "77777777-7777-4777-8777-777777777777";
  const photo = new Uint8Array(readFileSync(join(webFixtures, "media", "photo.jpg")));
  const dot = new Uint8Array(readFileSync(join(webFixtures, "media", "dot.png")));

  it("reads a blob through its reference, once per note", async () => {
    const blobs = new NoteBlobs(source, vault, note);
    const r = ref(photo, "image/jpeg");
    const b = await blobs.get(r);
    expect(new Uint8Array(await b.arrayBuffer())).toEqual(photo);
    expect(blobs.get(r)).toBe(blobs.get(r));
  });

  it("does not keep a failure, so a later request tries again", async () => {
    const blobs = new NoteBlobs(source, vault, note);
    const r = ref(enc.encode("never written"), "image/png");
    const first = blobs.get(r);
    expect(await code(first)).toBe("missing");
    expect(blobs.get(r)).not.toBe(first);
    // A different size limit is a different request.
    const ok = ref(photo, "image/jpeg");
    expect(await code(blobs.get(ok, 100))).toBe("tooLarge");
    expect(await code(blobs.get(ok))).toBe("ok");
  });

  it("reports a missing blob, one under another note, and a forged one", async () => {
    expect(await code(readBlob(source, vault, note, ref(enc.encode("never written"), "image/png")))).toBe("missing");
    // References never cross notes (§8.1.1): note 8 has the PNG, note 7's other image is not there.
    expect(await code(readBlob(source, vault, "88888888-8888-4888-8888-888888888888", ref(photo, "image/jpeg")))).toBe("missing");
    // The kind is part of the path: the same content as another kind is not found.
    expect(await code(readBlob(source, vault, note, ref(photo, "application/pdf")))).toBe("missing");
    // The fixture stores the PNG under the name of its first 100 bytes.
    expect(await code(readBlob(source, vault, note, ref(dot.subarray(0, 100), "image/png")))).toBe("hashMismatch");
  });

  it("refuses content over the caller's limit before reading", async () => {
    expect(await code(readBlob(source, vault, note, ref(photo, "image/jpeg"), 100))).toBe("tooLarge");
    expect(await code(readBlob(source, vault, note, { ...ref(photo, "image/jpeg"), size: 2 ** 31 }))).toBe("tooLarge");
  });

  it("reports a file that is not age as undecryptable", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "sempere-blob-"));
    cpSync(dir, tmp, { recursive: true });
    const r = ref(photo, "image/jpeg");
    const [name] = await vault.blobNames(hexToBytes(r.sha256));
    writeFileSync(join(tmp, "notes", note, "att", `${name}.image.age`), "not age");
    expect(await code(readBlob(new NodeDirSource(tmp), vault, note, r))).toBe("undecryptable");
  });

  it("names a blob under the epoch's blobNameKey alone: a name under any other key is not found (§8.1.2)", async () => {
    const r = ref(photo, "image/jpeg");
    const names = await vault.blobNames(hexToBytes(r.sha256));
    expect(names).toHaveLength(1);
    const tmp = mkdtempSync(join(tmpdir(), "sempere-blob-"));
    cpSync(dir, tmp, { recursive: true });
    const att = join(tmp, "notes", note, "att");
    const other = createHmac("sha256", deriveEpoch(new Uint8Array(32), epochInfo.blobNameKey))
      .update(Buffer.concat([enc.encode("sempere/1"), Uint8Array.of(0), enc.encode("blob"), Uint8Array.of(0), hexToBytes(r.sha256)])).digest("hex");
    renameSync(join(att, `${names[0]}.image.age`), join(att, `${other}.image.age`));
    expect(await code(readBlob(new NodeDirSource(tmp), vault, note, r))).toBe("missing");
  });
});
