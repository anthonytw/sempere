// Listing a vault fast: published summaries first, only changed notes
// decrypted, cached ciphertext on later visits (docs/web-viewer.md "Opening fast").

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { CachingSource, FileCache, MemoryFileStore } from "../src/vault/cache.ts";
import { type NoteSummary } from "../src/vault/library.ts";
import { type ListingCallbacks, listVault } from "../src/vault/listing.ts";
import { SourceError, type VaultSource } from "../src/vault/source.ts";
import { summariesFileName } from "../src/vault/summaries.ts";
import { type UnlockedVault } from "../src/vault/vault.ts";
import { NodeDirSource, fixtures, golden, sealFor, unlockFixture } from "./support.ts";

const dir = join(fixtures, "sample.sempere");
const lecture = "11111111-1111-4111-8111-111111111111";
const deleted = "22222222-2222-4222-8222-222222222222";
const gone = "33333333-3333-4333-8333-333333333333";

/** The fixture vault plus extra root files, counting reads of `notes/`. */
class FakeServer implements VaultSource {
  readonly label = "fake";
  readonly noteReads: string[] = [];
  readonly inner = new NodeDirSource(dir);
  constructor(readonly extra = new Map<string, Uint8Array>(), readonly hide = new Set<string>()) {}
  read(path: string, max: number): Promise<Uint8Array> {
    const x = this.extra.get(path);
    if (x) return Promise.resolve(x);
    if (path.startsWith("notes/")) this.noteReads.push(path);
    if (path === summariesFileName) return Promise.reject(new SourceError("not found", true));
    return this.inner.read(path, max);
  }
  listNotes() {
    return this.inner.listNotes();
  }
  async listRevisions(id: string) {
    return (await this.inner.listRevisions(id)).filter((f) => !this.hide.has(f));
  }
}

function collect(): { cb: ListingCallbacks; provisional: NoteSummary[]; rows: Map<string, NoteSummary>; gone: string[] } {
  const out = { provisional: [] as NoteSummary[], rows: new Map<string, NoteSummary>(), gone: [] as string[] };
  return {
    ...out,
    cb: {
      provisional: (r) => out.provisional.push(...r),
      row: (r) => out.rows.set(r.id, r),
      gone: (id) => out.gone.push(id),
      progress: () => undefined,
      current: () => true,
    },
  };
}

async function summariesFile(vault: UnlockedVault, edit?: (notes: Record<string, { revisions: string[] }>) => void): Promise<Uint8Array> {
  const content = JSON.parse(readFileSync(join(golden, "sample.summaries.json"), "utf8")) as { notes: Record<string, { revisions: string[] }> };
  edit?.(content.notes);
  return sealFor(vault, content);
}

describe("listing", () => {
  it("decrypts every note when there are no summaries", async () => {
    const { vault } = await unlockFixture(dir);
    const server = new FakeServer();
    const c = collect();
    const r = await listVault(server, vault, c.cb);
    expect(c.provisional).toEqual([]);
    expect(r).toMatchObject({ fromSummaries: 0, read: 2 });
    expect(server.noteReads.length).toBe(7);
    expect(c.rows.get(lecture)?.title).toBe("Fixture lecture");
  });

  it("shows the summaries at once and decrypts nothing that matches", async () => {
    const { vault } = await unlockFixture(dir);
    const server = new FakeServer(new Map([[summariesFileName, await summariesFile(vault, (n) => {
      n[gone] = { ...(n[lecture] as { revisions: string[] }) };
    })]]));
    const c = collect();
    const r = await listVault(server, vault, c.cb);
    expect(c.provisional.map((n) => n.id).sort()).toEqual([lecture, deleted, gone]);
    expect(c.gone).toEqual([gone]);
    expect(r).toMatchObject({ fromSummaries: 2, read: 0 });
    expect(server.noteReads).toEqual([]);
    expect(c.rows.get(deleted)?.deleted).toBe(true);
  });

  it("reads only the notes whose listing differs from their entry", async () => {
    const { vault } = await unlockFixture(dir);
    // The listing lacks the lecture's newest revision: its entry is stale.
    const server = new FakeServer(new Map([[summariesFileName, await summariesFile(vault)]]),
      new Set(["17911308050000000-a1b2c3d4-3.delta.age"]));
    const c = collect();
    const loaded: string[] = [];
    c.cb.loaded = (n) => loaded.push(n.id);
    const r = await listVault(server, vault, c.cb);
    expect(r).toMatchObject({ fromSummaries: 1, read: 1 });
    expect(server.noteReads.every((p) => p.startsWith(`notes/${lecture}/`))).toBe(true);
    expect(server.noteReads.length).toBe(4);
    // The decrypted note is handed over (the viewer keeps it for opening).
    expect(loaded).toEqual([lecture]);
  });

  it("ignores a damaged summaries file", async () => {
    const { vault } = await unlockFixture(dir);
    const server = new FakeServer(new Map([[summariesFileName, new TextEncoder().encode("SMPU\x01 not really")]]));
    const c = collect();
    const r = await listVault(server, vault, c.cb);
    expect(r.summariesProblem).toBeDefined();
    expect(r).toMatchObject({ fromSummaries: 0, read: 2 });
  });

  it("downloads nothing on a second visit without summaries, and evicts what is gone", async () => {
    const { vault } = await unlockFixture(dir);
    const store = new MemoryFileStore();
    const visit = async (server: FakeServer) => {
      const src = new CachingSource(server, new FileCache(store), "https://x/vault/\nid");
      return { r: await listVault(src, vault, collect().cb), reads: server.noteReads.length };
    };
    expect((await visit(new FakeServer())).reads).toBe(7);
    expect(store.files.size).toBe(7);
    const second = await visit(new FakeServer());
    expect(second.reads).toBe(0);
    expect(second.r.read).toBe(2);   // decrypted from the cache
    const third = await visit(new FakeServer(new Map(), new Set(["17911308050000000-a1b2c3d4-3.delta.age"])));
    expect(third.r.evicted).toBe(1);
    expect(store.files.size).toBe(6);
  });
});
