// A vault above epoch 1 (epoch 3) (format.md §15.14, key hierarchy KH3): `Tests/SempereTests/Fixtures/epochs.sempere`, made
// by `EpochsFixtureTests` (Swift). The viewer reads files under epoch 1's key through the records' keys, but only
// those the record that closed epoch 1 seals with their exact bytes; an unsealed one is set aside.

import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { readBlob } from "../src/vault/blobs.ts";
import { loadNote } from "../src/vault/library.ts";
import { readOptional } from "../src/vault/source.ts";
import { UnlockedVault, limits, parseManifest } from "../src/vault/vault.ts";
import { NodeDirSource, fixtures, sampleIdentity } from "./support.ts";

const before = "44444444-4444-4444-8444-444444444444";
const after = "55555555-5555-4555-8555-555555555555";
const planted = "66666666-6666-4666-8666-666666666666";
const attachment = new TextEncoder().encode("Sempere epochs fixture attachment: synthetic, test-only.\n");

async function open() {
  const source = new NodeDirSource(join(fixtures, "epochs.sempere"));
  const manifest = parseManifest(await source.read("vault.json", 1 << 24));
  const record = await readOptional(source, manifest.epochRecord, limits.epochRecordBytes);
  const vault = await UnlockedVault.unlock(manifest, sampleIdentity(), record,
    (p) => readOptional(source, p, limits.epochRecordBytes));
  return { source, manifest, vault };
}

describe("a vault at epoch 3", () => {
  it("checks, and gets the earlier keys from the records, newest first", async () => {
    const { manifest, vault } = await open();
    expect(manifest.epoch).toBe(3);
    expect(vault.listStatus).toEqual({ status: "verified" });
    expect(vault.older.map((o) => o.epoch)).toEqual([2, 1]);
  });

  it("reads a sealed revision of epoch 1 and one of epoch 2 (sealed in turn)", async () => {
    const { source, vault } = await open();
    expect((await loadNote(source, vault, before)).state?.meta.title).toBe("Before the change");
    expect((await loadNote(source, vault, after)).state?.meta.title).toBe("After the change");
  });

  it("sets aside a revision under epoch 1's key that the record does not seal", async () => {
    const { source, vault } = await open();
    const note = await loadNote(source, vault, planted);
    expect(note.state).toBeUndefined();
    expect(note.failures.length).toBe(1);
    expect(note.failures[0]?.message).toMatch(/^setAside:/);
  });

  it("reads a sealed blob of epoch 1 under its old name", async () => {
    const { source, vault } = await open();
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", attachment));
    const sha = Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
    const blob = await readBlob(source, vault, before, { sha256: sha, size: attachment.length, type: "text/plain" });
    expect(new Uint8Array(await blob.arrayBuffer())).toEqual(attachment);
  });

  it("reads nothing of epoch 1 without the current record", async () => {
    const source = new NodeDirSource(join(fixtures, "epochs.sempere"));
    const manifest = parseManifest(await source.read("vault.json", 1 << 24));
    const vault = await UnlockedVault.unlock(manifest, sampleIdentity());
    expect(vault.listStatus).toEqual({ status: "tampered", reason: "epochRecord" });
    expect(vault.older).toEqual([]);
    const note = await loadNote(source, vault, before);
    expect(note.failures[0]?.message).toMatch(/^undecryptable:/);
  });
  it("does not take an earlier record that does not hash to the link above it (review M1)", async () => {
    const source = new NodeDirSource(join(fixtures, "epochs.sempere"));
    const manifest = parseManifest(await source.read("vault.json", 1 << 24));
    const record = await readOptional(source, manifest.epochRecord, limits.epochRecordBytes);
    // Every older record read back with one byte changed: the walk stops at the first one.
    const vault = await UnlockedVault.unlock(manifest, sampleIdentity(), record, async (p) => {
      const bytes = await readOptional(source, p, limits.epochRecordBytes);
      if (!bytes) return bytes;
      const copy = new Uint8Array(bytes);
      copy[copy.length - 1] = (copy[copy.length - 1] ?? 0) ^ 1;
      return copy;
    });
    expect(vault.older.map((o) => o.epoch)).toEqual([2]);
    const note = await loadNote(source, vault, before);
    expect(note.failures[0]?.message).toMatch(/^undecryptable:/);
  });
});
