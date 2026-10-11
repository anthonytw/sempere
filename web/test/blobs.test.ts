// Blobs (format.md §8.1): names, kinds, Padmé, framing checks, and reading
// through a reference from the fixture vault (missing, forged, previous
// secret during a rewrap, size limits).

import { cpSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash, createHmac, hkdfSync } from "node:crypto";
import { Decrypter, Encrypter, armor, identityToRecipient } from "age-encryption";
import { describe, expect, it } from "vitest";
import {
  BlobError, NoteBlobs, asBlobRef, blobKind, hexToBytes, maxFileBytes, padme, readBlob, verifyPlaintext,
} from "../src/vault/blobs.ts";
import { UnlockedVault, parseManifest, rewrapPendingTag } from "../src/vault/vault.ts";
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
    const secret = Uint8Array.from({ length: 32 }, (_, i) => i);
    const content = enc.encode("hello, sempere!\n");
    const sha = createHash("sha256").update(content).digest();
    expect(sha.toString("hex")).toBe("8ff2ca4079cee96a407a038a996ef5d0dd317f201fddc04174f0d89b763add65");
    const name = createHmac("sha256", secret).update(Buffer.concat([enc.encode("sempere/1"), Uint8Array.of(0), enc.encode("blob"), Uint8Array.of(0), sha])).digest("hex");
    expect(name).toBe("13ddeae851cf51d7e9a970d82ca2c99f1dbaa3efaf792248da32b8374d6869af");
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

  it("finds a blob still named under the previous secret during a rewrap (§8.1.5)", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "sempere-blob-"));
    cpSync(dir, tmp, { recursive: true });
    const previous = Uint8Array.from({ length: 32 }, (_, i) => 255 - i);
    const e = new Encrypter();
    e.addRecipient(await identityToRecipient(sampleIdentity()));
    const journal = enc.encode(JSON.stringify({ previousVaultSecret: armor.encode(await e.encrypt(previous)) }));
    const r = ref(photo, "image/jpeg");
    // A journal's secret counts only when vault.json's secretLink links it to
    // the current one (format.md §2.1; security review 2026-10, R4).
    const unlinked = await UnlockedVault.unlock(manifest, sampleIdentity(), journal);
    expect(await unlinked.blobNames(hexToBytes(r.sha256))).toHaveLength(1);
    // Nor does it add a key for derived data such as published summaries (§12).
    const gcm = { name: "AES-GCM", length: 256 } as const;
    expect(await unlinked.derivedKeys("sempere/1 test", gcm, ["decrypt"])).toHaveLength(1);
    const d = new Decrypter();
    d.addIdentity(sampleIdentity());
    const currentSecret = await d.decrypt(armor.decode(manifest.vaultSecret));
    const linkKey = Buffer.from(hkdfSync("sha256", previous, Buffer.alloc(0), "sempere/1 secret link key", 32));
    const secretId = Buffer.from(hkdfSync("sha256", currentSecret, Buffer.alloc(0), "sempere/1 secret id", 32));
    const secretLink = createHmac("sha256", linkKey).update(Buffer.concat([enc.encode("sempere/1"), Uint8Array.of(0),
      enc.encode("secret link"), Uint8Array.of(0), enc.encode(manifest.vaultId), Uint8Array.of(0), secretId])).digest("hex");
    // A legacy (HMAC) link, as an older writer left it: a reader holding both secrets may check it.
    const rewrapPending = await rewrapPendingTag(manifest.vaultId, journal, currentSecret);
    const rewrapping = await UnlockedVault.unlock({ ...manifest, secretLink: { kind: "legacy", hex: secretLink }, rewrapPending },
      sampleIdentity(), journal);
    const [current, old] = await rewrapping.blobNames(hexToBytes(r.sha256));
    expect(await rewrapping.derivedKeys("sempere/1 test", gcm, ["decrypt"])).toHaveLength(2);
    expect(old).toBe(createHmac("sha256", previous).update(Buffer.concat([enc.encode("sempere/1"), Uint8Array.of(0), enc.encode("blob"), Uint8Array.of(0), hexToBytes(r.sha256)])).digest("hex"));
    const att = join(tmp, "notes", note, "att");
    cpSync(join(att, `${current}.image.age`), join(att, `${old}.image.age`));
    const { rmSync } = await import("node:fs");
    rmSync(join(att, `${current}.image.age`));
    const s = new NodeDirSource(tmp);
    expect(await code(readBlob(s, vault, note, r))).toBe("missing");
    expect(new Uint8Array(await (await readBlob(s, rewrapping, note, r)).arrayBuffer())).toEqual(photo);
  });
});
