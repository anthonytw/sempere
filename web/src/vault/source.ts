// Where vault files come from: a static or WebDAV URL, a folder opened with
// the File System Access API, or a dropped / picked folder. Every source only
// reads; names are validated before use (format.md §1, §5) and sizes bounded
// (§9). Nothing is ever sent anywhere but the read requests themselves.

import { isLowercaseUUID } from "../format/json.ts";
import { parseRevisionName, revisionFilename } from "../format/ids.ts";

export class SourceError extends Error {
  constructor(message: string, readonly notFound = false) {
    super(message);
    this.name = "SourceError";
  }
}

export interface VaultSource {
  /** Shown in the UI. */
  readonly label: string;
  /** Reads `path` (relative to the vault root, `/`-separated); throws `SourceError` (notFound when absent). */
  read(path: string, maxBytes: number): Promise<Uint8Array>;
  /**
   * Reads `path` as a stream that fails once more than `maxBytes` arrive
   * (blobs, format.md §8.1.4); optional, `openStream` falls back to `read`.
   */
  stream?(path: string, maxBytes: number): Promise<ReadableStream<Uint8Array>>;
  /** Lowercase-UUID note directory names. */
  listNotes(): Promise<string[]>;
  /** Canonical revision file names of one note (format.md §5); `att/` and unknown files skipped. */
  listRevisions(noteId: string): Promise<string[]>;
  /**
   * Drops a locally cached copy of `path` that failed to verify, so the next
   * read downloads it again; true when there was one (`CachingSource`).
   */
  evict?(path: string): Promise<boolean>;
}

/** Reads `path`, or undefined when it does not exist. */
export async function readOptional(src: VaultSource, path: string, maxBytes: number): Promise<Uint8Array | undefined> {
  try {
    return await src.read(path, maxBytes);
  } catch (e) {
    if (e instanceof SourceError && e.notFound) return undefined;
    throw e;
  }
}

/** Opens `path` as a bounded stream, through `stream` when the source has it. */
export async function openStream(src: VaultSource, path: string, maxBytes: number): Promise<ReadableStream<Uint8Array>> {
  if (src.stream) return src.stream(path, maxBytes);
  const bytes = await src.read(path, maxBytes);
  return new ReadableStream({
    start(c) {
      c.enqueue(bytes);
      c.close();
    },
  });
}

/** Passes a stream through, failing with `SourceError` once more than `maxBytes` have passed. */
export function boundedStream(body: ReadableStream<Uint8Array>, maxBytes: number, what: string): ReadableStream<Uint8Array> {
  let total = 0;
  return body.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, c) {
      total += chunk.length;
      if (total > maxBytes) throw new SourceError(`${what} is larger than ${maxBytes} bytes`);
      c.enqueue(chunk);
    },
  }));
}

/** A `File` as a bounded stream. */
function fileStream(file: File, path: string, maxBytes: number): ReadableStream<Uint8Array> {
  if (file.size > maxBytes) throw new SourceError(`${path} is larger than ${maxBytes} bytes`);
  return boundedStream(file.stream(), maxBytes, path);
}

export function isRevisionFile(name: string): boolean {
  const n = parseRevisionName(name);
  return n !== undefined && revisionFilename(n) === name;
}

function sortedUnique(names: Iterable<string>): string[] {
  return [...new Set(names)].sort();
}

/** Reads a response body, failing instead of buffering more than `maxBytes`. */
async function boundedBody(res: Response, maxBytes: number, what: string): Promise<Uint8Array> {
  const declared = Number(res.headers.get("content-length") ?? "NaN");
  if (Number.isFinite(declared) && declared > maxBytes) throw new SourceError(`${what} is larger than ${maxBytes} bytes`);
  if (!res.body) return new Uint8Array(await res.arrayBuffer());
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > maxBytes) {
      await reader.cancel();
      throw new SourceError(`${what} is larger than ${maxBytes} bytes`);
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}

// MARK: - Static index (`sempere vault index`)

/** Name of the listing `sempere vault index` writes at the vault root. */
export const indexFileName = "sempere-index.json";
export const maxIndexBytes = 64 * 1024 * 1024;

export interface VaultIndex {
  notes: Map<string, string[]>;
}

/**
 * Parses `sempere-index.json` (docs/web-viewer.md): `{"format":
 * "sempere-index/1", "notes": {"<noteId>": ["<revision file>", …]}}`.
 * Entries that are not note ids or revision names are ignored, like unknown
 * files in a vault.
 */
export function parseIndex(bytes: Uint8Array): VaultIndex {
  let json: unknown;
  try {
    json = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new SourceError(`${indexFileName} is not JSON`);
  }
  if (typeof json !== "object" || json === null || Array.isArray(json)) throw new SourceError(`${indexFileName} is not an object`);
  const o = json as Record<string, unknown>;
  if (o.format !== "sempere-index/1") throw new SourceError(`${indexFileName} has an unknown format`);
  const notes = new Map<string, string[]>();
  const raw = o.notes;
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) throw new SourceError(`${indexFileName} has no notes`);
  for (const [id, files] of Object.entries(raw)) {
    if (!isLowercaseUUID(id) || !Array.isArray(files)) continue;
    notes.set(id, sortedUnique(files.filter((f): f is string => typeof f === "string" && isRevisionFile(f))));
  }
  return { notes };
}

// MARK: - WebDAV PROPFIND

const hrefPattern = /<(?:[A-Za-z_][\w.-]*:)?href(?:\s[^>]*)?>([^<]*)<\/(?:[A-Za-z_][\w.-]*:)?href\s*>/g;

function decodeEntities(s: string): string {
  return s.replace(/&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);/g, (m, e: string) => {
    switch (e) {
      case "amp": return "&";
      case "lt": return "<";
      case "gt": return ">";
      case "quot": return "\"";
      case "apos": return "'";
      default: {
        const cp = e.startsWith("#x") ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
        return cp > 0 && cp <= 0x10ffff ? String.fromCodePoint(cp) : m;
      }
    }
  });
}

/**
 * The child names in a PROPFIND (Depth: 1) multistatus body: the last path
 * segment of every `href`, percent-decoded. Only names are taken from the
 * body; callers validate them, so a hostile body can at most list names.
 */
export function propfindNames(xml: string): string[] {
  const out: string[] = [];
  for (const m of xml.matchAll(hrefPattern)) {
    let href = decodeEntities((m[1] ?? "").trim());
    try {
      href = new URL(href, "http://x/").pathname;
    } catch {
      continue;
    }
    const segments = href.split("/").filter((s) => s.length > 0);
    const last = segments[segments.length - 1];
    if (last === undefined) continue;
    try {
      out.push(decodeURIComponent(last));
    } catch {
      continue;
    }
  }
  return out;
}

// MARK: - HTTP (static files or WebDAV)

export type HTTPMode = "auto" | "index" | "webdav";

/**
 * A vault under an `http(s)` URL. Listing uses `sempere-index.json` when the
 * server has one, else WebDAV `PROPFIND` (Depth: 1). Requests carry cookies
 * and HTTP authentication for the same origin only (`fetch` defaults), never
 * the key.
 */
export class HTTPSource implements VaultSource {
  readonly label: string;
  private readonly base: URL;
  private index?: VaultIndex | null;

  constructor(url: string, private readonly mode: HTTPMode = "auto", private readonly fetcher: typeof fetch = fetch.bind(globalThis)) {
    let u: URL;
    try {
      u = new URL(url, globalThis.location?.href);
    } catch {
      throw new SourceError("not a valid URL");
    }
    if (u.protocol !== "https:" && u.protocol !== "http:") throw new SourceError("only http(s) URLs can be opened");
    if (u.username || u.password) throw new SourceError("put credentials in the browser's login prompt, not in the URL");
    if (!u.pathname.endsWith("/")) u.pathname += "/";
    u.search = "";
    u.hash = "";
    this.base = u;
    this.label = u.href;
  }

  private url(path: string): URL {
    return new URL(path.split("/").map(encodeURIComponent).join("/"), this.base);
  }

  private async get(path: string): Promise<Response> {
    let res: Response;
    try {
      res = await this.fetcher(this.url(path), { method: "GET", cache: "no-cache" });
    } catch (e) {
      throw new SourceError(`cannot fetch ${path}: ${e instanceof Error ? e.message : String(e)}`);
    }
    if (res.status === 404 || res.status === 410) throw new SourceError(`${path} not found`, true);
    if (!res.ok) throw new SourceError(`${path}: HTTP ${res.status}`);
    return res;
  }

  async read(path: string, maxBytes: number): Promise<Uint8Array> {
    return boundedBody(await this.get(path), maxBytes, path);
  }

  async stream(path: string, maxBytes: number): Promise<ReadableStream<Uint8Array>> {
    const res = await this.get(path);
    const declared = Number(res.headers.get("content-length") ?? "NaN");
    if (Number.isFinite(declared) && declared > maxBytes) {
      await res.body?.cancel();
      throw new SourceError(`${path} is larger than ${maxBytes} bytes`);
    }
    if (!res.body) return boundedStream(new Blob([await res.arrayBuffer()]).stream(), maxBytes, path);
    return boundedStream(res.body, maxBytes, path);
  }

  private async loadIndex(): Promise<VaultIndex | null> {
    if (this.index !== undefined) return this.index;
    if (this.mode === "webdav") return (this.index = null);
    const bytes = await readOptional(this, indexFileName, maxIndexBytes);
    if (!bytes && this.mode === "index") throw new SourceError(`no ${indexFileName} at ${this.label} (run \`sempere vault index\`)`);
    this.index = bytes ? parseIndex(bytes) : null;
    return this.index;
  }

  private async propfind(path: string): Promise<string[]> {
    let res: Response;
    try {
      res = await this.fetcher(this.url(path), {
        method: "PROPFIND", headers: { Depth: "1", "Content-Type": "application/xml; charset=utf-8" },
        body: "<?xml version=\"1.0\" encoding=\"utf-8\"?><propfind xmlns=\"DAV:\"><prop><resourcetype/></prop></propfind>",
      });
    } catch (e) {
      throw new SourceError(`cannot list ${path || "the vault"}: ${e instanceof Error ? e.message : String(e)}`);
    }
    if (res.status === 404) return [];
    if (res.status !== 207) {
      throw new SourceError(`cannot list ${path || "the vault"} (HTTP ${res.status}): the server needs WebDAV or a ${indexFileName}`);
    }
    const body = await boundedBody(res, 16 * 1024 * 1024, "listing");
    return propfindNames(new TextDecoder().decode(body));
  }

  async listNotes(): Promise<string[]> {
    const index = await this.loadIndex();
    if (index) return [...index.notes.keys()].sort();
    return sortedUnique((await this.propfind("notes/")).filter(isLowercaseUUID));
  }

  async listRevisions(noteId: string): Promise<string[]> {
    const index = await this.loadIndex();
    if (index) return index.notes.get(noteId) ?? [];
    return sortedUnique((await this.propfind(`notes/${noteId}/`)).filter(isRevisionFile));
  }
}

// MARK: - Local folders

/** A folder given as a flat list of files with vault-relative paths (drop or `<input webkitdirectory>`). */
export class FileListSource implements VaultSource {
  private readonly files = new Map<string, File>();

  constructor(readonly label: string, entries: Iterable<[string, File]>) {
    for (const [path, file] of entries) this.files.set(path, file);
  }

  /**
   * Builds a source from files whose paths start with the vault folder's
   * name (`Notes.sempere/vault.json`): the folder holding `vault.json` at the
   * shallowest depth is the vault.
   */
  static fromPaths(files: Iterable<[string, File]>): FileListSource {
    const all = [...files];
    const roots = all.map(([p]) => p).filter((p) => p === "vault.json" || p.endsWith("/vault.json"))
      .sort((a, b) => a.split("/").length - b.split("/").length);
    const manifest = roots[0];
    if (manifest === undefined) throw new SourceError("the folder has no vault.json");
    const prefix = manifest.slice(0, manifest.length - "vault.json".length);
    const label = prefix.replace(/\/$/, "") || "folder";
    return new FileListSource(label, all.filter(([p]) => p.startsWith(prefix)).map(([p, f]) => [p.slice(prefix.length), f]));
  }

  read(path: string, maxBytes: number): Promise<Uint8Array> {
    const f = this.files.get(path);
    if (!f) return Promise.reject(new SourceError(`${path} not found`, true));
    if (f.size > maxBytes) return Promise.reject(new SourceError(`${path} is larger than ${maxBytes} bytes`));
    return f.arrayBuffer().then((b) => new Uint8Array(b));
  }

  stream(path: string, maxBytes: number): Promise<ReadableStream<Uint8Array>> {
    const f = this.files.get(path);
    if (!f) return Promise.reject(new SourceError(`${path} not found`, true));
    try {
      return Promise.resolve(fileStream(f, path, maxBytes));
    } catch (e) {
      return Promise.reject(e instanceof Error ? e : new Error(String(e)));
    }
  }

  listNotes(): Promise<string[]> {
    const ids = [...this.files.keys()].map((p) => p.split("/")).filter((s) => s.length === 3 && s[0] === "notes")
      .map((s) => s[1] ?? "").filter(isLowercaseUUID);
    return Promise.resolve(sortedUnique(ids));
  }

  listRevisions(noteId: string): Promise<string[]> {
    const prefix = `notes/${noteId}/`;
    const names = [...this.files.keys()].filter((p) => p.startsWith(prefix)).map((p) => p.slice(prefix.length))
      .filter((n) => !n.includes("/") && isRevisionFile(n));
    return Promise.resolve(sortedUnique(names));
  }
}

/** The subset of the File System Access API this source uses. */
export interface DirectoryHandle {
  readonly kind: "directory";
  readonly name: string;
  getDirectoryHandle(name: string): Promise<DirectoryHandle>;
  getFileHandle(name: string): Promise<{ getFile(): Promise<File> }>;
  entries(): AsyncIterable<[string, { kind: "file" | "directory" }]>;
}

function isNotFound(e: unknown): boolean {
  return e instanceof DOMException && (e.name === "NotFoundError" || e.name === "TypeMismatchError");
}

/** A folder opened with `showDirectoryPicker()` (read permission only). */
export class DirectorySource implements VaultSource {
  readonly label: string;

  constructor(private readonly root: DirectoryHandle) {
    this.label = root.name;
  }

  private async dir(parts: string[]): Promise<DirectoryHandle> {
    let d = this.root;
    for (const p of parts) d = await d.getDirectoryHandle(p);
    return d;
  }

  private async file(path: string): Promise<File> {
    const parts = path.split("/");
    const name = parts.pop() ?? "";
    try {
      return await (await (await this.dir(parts)).getFileHandle(name)).getFile();
    } catch (e) {
      throw new SourceError(`${path} not found`, isNotFound(e));
    }
  }

  async read(path: string, maxBytes: number): Promise<Uint8Array> {
    const file = await this.file(path);
    if (file.size > maxBytes) throw new SourceError(`${path} is larger than ${maxBytes} bytes`);
    return new Uint8Array(await file.arrayBuffer());
  }

  async stream(path: string, maxBytes: number): Promise<ReadableStream<Uint8Array>> {
    return fileStream(await this.file(path), path, maxBytes);
  }

  private async names(parts: string[], kind: "file" | "directory"): Promise<string[]> {
    let d: DirectoryHandle;
    try {
      d = await this.dir(parts);
    } catch (e) {
      if (isNotFound(e)) return [];
      throw e;
    }
    const out: string[] = [];
    for await (const [name, h] of d.entries()) if (h.kind === kind) out.push(name);
    return out;
  }

  async listNotes(): Promise<string[]> {
    return sortedUnique((await this.names(["notes"], "directory")).filter(isLowercaseUUID));
  }

  async listRevisions(noteId: string): Promise<string[]> {
    return sortedUnique((await this.names(["notes", noteId], "file")).filter(isRevisionFile));
  }
}
