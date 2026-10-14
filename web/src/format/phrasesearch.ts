// Every occurrence of a phrase in a note: a port of the CLI's `sempere search
// [--transcripts]` (Sources/SempereCLI/Search.swift). It reads each page's
// recognised handwriting, PDF page text, equation sources and text boxes, and
// (when given) the note's recording transcripts, and returns the CLI's JSON
// hits, which test/phrasesearch.test.ts compares with the CLI's output for the
// fixture vaults. The viewer uses the transcript hits for its transcript search.

import { type JSONObject, isObject } from "./json.ts";
import { type NoteState } from "./model.ts";
import { type FoldedTerm, foldTerm, occurrences, prepare, rangeOf, snippet, swiftCompare } from "./occurrences.ts";
import { itemLatex, itemText } from "./registers.ts";
import { type Transcript } from "./transcript.ts";

/** One hit, field for field the CLI's `SearchHit` JSON (absent fields are omitted, as Swift does). */
export interface PhraseHit {
  noteId: string;
  title: string;
  notebook?: string;
  /** 1-based; absent for a transcript hit. */
  page?: number;
  pageId?: string;
  snippet: string;
  matches: number;
  source: "handwriting" | "text" | "math" | "pdf" | "transcript";
  engine?: string;
  words: { text: string; box: number[] }[];
  itemId?: string;
  box?: number[];
  recordingId?: string;
  recordingTitle?: string;
  /** Seconds (transcript hits). */
  start?: number;
  end?: number;
  /** 1-based page of the PDF (pdf hits). */
  pdfPage?: number;
}

/** A recording's transcript as read for the search: decoded, or why it could not be. */
export interface TranscriptRead {
  recording: JSONObject;
  transcript?: Transcript;
  error?: string;
}

/** The term prepared once for many texts. */
export interface PhraseQuery {
  readonly folded: FoldedTerm;
  /** The term's words, for the handwriting hits' `words` (Swift splits on white space). */
  readonly tokens: FoldedTerm[];
}

/** Undefined for a term that is empty once trimmed (the CLI refuses it). */
export function phraseQuery(trimmed: string): PhraseQuery | undefined {
  if (trimmed.length === 0) return undefined;
  return { folded: foldTerm(trimmed), tokens: trimmed.split(/[\p{White_Space}]+/u).filter((w) => w.length > 0).map(foldTerm) };
}

function find(text: string, q: PhraseQuery): { snippet: string; matches: number } | undefined {
  const t = prepare(text);
  const found = occurrences(t, q.folded);
  const first = found[0];
  return first ? { snippet: snippet(t, first), matches: found.length } : undefined;
}

function frame(item: JSONObject): number[] | undefined {
  const f = item.frame;
  return Array.isArray(f) && f.length === 4 && f.every((n) => typeof n === "number") ? f : undefined;
}

/** A `pdfPage` item's stored text and engine (Swift `PDFPageText(json:)`); undefined when absent or malformed. */
function pageText(item: JSONObject): { text: string; engine: string } | undefined {
  const v = item.pageText;
  if (!isObject(v) || typeof v.text !== "string" || new TextEncoder().encode(v.text).length > 65_536) return undefined;
  return { text: v.text, engine: typeof v.engine === "string" ? v.engine : "" };
}

function recordingTitle(rec: JSONObject): string | undefined {
  return typeof rec.title === "string" ? rec.title : undefined;
}

/** The hits of one recording's transcript. */
export function transcriptHits(noteId: string, title: string, notebook: string | undefined, rec: JSONObject,
  transcript: Transcript, q: PhraseQuery): PhraseHit[] {
  const out: PhraseHit[] = [];
  for (const seg of transcript.segments) {
    const f = find(seg.text, q);
    if (!f) continue;
    const hit: PhraseHit = { noteId, title, snippet: f.snippet, matches: f.matches, source: "transcript",
      engine: transcript.engine, words: [], recordingId: String(rec.id).toLowerCase(), start: seg.start, end: seg.end };
    if (notebook !== undefined) hit.notebook = notebook;
    const rt = recordingTitle(rec);
    if (rt !== undefined) hit.recordingTitle = rt;
    out.push(hit);
  }
  return out;
}

/**
 * The hits of one note (not deleted: the caller skips those), in the CLI's
 * order of discovery; `transcripts` adds each readable transcript's hits.
 */
export function noteHits(noteId: string, state: NoteState, q: PhraseQuery, transcripts?: TranscriptRead[]): PhraseHit[] {
  const out: PhraseHit[] = [];
  const title = state.meta.title;
  const notebook = state.meta.notebook;
  const base = (page: number, pageId: string) => {
    const h = { noteId, title, page, pageId } as PhraseHit;
    if (notebook !== undefined) h.notebook = notebook;
    return h;
  };
  state.pages.forEach((page, index) => {
    const rec = page.recognition;
    if (rec) {
      const f = find(rec.text, q);
      if (f) {
        const words = rec.words.filter((w) => {
          const t = prepare(w.t);
          return q.tokens.some((tok) => rangeOf(t, tok) !== undefined);
        });
        out.push({ ...base(index + 1, page.id), snippet: f.snippet, matches: f.matches, source: "handwriting",
          engine: rec.engine, words: words.map((w) => ({ text: w.t, box: [...w.box] })) });
      }
    }
    const items = page.items;
    for (const item of items) {
      if (item.kind !== "pdfPage") continue;
      const pt = pageText(item);
      const f = pt ? find(pt.text, q) : undefined;
      if (!pt || !f) continue;
      const hit: PhraseHit = { ...base(index + 1, page.id), snippet: f.snippet, matches: f.matches, source: "pdf",
        engine: pt.engine, words: [], itemId: String(item.id).toLowerCase() };
      const box = frame(item);
      if (box) hit.box = box;
      if (typeof item.pageIndex === "number") hit.pdfPage = item.pageIndex + 1;
      out.push(hit);
    }
    for (const [kind, source, text] of [["math", "math", itemLatex], ["text", "text", itemText]] as const) {
      for (const item of items) {
        if (item.kind !== kind) continue;
        const f = find(text(item), q);
        if (!f) continue;
        const hit: PhraseHit = { ...base(index + 1, page.id), snippet: f.snippet, matches: f.matches, source, words: [],
          itemId: String(item.id).toLowerCase() };
        const box = frame(item);
        if (box) hit.box = box;
        out.push(hit);
      }
    }
  });
  for (const t of transcripts ?? []) {
    if (t.transcript) out.push(...transcriptHits(noteId, title, notebook, t.recording, t.transcript, q));
  }
  return out;
}

/** The CLI's order: title (lowercased), note, page (transcripts last), time, source. */
export function sortHits(hits: PhraseHit[]): PhraseHit[] {
  const key = (h: PhraseHit) => h.title.toLowerCase();
  return hits.map((h, i) => ({ h, i })).sort((a, b) =>
    swiftCompare(key(a.h), key(b.h)) || swiftCompare(a.h.noteId, b.h.noteId)
    || (a.h.page ?? Number.MAX_SAFE_INTEGER) - (b.h.page ?? Number.MAX_SAFE_INTEGER)
    || (a.h.start ?? 0) - (b.h.start ?? 0) || swiftCompare(a.h.source, b.h.source) || a.i - b.i).map((x) => x.h);
}
