// Test helpers: a vault source over a local directory (Node only).

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { isLowercaseUUID } from "../src/format/json.ts";
import { SourceError, type VaultSource, isRevisionFile } from "../src/vault/source.ts";
import { sealSummaries, summariesKeyInfo } from "../src/vault/summaries.ts";
import { UnlockedVault, parseManifest } from "../src/vault/vault.ts";

export const repo = join(import.meta.dirname, "..", "..");
export const fixtures = join(repo, "Tests", "SempereTests", "Fixtures");
export const webFixtures = join(import.meta.dirname, "fixtures");
export const golden = join(import.meta.dirname, "golden");

export function sampleIdentity(): string {
  const text = readFileSync(join(fixtures, "sample.key"), "utf8");
  const line = text.split("\n").find((l) => l.startsWith("AGE-SECRET-KEY-PQ-"));
  if (!line) throw new Error("no key in sample.key");
  return line;
}

export class NodeDirSource implements VaultSource {
  constructor(readonly root: string, readonly label = root) {}

  read(path: string, maxBytes: number): Promise<Uint8Array> {
    const p = join(this.root, path);
    try {
      if (statSync(p).size > maxBytes) return Promise.reject(new SourceError("too large"));
      return Promise.resolve(new Uint8Array(readFileSync(p)));
    } catch {
      return Promise.reject(new SourceError(`${path} not found`, true));
    }
  }

  listNotes(): Promise<string[]> {
    return Promise.resolve(readdirSync(join(this.root, "notes")).filter(isLowercaseUUID).sort());
  }

  listRevisions(id: string): Promise<string[]> {
    return Promise.resolve(readdirSync(join(this.root, "notes", id)).filter(isRevisionFile).sort());
  }
}

export async function gzip(data: Uint8Array): Promise<Uint8Array> {
  const s = new Blob([data as Uint8Array<ArrayBuffer>]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(s).arrayBuffer());
}

/** Seals JSON content for `vault` with its own derived key (the viewer only reads; tests write). */
export async function sealFor(vault: UnlockedVault, json: unknown, vaultId = vault.manifest.vaultId): Promise<Uint8Array> {
  const [key] = await vault.derivedKeys(summariesKeyInfo, { name: "AES-GCM", length: 256 }, ["encrypt"]);
  if (!key) throw new Error("no key");
  return sealSummaries(await gzip(new TextEncoder().encode(JSON.stringify(json))), key, vaultId);
}

export async function unlockFixture(dir: string): Promise<{ source: NodeDirSource; vault: UnlockedVault }> {
  const source = new NodeDirSource(dir);
  const vault = await UnlockedVault.unlock(parseManifest(await source.read("vault.json", 1 << 24)), sampleIdentity());
  return { source, vault };
}

