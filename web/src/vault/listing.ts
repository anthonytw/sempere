// Listing a vault fast (docs/web-viewer.md "Opening fast"): the published
// summaries (format.md §12) are shown at once, then checked against the
// vault's listing; only notes whose revision names differ from their entry
// are decrypted. With a `CachingSource` the revisions of those notes come
// from the browser cache when they were downloaded before.

import { type LoadedNote, type NoteSummary, loadNote, mapLimited, summarize } from "./library.ts";
import { CachingSource } from "./cache.ts";
import { SourceError, type VaultSource, readOptional } from "./source.ts";
import { type SummaryEntry, entryMatches, entrySummary, maxSummariesBytes, readSummaries, summariesFileName } from "./summaries.ts";
import { type UnlockedVault } from "./vault.ts";

export interface ListingProgress {
  /** Notes whose listing was checked. */
  checked: number;
  /** Notes in the vault (known once the note folders are listed). */
  total: number;
  /** Notes decrypted because they had no current entry. */
  read: number;
  /** Notes that need decrypting, found so far. */
  toRead: number;
}

export interface ListingCallbacks {
  /** The entries of the summaries file, before anything is checked (provisional rows). */
  provisional(rows: NoteSummary[]): void;
  /** A row that is now known to be current (from a matching entry or decrypted). */
  row(row: NoteSummary): void;
  /** A note the listing decrypted (before its `row`), for a caller that keeps decrypted notes. */
  loaded?(note: LoadedNote): void;
  /** A note the listing does not have (a provisional row to drop). */
  gone(id: string): void;
  progress(p: ListingProgress): void;
  /** False once the caller moved on (another vault, Lock): stop quietly. */
  current(): boolean;
}

export interface ListingResult {
  /** Why the summaries file was not used, if it existed and was not. */
  summariesProblem?: string;
  /** Entries used as they were. */
  fromSummaries: number;
  /** Notes decrypted. */
  read: number;
  /** Cached files dropped because the listing no longer has them. */
  evicted: number;
}

/** Reads the summaries file; an absent or unusable one gives no entries (a hint, format.md §12). */
export async function loadSummaries(source: VaultSource, vault: UnlockedVault): Promise<{ entries: Map<string, SummaryEntry>; problem?: string }> {
  let file: Uint8Array | undefined;
  try {
    file = await readOptional(source, summariesFileName, maxSummariesBytes);
  } catch (e) {
    return { entries: new Map(), problem: e instanceof Error ? e.message : String(e) };
  }
  if (!file) return { entries: new Map() };
  try {
    return { entries: await readSummaries(file, vault) };
  } catch (e) {
    return { entries: new Map(), problem: e instanceof Error ? e.message : String(e) };
  }
}

/** Lists every note: summaries first, then the listing, then the notes that changed. */
export async function listVault(source: VaultSource, vault: UnlockedVault, cb: ListingCallbacks,
  width = { list: 8, read: 4 }): Promise<ListingResult> {
  const { entries, problem } = await loadSummaries(source, vault);
  const result: ListingResult = { fromSummaries: 0, read: 0, evicted: 0 };
  if (problem !== undefined) result.summariesProblem = problem;
  if (!cb.current()) return result;
  if (entries.size > 0) cb.provisional([...entries].map(([id, e]) => entrySummary(id, e)));

  const ids = await source.listNotes();
  if (!cb.current()) return result;
  const listed = new Set(ids);
  for (const id of entries.keys()) if (!listed.has(id)) cb.gone(id);
  const progress: ListingProgress = { checked: 0, total: ids.length, read: 0, toRead: 0 };
  cb.progress({ ...progress });
  const listing = new Map<string, string[]>();
  const read = async (id: string, files: string[]) => {
    let row: NoteSummary, note: LoadedNote | undefined;
    try {
      note = await loadNote(source, vault, id, 6, files);
      row = summarize(note);
    } catch (e) {
      row = summarize({ id, error: e instanceof Error ? e.message : String(e), failures: [], revisionCount: files.length, hasAttachments: false });
    }
    if (!cb.current()) return;
    if (note) cb.loaded?.(note);
    progress.read++;
    result.read++;
    cb.row(row);
    cb.progress({ ...progress });
  };
  // Check listings and decrypt stale notes at the same time: a note is read as soon as it is found stale.
  let active = 0;
  const waiting: (() => void)[] = [];
  const acquire = async () => {
    if (active < width.read) {
      active++;
      return;
    }
    await new Promise<void>((r) => waiting.push(r));   // the releasing reader hands its slot over
  };
  const release = () => {
    const next = waiting.shift();
    if (next) next();
    else active--;
  };
  const pending: Promise<void>[] = [];
  await mapLimited(ids, width.list, async (id) => {
    if (!cb.current()) return;
    let files: string[];
    try {
      files = await source.listRevisions(id);
    } catch (e) {
      if (!(e instanceof SourceError)) throw e;
      cb.row(summarize({ id, error: e.message, failures: [], revisionCount: 0, hasAttachments: false }));
      return;
    }
    listing.set(id, files);
    progress.checked++;
    const entry = entries.get(id);
    if (entry && entryMatches(entry, files)) {
      result.fromSummaries++;
      cb.row(entrySummary(id, entry));
    } else {
      progress.toRead++;
      pending.push((async () => {
        await acquire();
        try {
          await read(id, files);
        } finally {
          release();
        }
      })());
    }
    cb.progress({ ...progress });
  });
  await Promise.all(pending);
  if (cb.current() && source instanceof CachingSource && listing.size === ids.length) {
    result.evicted = await source.retain(listing);
  }
  return result;
}
