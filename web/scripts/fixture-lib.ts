// The vault-writing toolkit shared by the fixture generators: age encryption, the SMPR
// record frame, Padmé padding and the keyed blob names and framing (format.md §8.1).
//
// Generated vaults are single-epoch vaults of the key hierarchy (format.md §15). They share the
// committed Swift fixture `Tests/SempereTests/Fixtures/sample.sempere`'s skeleton (vault id, epoch 1's
// key K_1, `vault.json`, `epochs/`, `keys/`; the device key is `sample.key`, the recovery key
// `sample-recovery.key`): the generator unwraps K_1 with the device key, derives `v_e`, `tagKey` and
// `blobNameKey`, encrypts the notes to `v_e`, and copies the skeleton in. vault.json holds no hash of
// the notes, so the Swift CLI verifies the result (`sempere vault verify --root …`) like sample.sempere.

import { Decrypter, Encrypter, armor, identityToRecipient } from "age-encryption";
import { createHash, createHmac } from "node:crypto";
import { cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { concat } from "../src/vault/bytes.ts";
import { epochKeys, parseEpochWrap, vaultRecipient } from "../src/vault/epoch.ts";

const enc = new TextEncoder();
const fixtures = join(import.meta.dirname, "..", "..", "Tests", "SempereTests", "Fixtures");
const skeleton = join(fixtures, "sample.sempere");

/** `sample.key`'s identity line (the throwaway device key of the committed fixtures). */
export function sampleIdentity(): string {
  const line = readFileSync(join(fixtures, "sample.key"), "utf8").split("\n").find((l) => l.startsWith("AGE-SECRET-KEY-PQ-"));
  if (!line) throw new Error("no identity in sample.key");
  return line;
}

/** The skeleton vault's epoch key `K_1`, unwrapped from the device entry of `vault.json` with `sample.key`. */
export async function skeletonEpochKey(): Promise<Uint8Array> {
  const manifest = JSON.parse(readFileSync(join(skeleton, "vault.json"), "utf8")) as {
    vaultId: string; epoch: number; keys: { role: string; key: string; wrap: string }[];
  };
  const identity = sampleIdentity();
  const recipient = await identityToRecipient(identity);
  const entry = manifest.keys.find((k) => k.role === "device" && k.key === recipient);
  if (!entry) throw new Error("sample.key is not a device of sample.sempere");
  const d = new Decrypter();
  d.addIdentity(identity);
  const parsed = parseEpochWrap(await d.decrypt(armor.decode(entry.wrap)), manifest.vaultId, manifest.epoch);
  if ("problem" in parsed) throw new Error(`wrap: ${parsed.problem}`);
  return parsed.key;
}

/** Copies the skeleton's `vault.json`, `epochs/` and `keys/` into `out` (after the notes are written). */
export function installSkeleton(out: string): void {
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, "vault.json"), readFileSync(join(skeleton, "vault.json")));
  for (const dir of ["epochs", "keys"]) cpSync(join(skeleton, dir), join(out, dir), { recursive: true });
}

export async function gzip(data: Uint8Array): Promise<Uint8Array> {
  const s = new Blob([data as Uint8Array<ArrayBuffer>]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(s).arrayBuffer());
}

export function padme(n: number): number {
  if (n < 2) return n;
  const e = Math.floor(Math.log2(n)), z = e - (Math.floor(Math.log2(e)) + 1);
  return Math.ceil(n / 2 ** z) * 2 ** z;
}

export type Ref = { sha256: string; size: number; type: string };

/** Writers for one fixture vault at `out`: files encrypted to the skeleton's `v_e`, tags and names under its keys. */
export async function createVaultWriter({ out }: { out: string }) {
  const key = await skeletonEpochKey();
  const keys = epochKeys(key);
  const recipient = await vaultRecipient(key);

  async function encrypt(data: Uint8Array): Promise<Uint8Array> {
    const e = new Encrypter();
    e.addRecipient(recipient);
    return e.encrypt(data);
  }

  async function frame(json: unknown, noteId: string, filename: string): Promise<Uint8Array> {
    const gz = await gzip(enc.encode(JSON.stringify(json)));
    const hmacKey = await crypto.subtle.importKey("raw", keys.tagKey as Uint8Array<ArrayBuffer>, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const msg = concat([enc.encode("sempere/1"), Uint8Array.of(0), enc.encode(noteId), Uint8Array.of(0),
      enc.encode(filename), Uint8Array.of(0), gz]);
    const tag = new Uint8Array(await crypto.subtle.sign("HMAC", hmacKey, msg as Uint8Array<ArrayBuffer>));
    const body = new Uint8Array(37 + gz.length);
    body.set(enc.encode("SMPR"), 0);
    body[4] = 1;
    body.set(tag, 5);
    body.set(gz, 37);
    return body;
  }

  function blobName(sha: Buffer): string {
    return createHmac("sha256", keys.blobNameKey).update(Buffer.concat([enc.encode("sempere/1"), Uint8Array.of(0), enc.encode("blob"), Uint8Array.of(0), sha])).digest("hex");
  }

  /** Writes `content` as a blob of `noteId` (unless `skip`) and returns its reference. */
  async function writeBlob(noteId: string, content: Uint8Array, type: string, kind: string, opts: { skip?: boolean; asName?: string } = {}): Promise<Ref> {
    const sha = createHash("sha256").update(content).digest();
    const plain = new Uint8Array(padme(45 + content.length));
    plain.set(enc.encode("INKB"), 0);
    plain[4] = 1;
    plain.set(sha, 5);
    new DataView(plain.buffer).setBigUint64(37, BigInt(content.length));
    plain.set(content, 45);
    if (!opts.skip) {
      const dir = join(out, "notes", noteId, "att");
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, `${opts.asName ?? blobName(sha)}.${kind}.age`), await encrypt(plain));
    }
    return { sha256: sha.toString("hex"), size: content.length, type };
  }

  return { encrypt, frame, blobName, writeBlob };
}
