// The vault-writing toolkit shared by the fixture generators: age encryption, the SMPR
// record frame, Padmé padding and the keyed blob names and framing (format.md §8.1).

import { Encrypter } from "age-encryption";
import { createHash, createHmac, hkdfSync } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { concat } from "../src/vault/bytes.ts";

const enc = new TextEncoder();

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

/**
 * `recipientsTag` and `markersTag` (format.md §2.1) of a `sempere/1` vault with no features, as
 * every writer puts them in `vault.json`. Computed here with node:crypto rather than imported from
 * src/vault/vault.ts, whose module graph uses TypeScript that Node's type stripping rejects; the web
 * tests check these tags with the viewer's own code when they open the fixture.
 */
export function vaultTags(vaultId: string, keys: string[], secret: Uint8Array): { recipientsTag: string; markersTag: string } {
  const z = Uint8Array.of(0);
  const tag = (purpose: string, fields: string[]) => {
    const key = new Uint8Array(hkdfSync("sha256", secret, new Uint8Array(0), `sempere/1 ${purpose} key`, 32));
    const parts = [enc.encode("sempere/1"), z, enc.encode(purpose), z, enc.encode(vaultId.toLowerCase())];
    for (const f of fields) parts.push(z, enc.encode(f));
    return createHmac("sha256", key).update(concat(parts)).digest("hex");
  };
  return { recipientsTag: tag("recipients", keys), markersTag: tag("markers", ["sempere/1"]) };
}

/** Writers for one fixture vault at `out`, encrypted to `recipient`, with HMAC key `secret`. */
export function createVaultWriter({ secret, out, recipient }: { secret: Uint8Array<ArrayBuffer>; out: string; recipient: string }) {
  async function encrypt(data: Uint8Array): Promise<Uint8Array> {
    const e = new Encrypter();
    e.addRecipient(recipient);
    return e.encrypt(data);
  }

  async function frame(json: unknown, noteId: string, filename: string): Promise<Uint8Array> {
    const gz = await gzip(enc.encode(JSON.stringify(json)));
    const key = await crypto.subtle.importKey("raw", secret, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const msg = concat([enc.encode("sempere/1"), Uint8Array.of(0), enc.encode(noteId), Uint8Array.of(0),
      enc.encode(filename), Uint8Array.of(0), gz]);
    const tag = new Uint8Array(await crypto.subtle.sign("HMAC", key, msg as Uint8Array<ArrayBuffer>));
    const body = new Uint8Array(37 + gz.length);
    body.set(enc.encode("SMPR"), 0);
    body[4] = 1;
    body.set(tag, 5);
    body.set(gz, 37);
    return body;
  }

  function blobName(sha: Buffer): string {
    return createHmac("sha256", secret).update(Buffer.concat([enc.encode("sempere/1"), Uint8Array.of(0), enc.encode("blob"), Uint8Array.of(0), sha])).digest("hex");
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
