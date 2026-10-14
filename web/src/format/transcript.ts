// Transcripts (format.md §8.3.2): a blob of UTF-8 JSON, checked like
// Swift's `Transcript.decode` (Sources/Sempere/Attachments.swift). An
// invalid transcript is treated like a blob that fails verification.

import { arr, fail, num, obj, optWith, reqWith, str, uuid } from "./json.ts";
import { parseRFC3339 } from "./rfc3339.ts";

export const transcriptFormat = "sempere-transcript/1";
/** Largest transcript content (§8.4). */
export const maxTranscriptBytes = 64 * 1024 * 1024;

export interface TranscriptWord {
  t: string;
  start: number;
  end: number;
  c?: number;
}

export interface TranscriptSegment {
  start: number;
  end: number;
  text: string;
  confidence?: number;
  language?: string;
  words?: TranscriptWord[];
}

export interface Transcript {
  recording: string;
  engine: string;
  language: string;
  created: number;
  segments: TranscriptSegment[];
}

function unit(v: number | undefined): boolean {
  return v === undefined || (v >= 0 && v <= 1);
}

/** Why the segments break §8.3.2, or undefined (Swift `validationError`). */
export function transcriptProblem(segments: TranscriptSegment[]): string | undefined {
  let lastEnd = -Infinity;
  for (const s of segments) {
    if (!(s.start >= 0 && s.start <= s.end)) return "segment with start after end";
    if (s.start < lastEnd) return "segments out of order or overlapping";
    if (!unit(s.confidence)) return "confidence outside 0...1";
    lastEnd = s.end;
    let lastWordEnd = -Infinity;
    for (const w of s.words ?? []) {
      if (!(w.start <= w.end && w.start >= s.start && w.end <= s.end)) return "word outside its segment";
      if (w.start < lastWordEnd) return "words out of order or overlapping";
      if (!unit(w.c)) return "word confidence outside 0...1";
      lastWordEnd = w.end;
    }
  }
  return undefined;
}

/**
 * Decodes transcript content for recording `recordingId`. Throws
 * `DecodeError` for anything §8.3.2 calls invalid, including a transcript
 * that names another recording.
 */
export function decodeTranscript(bytes: Uint8Array, recordingId: string): Transcript {
  if (bytes.length > maxTranscriptBytes) fail("$", "transcript larger than 64 MiB");
  let json: unknown;
  try {
    json = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    fail("$", "transcript is not UTF-8 JSON");
  }
  const o = obj(json, "$");
  if (reqWith(o, "format", "$", str) !== transcriptFormat) fail("$.format", "unknown transcript format");
  const created = parseRFC3339(reqWith(o, "created", "$", str));
  if (created === undefined) fail("$.created", "bad date");
  const t: Transcript = {
    recording: reqWith(o, "recording", "$", uuid),
    engine: reqWith(o, "engine", "$", str),
    language: reqWith(o, "language", "$", str),
    created,
    segments: reqWith(o, "segments", "$", (v, p) => arr(v, p).map((e, i) => {
      const q = `${p}[${i}]`;
      const so = obj(e, q);
      const seg: TranscriptSegment = {
        start: reqWith(so, "start", q, num), end: reqWith(so, "end", q, num), text: reqWith(so, "text", q, str),
      };
      const c = optWith(so, "confidence", q, num);
      if (c !== undefined) seg.confidence = c;
      const lang = optWith(so, "language", q, str);
      if (lang !== undefined) seg.language = lang;
      const words = optWith(so, "words", q, (w, wp) => arr(w, wp).map((x, j) => {
        const r = `${wp}[${j}]`;
        const wo = obj(x, r);
        const word: TranscriptWord = { t: reqWith(wo, "t", r, str), start: reqWith(wo, "start", r, num), end: reqWith(wo, "end", r, num) };
        const wc = optWith(wo, "c", r, num);
        if (wc !== undefined) word.c = wc;
        return word;
      }));
      if (words !== undefined) seg.words = words;
      return seg;
    })),
  };
  const why = transcriptProblem(t.segments);
  if (why) fail("$.segments", why);
  if (t.recording !== recordingId) fail("$.recording", "the transcript belongs to another recording");
  return t;
}
