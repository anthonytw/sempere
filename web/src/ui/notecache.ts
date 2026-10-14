// The decrypted notes the viewer keeps in this tab's memory, so that opening a note again (or one the
// listing just decrypted) does not decrypt its revisions again. Bounded; least recently used first.
// Only notes read in full are kept: a note that could not be opened, or one with revisions that could
// not be read (often a network error), is read again the next time it is opened.

import { type LoadedNote } from "../vault/library.ts";

export class NoteCache {
  /** In recency order: the least recently used first. */
  private readonly notes = new Map<string, LoadedNote>();
  /** Notes put in by the listing and not opened since: they go before any opened note. */
  private readonly listed = new Set<string>();

  constructor(readonly capacity = 8) {}

  get size(): number {
    return this.notes.size;
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
    if (!complete(note)) {
      this.drop(id);
      return;
    }
    this.notes.delete(id);
    this.notes.set(id, note);
    this.listed.delete(id);
    while (this.notes.size > this.capacity) this.drop(this.notes.keys().next().value ?? "");
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
    if (this.notes.has(note.id)) {
      if (this.listed.has(note.id)) this.notes.set(note.id, note);
      return;
    }
    if (this.notes.size >= this.capacity) {
      let oldest: LoadedNote | undefined;
      for (const id of this.listed) {
        const n = this.notes.get(id);
        if (n && (!oldest || (n.modified ?? -Infinity) < (oldest.modified ?? -Infinity))) oldest = n;
      }
      if (!oldest || (oldest.modified ?? -Infinity) >= (note.modified ?? -Infinity)) return;
      this.drop(oldest.id);
    }
    // First in the map: the next to go.
    const rest = [...this.notes];
    this.notes.clear();
    this.notes.set(note.id, note);
    for (const [id, n] of rest) this.notes.set(id, n);
    this.listed.add(note.id);
  }

  clear(): void {
    this.notes.clear();
    this.listed.clear();
  }

  private drop(id: string): void {
    this.notes.delete(id);
    this.listed.delete(id);
  }
}

/** Whether every revision of `note` was read. */
function complete(note: LoadedNote): boolean {
  return note.error === undefined && note.failures.length === 0;
}
