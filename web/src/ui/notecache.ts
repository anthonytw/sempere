// The decrypted notes the viewer keeps in this tab's memory, so that opening a note again (or one the
// listing just decrypted) does not decrypt its revisions again. Bounded; least recently used first.
// Only notes read in full are kept: a note that could not be opened, or one with revisions that could
// not be read (often a network error), is read again the next time it is opened.

import { type LoadedNote } from "../vault/library.ts";
import { type NoteState } from "../format/model.ts";

/** Most estimated bytes the cache holds (a handwritten note's points dominate: 72 bytes each). */
export const defaultMaxBytes = 128 << 20;

const word = 8;
const object = 48;

function jsonBytes(value: unknown, depth = 0): number {
  if (typeof value === "string") return value.length * 2 + 16;
  if (typeof value !== "object" || value === null) return word;
  if (depth > 32) return object;
  if (Array.isArray(value)) return value.reduce<number>((n, v) => n + jsonBytes(v, depth + 1), object);
  let n = object;
  for (const [k, v] of Object.entries(value)) n += k.length * 2 + jsonBytes(v, depth + 1);
  return n;
}

function stateBytes(s: NoteState): number {
  let n = jsonBytes(s.meta) + jsonBytes(s.tagSet) + jsonBytes(s.recordings) + jsonBytes(s.clocks ?? {}) + jsonBytes(s.tombstones ?? {});
  for (const page of s.pages) {
    n += 256 + page.id.length * 2;
    for (const stroke of page.strokes) n += 256 + stroke.points.byteLength;
    n += jsonBytes(page.items);
    if (page.recognition) n += jsonBytes(page.recognition);
    if (page.paper) n += jsonBytes(page.paper);
  }
  return n;
}

/** About how many bytes of memory `note` holds (an estimate: the points of its strokes, its items and texts). */
export function estimateBytes(note: LoadedNote): number {
  return 512 + (note.state ? stateBytes(note.state) : 0) + jsonBytes(note.failures) + (note.newer ? jsonBytes(note.newer) : 0);
}

export class NoteCache {
  /** In recency order: the least recently used first. */
  private readonly notes = new Map<string, LoadedNote>();
  /** Notes put in by the listing and not opened since: they go before any opened note. */
  private readonly listed = new Set<string>();

  /** The estimated size of each kept note. */
  private readonly costs = new Map<string, number>();
  private held = 0;

  constructor(readonly capacity = 8, readonly maxBytes = defaultMaxBytes) {}

  get size(): number {
    return this.notes.size;
  }

  /** The estimated bytes of the notes kept. */
  get bytes(): number {
    return this.held;
  }

  /** The note, now the most recently used one. */
  get(id: string): LoadedNote | undefined {
    const note = this.notes.get(id);
    if (!note) return undefined;
    this.notes.delete(id);
    this.notes.set(id, note);
    this.listed.delete(id);
    return note;
  }

  /** Keeps a note that was opened, as the most recently used one (a failed one: forgets the note). */
  set(id: string, note: LoadedNote): void {
    const cost = complete(note) ? estimateBytes(note) : Infinity;
    // A note over the whole budget is never kept: it would push out everything else and still not fit.
    if (cost > this.maxBytes) {
      this.drop(id);
      return;
    }
    this.drop(id);
    this.notes.set(id, note);
    this.costs.set(id, cost);
    this.held += cost;
    this.listed.delete(id);
    while (this.notes.size > this.capacity || this.held > this.maxBytes) {
      const oldest = this.notes.keys().next().value;
      if (oldest === undefined || oldest === id) break;
      this.drop(oldest);
    }
  }

  /**
   * Keeps a note the listing decrypted (it is likely to be opened next: it just changed), behind
   * every opened note. When the cache is full it only replaces a listed note modified earlier.
   */
  offer(note: LoadedNote): void {
    if (!complete(note)) {
      if (this.listed.has(note.id)) this.drop(note.id);
      return;
    }
    const cost = estimateBytes(note);
    if (cost > this.maxBytes) {
      if (this.listed.has(note.id)) this.drop(note.id);
      return;
    }
    if (this.notes.has(note.id)) {
      if (this.listed.has(note.id)) {
        this.held += cost - (this.costs.get(note.id) ?? 0);
        this.notes.set(note.id, note);
        this.costs.set(note.id, cost);
      }
      return;
    }
    // Room is made from listed notes modified earlier than this one, the oldest first; if they do not
    // free enough (an opened note is never pushed out by a listed one), nothing changes.
    const victims: string[] = [];
    let count = this.notes.size;
    let bytes = this.held;
    if (count >= this.capacity || bytes + cost > this.maxBytes) {
      const candidates = [...this.listed]
        .map((id) => this.notes.get(id))
        .filter((n): n is LoadedNote => n !== undefined)
        .sort((x, y) => (x.modified ?? -Infinity) - (y.modified ?? -Infinity));
      for (const candidate of candidates) {
        if (count < this.capacity && bytes + cost <= this.maxBytes) break;
        if ((candidate.modified ?? -Infinity) >= (note.modified ?? -Infinity)) return;
        victims.push(candidate.id);
        count -= 1;
        bytes -= this.costs.get(candidate.id) ?? 0;
      }
      if (count >= this.capacity || bytes + cost > this.maxBytes) return;
    }
    for (const id of victims) this.drop(id);
    // First in the map: the next to go.
    const rest = [...this.notes];
    this.notes.clear();
    this.notes.set(note.id, note);
    for (const [id, n] of rest) this.notes.set(id, n);
    this.costs.set(note.id, cost);
    this.held += cost;
    this.listed.add(note.id);
  }

  clear(): void {
    this.notes.clear();
    this.listed.clear();
    this.costs.clear();
    this.held = 0;
  }

  private drop(id: string): void {
    this.notes.delete(id);
    this.listed.delete(id);
    this.held -= this.costs.get(id) ?? 0;
    this.costs.delete(id);
  }
}

/** Whether every revision of `note` was read. */
function complete(note: LoadedNote): boolean {
  return note.error === undefined && note.failures.length === 0;
}
