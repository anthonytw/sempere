// A browser cache of vault CIPHERTEXT, keyed by vault and file path, so a
// second visit downloads only files it has not seen. Revisions and blobs are
// write-once (format.md §1), so a cached file never needs re-fetching; files
// gone from the listing are evicted, the rest is size-bounded (least recently
// used first). Only encrypted files are stored, exactly as the server sent
// them: everything read from the cache is decrypted and verified like a
// download, and a cached file that fails is evicted and fetched again.
// Nothing decrypted, and never the key, is stored (docs/web-viewer.md).

import { isLowercaseUUID } from "../format/json.ts";
import { concat } from "./bytes.ts";
import { boundedStream, SourceError, type VaultSource, isRevisionFile } from "./source.ts";

/** Where the cached bytes live: IndexedDB in the browser, memory in tests. */
export interface FileStore {
  /** Every entry's key, size and last use (Unix ms), without the bytes. */
  entries(): Promise<{ key: string; size: number; used: number }[]>;
  get(key: string): Promise<Uint8Array | undefined>;
  put(key: string, bytes: Uint8Array, used: number): Promise<void>;
  touch(key: string, used: number): Promise<void>;
  delete(keys: string[]): Promise<void>;
  clear(): Promise<void>;
}

export interface CacheLimits {
  /** Total bytes kept (all vaults). */
  maxBytes: number;
  /** Larger files are not cached. */
  maxEntryBytes: number;
}

export const defaultCacheLimits: CacheLimits = { maxBytes: 512 * 1024 * 1024, maxEntryBytes: 64 * 1024 * 1024 };

/**
 * True for the write-once files a cache may keep: revisions
 * (`notes/<id>/<revision>`) and blobs (`notes/<id>/att/<name>.<kind>.age`).
 */
export function isCacheablePath(path: string): boolean {
  const p = path.split("/");
  if (p[0] !== "notes" || !isLowercaseUUID(p[1] ?? "")) return false;
  if (p.length === 3) return isRevisionFile(p[2] ?? "");
  return p.length === 4 && p[2] === "att" && /^[0-9a-f]{64}\.[a-z]+\.age$/.test(p[3] ?? "");
}

/** The LRU index over a `FileStore`, shared by every vault opened in the tab. */
export class FileCache {
  private index?: Promise<Map<string, { size: number; used: number }>>;
  private total = 0;
  /** Requests answered from the cache and from the network since the cache was made (status, tests). */
  readonly stats = { hits: 0, misses: 0 };

  constructor(private readonly store: FileStore, readonly limits: CacheLimits = defaultCacheLimits,
    private readonly now: () => number = () => Date.now()) {}

  private load(): Promise<Map<string, { size: number; used: number }>> {
    this.index ??= this.store.entries().then((list) => {
      const m = new Map(list.map((e) => [e.key, { size: e.size, used: e.used }]));
      this.total = list.reduce((n, e) => n + e.size, 0);
      return m;
    }, () => new Map());
    return this.index;
  }

  /** Bytes held. */
  async size(): Promise<{ files: number; bytes: number }> {
    const m = await this.load();
    return { files: m.size, bytes: this.total };
  }

  async get(key: string): Promise<Uint8Array | undefined> {
    const m = await this.load();
    const meta = m.get(key);
    if (!meta) return undefined;
    let bytes: Uint8Array | undefined;
    try {
      bytes = await this.store.get(key);
    } catch {
      bytes = undefined;
    }
    if (!bytes || bytes.length !== meta.size) {
      await this.delete([key]);
      return undefined;
    }
    meta.used = this.now();
    void this.store.touch(key, meta.used).catch(() => undefined);
    return bytes;
  }

  async put(key: string, bytes: Uint8Array): Promise<void> {
    if (bytes.length > this.limits.maxEntryBytes) return;
    const m = await this.load();
    const used = this.now();
    try {
      await this.store.put(key, bytes, used);
    } catch {
      return; // quota or a closed database: just not cached
    }
    const old = m.get(key);
    this.total += bytes.length - (old?.size ?? 0);
    m.set(key, { size: bytes.length, used });
    if (this.total > this.limits.maxBytes) {
      const victims: string[] = [];
      let total = this.total;
      for (const [k, v] of [...m.entries()].sort((a, b) => a[1].used - b[1].used)) {
        if (total <= this.limits.maxBytes) break;
        if (k === key) continue;
        victims.push(k);
        total -= v.size;
      }
      await this.delete(victims);
    }
  }

  async delete(keys: string[]): Promise<void> {
    if (keys.length === 0) return;
    const m = await this.load();
    for (const k of keys) {
      const v = m.get(k);
      if (v) {
        this.total -= v.size;
        m.delete(k);
      }
    }
    await this.store.delete(keys).catch(() => undefined);
  }

  /** Keys under `prefix`. */
  async keys(prefix: string): Promise<string[]> {
    return [...(await this.load()).keys()].filter((k) => k.startsWith(prefix));
  }

  async clear(): Promise<void> {
    const m = await this.load();
    m.clear();
    this.total = 0;
    await this.store.clear().catch(() => undefined);
  }
}

/**
 * The cache namespace of a vault: its URL (`label`), its id, and a
 * fingerprint of its key state, the SHA-256 of `vaultSecret` as sealed in
 * `vault.json` and of the rewrap journal if one is there (format.md §3.3.1).
 * Every recipient change re-encrypts the secret, and a rewrap rewrites the
 * write-once files in place under the same names, so after an addition, a
 * removal or the end of a rewrap the namespace changes, and the copies of
 * files encrypted to the old recipients (openable by a removed key) are
 * dropped by `dropOtherNamespaces` (security review 2026-10, P4).
 */
export async function cacheNamespace(label: string, vaultId: string, sealedSecret: string,
  journal?: Uint8Array): Promise<string> {
  const enc = new TextEncoder();
  const secret = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(sealedSecret)));
  const parts = [secret];
  if (journal) parts.push(new Uint8Array(await crypto.subtle.digest("SHA-256", journal as Uint8Array<ArrayBuffer>)));
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", concat(parts) as Uint8Array<ArrayBuffer>));
  const fingerprint = [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${label}\n${vaultId}\n${fingerprint}`;
}

/**
 * A source that answers write-once paths from a `FileCache` and stores what
 * it downloads. `namespace` separates vaults (`cacheNamespace`: URL, vault
 * id and key state).
 */
export class CachingSource implements VaultSource {
  readonly label: string;

  constructor(private readonly inner: VaultSource, private readonly cache: FileCache, private readonly namespace: string) {
    this.label = inner.label;
  }

  private key(path: string): string {
    return `${this.namespace}\n${path}`;
  }

  async read(path: string, maxBytes: number): Promise<Uint8Array> {
    if (!isCacheablePath(path)) return this.inner.read(path, maxBytes);
    const hit = await this.cache.get(this.key(path));
    if (hit && hit.length <= maxBytes) {
      this.cache.stats.hits++;
      return hit;
    }
    this.cache.stats.misses++;
    const bytes = await this.inner.read(path, maxBytes);
    await this.cache.put(this.key(path), bytes);
    return bytes;
  }

  async stream(path: string, maxBytes: number): Promise<ReadableStream<Uint8Array>> {
    const open = () => this.inner.stream ? this.inner.stream(path, maxBytes)
      : this.inner.read(path, maxBytes).then((b) => new Blob([b as Uint8Array<ArrayBuffer>]).stream());
    if (!isCacheablePath(path)) return open();
    const hit = await this.cache.get(this.key(path));
    if (hit && hit.length <= maxBytes) {
      this.cache.stats.hits++;
      return boundedStream(new Blob([hit as Uint8Array<ArrayBuffer>]).stream(), maxBytes, path);
    }
    this.cache.stats.misses++;
    const body = await open();
    // Kept only when the whole file passed through (a cancelled read stores nothing).
    const chunks: Uint8Array[] = [];
    let total = 0;
    const limit = this.cache.limits.maxEntryBytes;
    const cache = this.cache, key = this.key(path);
    return body.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, c) {
        if (total <= limit) chunks.push(chunk);
        total += chunk.length;
        c.enqueue(chunk);
      },
      async flush() {
        if (total > limit) return;
        const out = new Uint8Array(total);
        let at = 0;
        for (const ch of chunks) {
          out.set(ch, at);
          at += ch.length;
        }
        await cache.put(key, out);
      },
    }));
  }

  /**
   * Drops every cached file of the same vault (URL and id) cached under
   * another namespace: an earlier key state, or a cache written before key
   * states were part of the namespace. Returns how many were dropped.
   */
  async dropOtherNamespaces(): Promise<number> {
    const vault = this.namespace.slice(0, this.namespace.lastIndexOf("\n") + 1);
    const mine = `${this.namespace}\n`;
    const victims = (await this.cache.keys(vault)).filter((k) => !k.startsWith(mine));
    await this.cache.delete(victims);
    return victims.length;
  }

  /** Drops a cached file (it failed to verify); true when it was cached. */
  async evict(path: string): Promise<boolean> {
    const key = this.key(path);
    const had = (await this.cache.keys(key)).includes(key);
    if (had) await this.cache.delete([key]);
    return had;
  }

  listNotes(): Promise<string[]> {
    return this.inner.listNotes();
  }

  listRevisions(noteId: string): Promise<string[]> {
    return this.inner.listRevisions(noteId);
  }

  /**
   * Evicts this vault's cached files that the listing no longer has:
   * revisions not listed, and every file of a note that is gone. Blobs of
   * listed notes stay (their names are not listed; LRU bounds them).
   */
  async retain(listing: Map<string, string[]>): Promise<number> {
    const prefix = `${this.namespace}\n`;
    const victims: string[] = [];
    for (const key of await this.cache.keys(prefix)) {
      const p = key.slice(prefix.length).split("/");
      const files = listing.get(p[1] ?? "");
      if (!files) victims.push(key);
      else if (p.length === 3 && !files.includes(p[2] ?? "")) victims.push(key);
    }
    await this.cache.delete(victims);
    return victims.length;
  }
}

/** A store in memory (tests, and browsers without IndexedDB). */
export class MemoryFileStore implements FileStore {
  readonly files = new Map<string, { bytes: Uint8Array; used: number }>();

  entries(): Promise<{ key: string; size: number; used: number }[]> {
    return Promise.resolve([...this.files].map(([key, v]) => ({ key, size: v.bytes.length, used: v.used })));
  }

  get(key: string): Promise<Uint8Array | undefined> {
    return Promise.resolve(this.files.get(key)?.bytes);
  }

  put(key: string, bytes: Uint8Array, used: number): Promise<void> {
    this.files.set(key, { bytes, used });
    return Promise.resolve();
  }

  touch(key: string, used: number): Promise<void> {
    const f = this.files.get(key);
    if (f) f.used = used;
    return Promise.resolve();
  }

  delete(keys: string[]): Promise<void> {
    for (const k of keys) this.files.delete(k);
    return Promise.resolve();
  }

  clear(): Promise<void> {
    this.files.clear();
    return Promise.resolve();
  }
}

const dbName = "sempere-viewer-cache";
const dataStore = "files";
const metaStore = "meta";

function done(req: IDBRequest): Promise<unknown> {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new SourceError("IndexedDB request failed"));
  });
}

function finished(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error ?? new SourceError("IndexedDB transaction failed"));
    tx.onabort = () => reject(tx.error ?? new SourceError("IndexedDB transaction aborted"));
  });
}

/**
 * IndexedDB: the bytes in one object store, `{size, used}` in another so the
 * index loads without reading any file.
 */
export class IndexedDBFileStore implements FileStore {
  private constructor(private readonly db: IDBDatabase) {}

  static async open(factory: IDBFactory = indexedDB): Promise<IndexedDBFileStore> {
    const req = factory.open(dbName, 1);
    req.onupgradeneeded = () => {
      req.result.createObjectStore(dataStore);
      req.result.createObjectStore(metaStore);
    };
    return new IndexedDBFileStore(await done(req) as IDBDatabase);
  }

  /** Deletes the whole database (Clear cached data, even when it cannot be opened). */
  static async destroy(factory: IDBFactory = indexedDB): Promise<void> {
    await done(factory.deleteDatabase(dbName));
  }

  close(): void {
    this.db.close();
  }

  async entries(): Promise<{ key: string; size: number; used: number }[]> {
    const tx = this.db.transaction(metaStore, "readonly");
    const store = tx.objectStore(metaStore);
    const [keys, values] = await Promise.all([done(store.getAllKeys()), done(store.getAll())]) as [IDBValidKey[], unknown[]];
    const out: { key: string; size: number; used: number }[] = [];
    keys.forEach((k, i) => {
      const v = values[i] as { size?: unknown; used?: unknown } | undefined;
      if (typeof k === "string" && typeof v?.size === "number" && typeof v.used === "number") out.push({ key: k, size: v.size, used: v.used });
    });
    return out;
  }

  async get(key: string): Promise<Uint8Array | undefined> {
    const v = await done(this.db.transaction(dataStore, "readonly").objectStore(dataStore).get(key));
    return v instanceof Uint8Array ? v : v instanceof ArrayBuffer ? new Uint8Array(v) : undefined;
  }

  async put(key: string, bytes: Uint8Array, used: number): Promise<void> {
    const tx = this.db.transaction([dataStore, metaStore], "readwrite");
    tx.objectStore(dataStore).put(bytes, key);
    tx.objectStore(metaStore).put({ size: bytes.length, used }, key);
    await finished(tx);
  }

  async touch(key: string, used: number): Promise<void> {
    const tx = this.db.transaction(metaStore, "readwrite");
    const store = tx.objectStore(metaStore);
    const v = await done(store.get(key)) as { size: number } | undefined;
    if (v) store.put({ size: v.size, used }, key);
    await finished(tx);
  }

  async delete(keys: string[]): Promise<void> {
    const tx = this.db.transaction([dataStore, metaStore], "readwrite");
    for (const k of keys) {
      tx.objectStore(dataStore).delete(k);
      tx.objectStore(metaStore).delete(k);
    }
    await finished(tx);
  }

  async clear(): Promise<void> {
    const tx = this.db.transaction([dataStore, metaStore], "readwrite");
    tx.objectStore(dataStore).clear();
    tx.objectStore(metaStore).clear();
    await finished(tx);
  }
}
