// Loading notes from a source: list, read and decrypt every revision, merge,
// and summarise for the note list and search. Unreadable revisions are
// reported with the note (format.md §4), never silently dropped.

import { type NoteState, type Revision } from "../format/model.ts";
import { type NewerContent, emptyNewer, mergeNewer } from "../format/newer.ts";
import { type JSONObject } from "../format/json.ts";
import { itemLatex, itemText } from "../format/registers.ts";
import { type PageTextEntry, type TextSpan } from "../format/search.ts";
import { NoteLogError, reconstruct } from "../format/reducer.ts";
import { type UnlockedVault, RevisionReadError, limits } from "./vault.ts";
import { SourceError, type VaultSource } from "./source.ts";

export interface RevisionFailure {
  file: string;
  message: string;
}

export interface LoadedNote {
  id: string;
  /** Undefined when nothing could be read or the revisions conflict. */
  state?: NoteState;
  /** Why `state` is missing. */
  error?: string;
  failures: RevisionFailure[];
  revisionCount: number;
  /** Newest `wall` of a readable revision (Unix ms). */
  modified?: number;
  /** The note holds items or recordings (format.md §8). */
  hasAttachments: boolean;
  /** What a newer version wrote and what could not be shown (format.md §7.4). */
  newer?: NewerContent;
}

export interface NoteSummary {
  id: string;
  title: string;
  tags: string[];
  notebook?: string;
  favorite: boolean;
  deleted: boolean;
  created: number;
  modified?: number;
  pageCount: number;
  /** Recognised text per page (1-based page numbers), for search. */
  pageTexts: PageTextEntry[];
  failures: number;
  error?: string;
  hasAttachments: boolean;
  /** The note holds content a newer version wrote (format.md §7.4). */
  newer: boolean;
}

function holdsAttachments(r: Revision): boolean {
  if (r.body.type === "delta") {
    return r.body.ops.some((o) => ["addItem", "removeItem", "setItem", "addRecording", "removeRecording", "setRecording"].includes(o.op));
  }
  const s = r.body.state;
  return s.recordings.length > 0 || s.pages.some((p) => p.items.length > 0)
    || (s.tombstones?.items.length ?? 0) > 0 || (s.tombstones?.recordings.length ?? 0) > 0;
}

/** Runs `f` over `items` with at most `width` in flight, keeping order. */
export async function mapLimited<T, R>(items: T[], width: number, f: (t: T, i: number) => Promise<R>): Promise<R[]> {
  const out = new Array<R>(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      out[i] = await f(items[i] as T, i);
    }
  };
  await Promise.all(Array.from({ length: Math.min(width, items.length) }, worker));
  return out;
}

function message(e: unknown): string {
  if (e instanceof RevisionReadError) return `${e.code}: ${e.message}`;
  return e instanceof Error ? e.message : String(e);
}

/** Reads and merges every revision of one note (`files`: its listing, when already known). */
export async function loadNote(source: VaultSource, vault: UnlockedVault, id: string, width = 6, listed?: string[]): Promise<LoadedNote> {
  const files = listed ?? await source.listRevisions(id);
  const failures: RevisionFailure[] = [];
  const newer = emptyNewer();
  const revs = await mapLimited(files, width, async (file) => {
    const path = `notes/${id}/${file}`;
    try {
      try {
        return await vault.readRevision(id, file, await source.read(path, limits.revisionBytes));
      } catch (e) {
        // A cached copy that fails is dropped and downloaded once more.
        if (!(e instanceof RevisionReadError) || !source.evict || !(await source.evict(path))) throw e;
        return await vault.readRevision(id, file, await source.read(path, limits.revisionBytes));
      }
    } catch (e) {
      if (e instanceof RevisionReadError && e.code === "newer") newer.unreadable++;
      if (e instanceof SourceError || e instanceof RevisionReadError) {
        failures.push({ file, message: message(e) });
        return undefined;
      }
      throw e;
    }
  });
  const readable = revs.filter((r): r is Revision => r !== undefined);
  failures.sort((a, b) => (a.file < b.file ? -1 : 1));
  const note: LoadedNote = {
    id, failures, revisionCount: files.length, hasAttachments: readable.some(holdsAttachments),
  };
  for (const r of readable) if (r.newer) mergeNewer(newer, r.newer);
  if (newer.revisions > 0 || newer.unreadable > 0) note.newer = newer;
  if (readable.length > 0) note.modified = Math.max(...readable.map((r) => r.wall));
  if (readable.length === 0) {
    note.error = files.length === 0 ? "the note has no revisions" : "no revision of the note could be read";
    return note;
  }
  try {
    note.state = reconstruct(readable);
  } catch (e) {
    if (!(e instanceof NoteLogError)) throw e;
    note.error = e.message;
  }
  return note;
}

/** A `pdfPage` item's stored page text (§8.2.6); "" when absent or malformed (Swift `Item.pageText`). */
export function pdfPageText(item: JSONObject): string {
  const v = item.pageText;
  if (v === null || typeof v !== "object" || Array.isArray(v)) return "";
  const t = (v as JSONObject).text;
  return typeof t === "string" && new TextEncoder().encode(t).length <= 65_536 ? t : "";
}

export function summarize(n: LoadedNote): NoteSummary {
  const s = n.state;
  const out: NoteSummary = {
    id: n.id, title: s?.meta.title ?? "", tags: s?.meta.tags ?? [], favorite: s?.meta.favorite ?? false,
    deleted: s?.deleted ?? false, created: s?.meta.created ?? 0, pageCount: s?.pages.length ?? 0,
    pageTexts: (s?.pages ?? []).flatMap((p, i) => {
      // Recognised handwriting, then each text box, PDF page text and equation source in drawing order
      // (Swift `PageText.texts`).
      // `spans` say which part is which (UTF-16 offsets, as Swift's), so a snippet leaves equations out.
      const parts = [{ text: p.recognition?.text ?? "", isMath: false },
        ...p.items.map((it) => it.kind === "math" ? { text: itemLatex(it), isMath: true }
          : { text: it.kind === "text" ? itemText(it) : it.kind === "pdfPage" ? pdfPageText(it) : "", isMath: false })]
        .filter((t) => t.text.length > 0);
      const spans: TextSpan[] = [];
      let offset = 0;
      for (const part of parts) {
        spans.push({ start: offset, end: offset + part.text.length, isMath: part.isMath });
        offset += part.text.length + 1;   // the joining newline
      }
      return parts.length > 0 ? [{ number: i + 1, text: parts.map((t) => t.text).join("\n"), spans }] : [];
    }),
    failures: n.failures.length, hasAttachments: n.hasAttachments, newer: n.newer !== undefined,
  };
  if (s?.meta.notebook !== undefined) out.notebook = s.meta.notebook;
  if (n.modified !== undefined) out.modified = n.modified;
  if (n.error !== undefined) out.error = n.error;
  return out;
}
