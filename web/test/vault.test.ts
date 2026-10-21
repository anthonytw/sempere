// Opening and unlocking vaults of the key hierarchy, and reading revisions that were tampered with
// (format.md §15.3, §4, §5, §9).

import { cpSync, mkdtempSync, readFileSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import { loadNote } from "../src/vault/library.ts";
import { deriveEpoch, epochInfo } from "../src/vault/epoch.ts";
import { RevisionReadError, UnlockedVault, VaultError, deviceEntries, entryFingerprint, isPQRecipient, listWarningText,
  parseIdentity, parseManifest, type VaultManifest } from "../src/vault/vault.ts";
import { gunzip } from "../src/vault/gzip.ts";
import { isRevisionFile } from "../src/vault/source.ts";
import { NodeDirSource, fixtures, gzip, recoveryIdentity, sampleIdentity } from "./support.ts";

const lecture = "11111111-1111-4111-8111-111111111111";
const enc = new TextEncoder();
const manifestPath = join(fixtures, "sample.sempere", "vault.json");

function copy(name: string): string {
  const dir = join(mkdtempSync(join(tmpdir(), "sempere-web-")), name);
  cpSync(join(fixtures, name), dir, { recursive: true });
  return dir;
}

async function caught(p: Promise<unknown>): Promise<unknown> {
  try {
    await p;
  } catch (e) {
    return e;
  }
  throw new Error("expected a rejection");
}

function raw(): Record<string, unknown> {
  return JSON.parse(readFileSync(manifestPath, "utf8")) as Record<string, unknown>;
}

function parse(o: unknown): VaultManifest {
  return parseManifest(enc.encode(JSON.stringify(o)));
}

const record = (): Uint8Array => new Uint8Array(readFileSync(join(fixtures, "sample.sempere", "epochs", readdirSync(join(fixtures, "sample.sempere", "epochs"))[0] ?? "")));

describe("manifest", () => {
  it("parses the fixture vault", () => {
    const m = parseManifest(readFileSync(manifestPath));
    expect(m.format).toBe("sempere/1");
    expect(m.epoch).toBe(1);
    expect(m.keys.map((k) => k.role)).toEqual(["device", "recovery"]);
    expect(m.keys.every((k) => isPQRecipient(k.key))).toBe(true);
    // The id is the first 8 hex digits of the fingerprint (format.md §15.4); the home is the creating device.
    const [device] = m.keys;
    expect(entryFingerprint(device ?? m.keys[0] as never)).toBe(m.home);
    expect(device?.id).toBe(m.home.slice(0, 8));
    expect(deviceEntries(m)).toEqual([{ key: device?.key, label: device?.name }]);
  });

  it("rejects other formats, garbage and the structure format.md §15.3 forbids", () => {
    const m = raw();
    const keys = m.keys as Record<string, unknown>[];
    const bad = (v: unknown) => () => parse(v);
    expect(bad({ ...m, format: "sempere/0" })).toThrow(/unsupported vault format/);
    expect(bad({ ...m, keys: [] })).toThrow(/no device|not one recovery/);
    expect(bad({ ...m, keys: [keys[0]] })).toThrow(/not one recovery/);
    expect(bad({ ...m, keys: [keys[1]] })).toThrow(/no device/);
    expect(bad({ ...m, keys: [keys[0], keys[1], { ...keys[1], key: "age1nope" }] })).toThrow(/not one recovery/);
    expect(bad({ ...m, keys: [{ ...keys[0], key: "age1nope" }, keys[1]] })).toThrow(/post-quantum|not a listed device/);
    expect(bad({ ...m, keys: [keys[0], keys[0], keys[1]] })).toThrow(/listed twice/);
    expect(bad({ ...m, keys: [{ ...keys[0], id: "00000000" }, keys[1]] })).toThrow(/device entry/);
    expect(bad({ ...m, keys: [keys[0], { ...keys[1], kind: "cli" }] })).toThrow(/recovery entry/);
    expect(bad({ ...m, epoch: 2 })).toThrow(/disagree/);
    expect(bad({ ...m, epochRecord: "epochs/1-0000000000000000.epoch.age" })).toThrow(/epoch's record/);
    expect(bad({ ...m, epochReason: "remove" })).toThrow(/epochReason/);
    expect(bad({ ...m, created: "2026-02-30T00:00:00Z" })).toThrow(VaultError);
    expect(bad({ ...m, root: "abc" })).toThrow(/lowercase hex/);
    expect(bad({ ...m, listTag: undefined })).toThrow(/listTag/);
    expect(() => parseManifest(enc.encode("{"))).toThrow(/not JSON/);
    expect(() => parseManifest(Uint8Array.of(0xff, 0xfe))).toThrow(VaultError);
  });

  it("refuses a classic X25519 key, alone or next to post-quantum ones (§3.1); a later major may list others", () => {
    const m = raw();
    const keys = m.keys as Record<string, unknown>[];
    const classic = "age1f406y9syjcsa2gj2lgz0s2g7suxrytycqr79zccg3d4spcujegqsgl00rd";
    expect(isPQRecipient(classic)).toBe(false);
    expect(() => parse({ ...m, keys: [keys[0], keys[1], { ...keys[1], role: "device", key: classic }] }))
      .toThrow(expect.objectContaining({ code: "manifestCorrupt" }));
  });

  it("refuses features that are not an array of strings, as Swift does; null is absent", () => {
    const m = raw();
    const p = (features: unknown) => parse({ ...m, features });
    for (const features of ["attachments", [1], ["attachments", 2], {}, 3]) {
      expect(() => p(features)).toThrow(expect.objectContaining({ code: "manifestCorrupt" }));
    }
    expect(p(null).features).toEqual([]);
    expect(p(["attachments"]).features).toEqual(["attachments"]);
  });

  it("refuses a vault.json of a later major that does not decode, and reads one that does", () => {
    const m = raw();
    expect(() => parse({ ...m, format: "sempere/2", keys: "x" })).toThrow(expect.objectContaining({ code: "unsupportedFormat" }));
    expect(parse({ ...m, format: "sempere/2" }).format).toBe("sempere/2");
  });
});

describe("identity", () => {
  it("takes the PQ key from a whole key file (device or recovery) or a bare line", () => {
    const file = readFileSync(join(fixtures, "sample.key"), "utf8");
    expect(parseIdentity(file)).toBe(sampleIdentity());
    expect(parseIdentity(readFileSync(join(fixtures, "sample-recovery.key"), "utf8"))).toBe(recoveryIdentity());
    expect(parseIdentity(`  ${sampleIdentity().toLowerCase()}  \n`)).toBe(sampleIdentity());
  });

  it("refuses classic keys, nothing, and several keys", () => {
    // A stock `age-keygen` (classic X25519) key file.
    const classic = "# created: 2026-10-04T16:20:00Z\n# public key: age1f406y9syjcsa2gj2lgz0s2g7suxrytycqr79zccg3d4spcujegqsgl00rd\n"
      + "AGE-SECRET-KEY-1JQ4L7CGCHC2TE7JUJ7YG4Y4DREUWFD7Y6U5XKFZ3EYTNY62Z5PES6MWJVN\n";
    expect(() => parseIdentity(classic)).toThrow(expect.objectContaining({ code: "classicIdentity" }) as Error);
    expect(() => parseIdentity("hello")).toThrow(expect.objectContaining({ code: "badIdentity" }) as Error);
    expect(() => parseIdentity(`${sampleIdentity()}\n${sampleIdentity()}`)).toThrow(/one key/);
  });
});

describe("unlock", () => {
  const manifest = () => parseManifest(readFileSync(manifestPath));

  it("opens with a device key or with the recovery key, to the same keys", async () => {
    const m = manifest();
    const device = await UnlockedVault.unlock(m, sampleIdentity(), record());
    const recovery = await UnlockedVault.unlock(m, recoveryIdentity(), record());
    expect(device.openedWith).toBe("device");
    expect(recovery.openedWith).toBe("recovery");
    expect(device.recipient).not.toBe(recovery.recipient);
    const hash = new Uint8Array(32).fill(7);
    expect(await device.blobNames(hash)).toEqual(await recovery.blobNames(hash));
    expect(device.listStatus).toEqual({ status: "verified" });
    expect(recovery.listStatus).toEqual({ status: "verified" });
  });

  it("says when the key is not one of the vault's keys, or is not a key", async () => {
    const { generateHybridIdentity } = await import("age-encryption");
    const other = await generateHybridIdentity();
    expect(((await caught(UnlockedVault.unlock(manifest(), other))) as VaultError).code).toBe("keyNotListed");
    expect(((await caught(UnlockedVault.unlock(manifest(), "AGE-SECRET-KEY-PQ-1NOTAKEY"))) as VaultError).code).toBe("badIdentity");
  });

  it("says when a listed key's wrap does not open (swapped wraps), or names another vault", async () => {
    const m = raw();
    const [device, recovery] = m.keys as Record<string, unknown>[];
    const swapped = parse({ ...m, keys: [{ ...device, wrap: recovery?.wrap }, { ...recovery, wrap: device?.wrap }] });
    expect(((await caught(UnlockedVault.unlock(swapped, sampleIdentity()))) as VaultError).code).toBe("wrongKey");
    const elsewhere = parse({ ...m, vaultId: "5a3b1e00-1000-4000-8000-0000000000ff" });
    expect(((await caught(UnlockedVault.unlock(elsewhere, sampleIdentity()))) as VaultError).code).toBe("invalidWrap");
  });
});

describe("vault.json by itself (format.md §15.3)", () => {
  // The viewer keeps no trust record and walks no chain: what it can check is what the file and K_e say.
  const status = async (o: unknown, withRecord: Uint8Array | null = record()) =>
    (await UnlockedVault.unlock(parse(o), sampleIdentity(), withRecord ?? undefined)).listStatus;

  it("refuses a vault.json whose listTag does not verify under K_e, however it was changed", async () => {
    const m = raw();
    const [device, recovery] = m.keys as Record<string, unknown>[];
    const cases: [string, unknown][] = [
      ["a renamed device", { ...m, keys: [{ ...device, name: "Mallory" }, recovery] }],
      ["a changed root", { ...m, root: "ab".repeat(32) }],
      ["a changed record hash", { ...m, epochRecordHash: "ab".repeat(32) }],
      ["a stripped tag", { ...m, listTag: "" }],
      ["a tag of another vault", { ...m, listTag: "ab".repeat(32) }],
      ["an uppercase tag", { ...m, listTag: String(m.listTag).toUpperCase() }],
      ["a changed epoch id", { ...m, epochId: "ab".repeat(32), epochRecord: `epochs/1-${"ab".repeat(8)}.epoch.age` }],
    ];
    for (const [name, json] of cases) {
      const e = await caught(UnlockedVault.unlock(parse(json), sampleIdentity(), record()));
      expect((e as VaultError).code, name).toBe("tamperedList");
    }
  });

  it("reports what the file's own signatures and the epoch record say", async () => {
    const m = raw();
    const flip = (s: unknown) => {
      const o = s as { p256: string; mldsa65: string };
      return { ...o, p256: (o.p256[0] === "0" ? "1" : "0") + o.p256.slice(1) };
    };
    expect(await status(m)).toEqual({ status: "verified" });
    expect(await status({ ...m, authorSig: flip(m.authorSig) })).toEqual({ status: "tampered", reason: "authorSig" });
    expect(await status({ ...m, epochSig: flip(m.epochSig) })).toEqual({ status: "tampered", reason: "epochSig" });
    // The record: missing, or not the one vault.json hashes.
    expect(await status(m, null)).toEqual({ status: "tampered", reason: "epochRecord" });
    const damaged = record().slice();
    damaged[damaged.length - 1] = (damaged[damaged.length - 1] ?? 0) ^ 1;
    expect(await status(m, damaged)).toEqual({ status: "tampered", reason: "epochRecord" });
    expect(listWarningText({ status: "tampered", reason: "authorSig" })).toMatch(/home device/);
    expect(listWarningText({ status: "tampered", reason: "epochRecord" })).toMatch(/key history/);
    expect(listWarningText({ status: "verified" })).toBeUndefined();
    // A tampered but listTag-valid list still unlocks and reads (the viewer only reports).
    const tampered = await UnlockedVault.unlock(parse({ ...m, authorSig: flip(m.authorSig) }), sampleIdentity(), record());
    const note = await loadNote(new NodeDirSource(join(fixtures, "sample.sempere")), tampered, lecture);
    expect(note.failures).toEqual([]);
  });
});

describe("body tag (format.md §4, §15.2)", () => {
  // BodyFramingTests.testTagKnownAnswer (Swift): K_e = 00 01 … 1f, tagKey = HKDF-SHA256(K_e, "sempere/1 body tag").
  it("matches the Swift known answer", () => {
    const tagKey = deriveEpoch(Uint8Array.from({ length: 32 }, (_, i) => i), epochInfo.tagKey);
    const note = "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c", file = "17596320000000003-a1b2c3d4-12.delta.age";
    const message = Buffer.concat([enc.encode("sempere/1"), Uint8Array.of(0), enc.encode(note), Uint8Array.of(0), enc.encode(file),
      Uint8Array.of(0), enc.encode("gzip-bytes")]);
    expect(createHmac("sha256", tagKey).update(message).digest("hex"))
      .toBe("627b94a5b45b3fe4e8761174da0c5633331b4af76d4d4714a0baa6b5dbc718d1");
  });
});

describe("reading revisions", () => {
  async function open(dir: string) {
    const src = new NodeDirSource(dir);
    const vault = await UnlockedVault.unlock(parseManifest(await src.read("vault.json", 1 << 24)), sampleIdentity());
    return { src, vault };
  }

  it("binds each revision to its note and file name (§4)", async () => {
    const dir = copy("sample.sempere");
    const { src, vault } = await open(dir);
    const files = await src.listRevisions(lecture);
    const [first, second] = files as [string, string];
    const data = await src.read(`notes/${lecture}/${first}`, 1 << 28);
    expect((await vault.readRevision(lecture, first, data)).seq).toBe(1);
    // Renamed or moved to another note: the tag no longer matches.
    const asOther = await caught(vault.readRevision(lecture, second, data));
    expect((asOther as RevisionReadError).code).toBe("tagMismatch");
    const otherNote = await caught(vault.readRevision("22222222-2222-4222-8222-222222222222", first, data));
    expect((otherNote as RevisionReadError).code).toBe("tagMismatch");
    // Not age at all.
    const junk = await caught(vault.readRevision(lecture, first, enc.encode("not age")));
    expect((junk as RevisionReadError).code).toBe("undecryptable");
    // A non-canonical name is never read.
    const name = await caught(vault.readRevision(lecture, first.replace("-1.", "-01."), data));
    expect((name as RevisionReadError).code).toBe("undecodable");
  });

  it("reports unreadable revisions with the note and merges the rest", async () => {
    const dir = copy("sample.sempere");
    const notes = join(dir, "notes", lecture);
    const files = readdirSync(notes).filter(isRevisionFile).sort();   // not att/ (format.md §8.1.2)
    // Replace the last delta's bytes with another revision's: tag mismatch.
    const last = files[files.length - 1] ?? "";
    writeFileSync(join(notes, last), readFileSync(join(notes, files[0] ?? "")));
    const { src, vault } = await open(dir);
    const note = await loadNote(src, vault, lecture);
    expect(note.failures.map((f) => f.file)).toEqual([last]);
    expect(note.failures[0]?.message).toMatch(/^tagMismatch/);
    expect(note.state?.meta.title).toBe("Fixture lecture");
  });

  it("rejects a revision whose content names another file (§5)", async () => {
    const dir = copy("sample.sempere");
    const notes = join(dir, "notes", lecture);
    const [first] = readdirSync(notes).filter(isRevisionFile).sort();
    // Renaming changes the name the tag is checked under, so this is a tag
    // failure; the content check is the second line of defense.
    renameSync(join(notes, first ?? ""), join(notes, "17911308010000000-a1b2c3d4-9.delta.age"));
    const { src, vault } = await open(dir);
    const note = await loadNote(src, vault, lecture);
    expect(note.failures).toHaveLength(1);
  });
});

describe("gunzip", () => {
  it("round-trips and bounds the output", async () => {
    const data = new Uint8Array(100_000).fill(7);
    expect(await gunzip(await gzip(data))).toEqual(data);
    await expect(gunzip(await gzip(data), 99_999)).rejects.toThrow(/larger than/);
  });

  it("fails on empty, truncated and corrupt input", async () => {
    const z = await gzip(enc.encode("hello hello hello"));
    await expect(gunzip(new Uint8Array())).rejects.toThrow();
    await expect(gunzip(z.subarray(0, z.length - 6))).rejects.toThrow();
    const bad = z.slice();
    bad[12] = (bad[12] ?? 0) ^ 0xff;
    await expect(gunzip(bad)).rejects.toThrow();
  });
});
