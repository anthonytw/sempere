// Opening and unlocking vaults, and reading revisions that were tampered with
// (format.md §3.3.2, §4, §5, §9).

import { cpSync, mkdtempSync, readFileSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { loadNote } from "../src/vault/library.ts";
import { RevisionReadError, UnlockedVault, VaultError, checkRecipients, parseIdentity, parseManifest, recipientType,
  recipientsTag, recipientsWarningText, type VaultManifest } from "../src/vault/vault.ts";
import { gunzip } from "../src/vault/gzip.ts";
import { isRevisionFile } from "../src/vault/source.ts";
import { NodeDirSource, fixtures, gzip, sampleIdentity } from "./support.ts";

const lecture = "11111111-1111-4111-8111-111111111111";
const enc = new TextEncoder();

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

describe("manifest", () => {
  it("parses the fixture vault", () => {
    const m = parseManifest(readFileSync(join(fixtures, "sample.sempere", "vault.json")));
    expect(m.format).toBe("sempere/1");
    expect(m.recipients).toHaveLength(1);
    expect(recipientType(m.recipients[0]?.key ?? "")).toBe("mlkem768x25519");
  });

  it("rejects other formats, garbage and duplicate recipients", () => {
    const m = JSON.parse(readFileSync(join(fixtures, "sample.sempere", "vault.json"), "utf8")) as Record<string, unknown>;
    const bad = (v: unknown) => () => parseManifest(enc.encode(JSON.stringify(v)));
    expect(bad({ ...m, format: "sempere/0" })).toThrow(/unsupported vault format/);
    expect(bad({ ...m, recipients: [] })).toThrow(/no recipients/);
    expect(bad({ ...m, recipients: [{ key: "age1nope", label: "", added: "2026-10-04T16:20:00Z" }] })).toThrow(/invalid recipient/);
    const r = (m.recipients as unknown[])[0];
    expect(bad({ ...m, recipients: [r, r] })).toThrow(/duplicate/);
    expect(bad({ ...m, created: "2026-02-30T00:00:00Z" })).toThrow(VaultError);
    expect(() => parseManifest(enc.encode("{"))).toThrow(/not JSON/);
    expect(() => parseManifest(Uint8Array.of(0xff, 0xfe))).toThrow(VaultError);
  });

  it("refuses features that are not an array of strings, as Swift does; null is absent", () => {
    const m = JSON.parse(readFileSync(join(fixtures, "sample.sempere", "vault.json"), "utf8")) as Record<string, unknown>;
    const parse = (features: unknown) => parseManifest(enc.encode(JSON.stringify({ ...m, features })));
    for (const features of ["attachments", [1], ["attachments", 2], {}, 3]) {
      expect(() => parse(features)).toThrow(expect.objectContaining({ code: "manifestCorrupt" }));
    }
    expect(parse(null).features).toEqual([]);
    expect(parse(["attachments"]).features).toEqual(["attachments"]);
  });
});

describe("identity", () => {
  it("takes the PQ key from a whole key file or a bare line", () => {
    const file = readFileSync(join(fixtures, "sample.key"), "utf8");
    expect(parseIdentity(file)).toBe(sampleIdentity());
    expect(parseIdentity(`  ${sampleIdentity().toLowerCase()}  \n`)).toBe(sampleIdentity());
  });

  it("refuses classic keys, nothing, and several keys", () => {
    const classic = readFileSync(join(fixtures, "legacy.key"), "utf8");
    expect(() => parseIdentity(classic)).toThrow(expect.objectContaining({ code: "classicIdentity" }) as Error);
    expect(() => parseIdentity("hello")).toThrow(expect.objectContaining({ code: "badIdentity" }) as Error);
    expect(() => parseIdentity(`${sampleIdentity()}\n${sampleIdentity()}`)).toThrow(/one key/);
  });
});

describe("unlock", () => {
  it("refuses a legacy vault before trying the key (§3.3.2)", async () => {
    const m = parseManifest(readFileSync(join(fixtures, "legacy.sempere", "vault.json")));
    const e = await caught(UnlockedVault.unlock(m, sampleIdentity()));
    expect(e).toBeInstanceOf(VaultError);
    expect((e as VaultError).code).toBe("legacyVault");
  });

  it("says when the key does not open the vault", async () => {
    const m = parseManifest(readFileSync(join(fixtures, "sample.sempere", "vault.json")));
    // A valid PQ identity that is not a recipient: the fixture key with its seed changed.
    const { generateHybridIdentity } = await import("age-encryption");
    const other = await generateHybridIdentity();
    const e = await caught(UnlockedVault.unlock(m, other));
    expect((e as VaultError).code).toBe("wrongKey");
    expect((await caught(UnlockedVault.unlock(m, "AGE-SECRET-KEY-PQ-1NOTAKEY")) as VaultError).code).toBe("badIdentity");
  });
});

describe("recipients tag (format.md §2.1)", () => {
  // The same vector as RecipientsAuthTests.testKnownAnswerVector (Swift).
  it("matches the known-answer vector", async () => {
    const secret = Uint8Array.from({ length: 32 }, (_, i) => i + 1);
    expect(await recipientsTag("0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c", ["age1pq1example0", "age1pq1example1"], secret))
      .toBe("548c16534c81b7cfb1c92c574380129377d3616b02b631d9fa99bf6356b63c0c");
  });

  async function secretOf(m: VaultManifest): Promise<Uint8Array> {
    const { Decrypter, armor } = await import("age-encryption");
    const d = new Decrypter();
    d.addIdentity(sampleIdentity());
    return d.decrypt(armor.decode(m.vaultSecret));
  }

  function withManifest(edit: (o: Record<string, unknown>) => void): VaultManifest {
    const o = JSON.parse(readFileSync(join(fixtures, "sample.sempere", "vault.json"), "utf8")) as Record<string, unknown>;
    edit(o);
    return parseManifest(enc.encode(JSON.stringify(o)));
  }

  it("reports untagged, verified and tampered lists; reading is unaffected", async () => {
    // The committed fixture is tagged (by the Swift writer).
    const committed = parseManifest(readFileSync(join(fixtures, "sample.sempere", "vault.json")));
    const ok = await UnlockedVault.unlock(committed, sampleIdentity());
    const secret = await secretOf(committed);
    const tag = await recipientsTag(committed.vaultId, committed.recipients.map((r) => r.key), secret);
    expect(committed.recipientsTag).toBe(tag);
    const untagged = withManifest((o) => { delete o.recipientsTag; delete o.markersTag; o.features = ["attachments"]; });
    expect((await UnlockedVault.unlock(untagged, sampleIdentity())).recipientsStatus).toEqual({ status: "untagged" });
    expect(ok.recipientsStatus).toEqual({ status: "verified" });
    expect(recipientsWarningText(ok.recipientsStatus)).toBeUndefined();

    const cases: [string, (o: Record<string, unknown>) => void, string][] = [
      ["added recipient", (o) => {
        (o.recipients as unknown[]).push({ key: "age1pq1" + "q".repeat(60), label: "x", added: "2026-10-07T00:00:00Z" });
      }, "tagMismatch"],
      ["tag from another vault", (o) => { o.recipientsTag = "ab".repeat(32); }, "tagMismatch"],
      ["tag of the wrong type", (o) => { o.recipientsTag = 42; }, "tagMismatch"],
      ["uppercase tag", (o) => { o.recipientsTag = tag.toUpperCase(); }, "tagMismatch"],
      ["tag stripped", (o) => { delete o.recipientsTag; }, "tagRemoved"],
    ];
    for (const [name, edit, reason] of cases) {
      const m = withManifest(edit);
      const s = await checkRecipients(m, secret);
      expect(s, name).toEqual({ status: "tampered", reason });
      expect(recipientsWarningText(s), name).toMatch(/device list/);
    }
    // A tampered list still unlocks and reads (the viewer only reports).
    const tampered = await UnlockedVault.unlock(withManifest((o) => { o.recipientsTag = "00".repeat(32); }), sampleIdentity());
    expect(tampered.recipientsStatus.status).toBe("tampered");
    const note = await loadNote(new NodeDirSource(join(fixtures, "sample.sempere")), tampered, lecture);
    expect(note.failures).toEqual([]);
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
    // failure; the content check is the second line of defence.
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
