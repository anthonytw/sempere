// Reading a note's recording transcripts (format.md §8.3.2) for the search:
// each from its verified blob, checked like Swift's `Transcript.decode`, and
// bound to its recording. A transcript that cannot be read is reported with
// its reason, never searched (the CLI's `search --transcripts` warns and exits 1).

import { type NoteState } from "../format/model.ts";
import { type TranscriptRead } from "../format/phrasesearch.ts";
import { decodeTranscript, maxTranscriptBytes } from "../format/transcript.ts";
import { type BlobRef, BlobError, asBlobRef } from "./blobs.ts";

export type BlobReader = (ref: BlobRef, maxBytes: number) => Promise<Blob>;

function reason(e: unknown): string {
  if (e instanceof BlobError && e.code === "missing") return "the transcript file is missing from the vault";
  return e instanceof Error ? e.message : String(e);
}

/** The transcripts of every recording of `state` that has one, in the note's order. */
export async function readTranscripts(state: NoteState, read: BlobReader): Promise<TranscriptRead[]> {
  const out: TranscriptRead[] = [];
  for (const recording of state.recordings) {
    const ref = asBlobRef(recording.transcript);
    if (!ref) continue;
    try {
      const bytes = new Uint8Array(await (await read(ref, maxTranscriptBytes)).arrayBuffer());
      out.push({ recording, transcript: decodeTranscript(bytes, String(recording.id).toLowerCase()) });
    } catch (e) {
      out.push({ recording, error: reason(e) });
    }
  }
  return out;
}
