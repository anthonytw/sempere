// Test builders for revisions, ops, strokes and pages: a port of the helpers in
// Tests/SempereTests/TestSupport.swift (LogBuilder, stroke, SplitMix64) plus
// the writer-side pieces the Swift merge tests lean on (SnapshotBuilder,
// HybridClock, NoteOps tag helpers, a compaction rule), which the viewer has
// no need for. Synthetic data only.

import {
  Included, type Origin, type Stamp, cmpName, entryCovers, originOf, zeroDevice, zeroHLC,
} from "../src/format/ids.ts";
import {
  type MetaChange, type NoteState, type Op, type Page, type PageSize, type Paper, type Recognition, type Revision,
  type Stroke, type TagSet, defaultPaper, pointStride, revisionName,
} from "../src/format/model.ts";
import { canonical, resolve } from "../src/format/reducer.ts";
import { normalizedTag, tagKey } from "../src/format/tags.ts";

export const devA = "aaaaaaaa";
export const devB = "bbbbbbbb";
export const devC = "cccccccc";
export const testNote = "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c";
export const baseMillis = 1_759_632_000_000;
export const p1 = "00000000-0000-4000-8000-0000000000a1";
export const p2 = "00000000-0000-4000-8000-0000000000a2";

export const letter: PageSize = { width: 612, height: 792, infinite: false };
export const a4: PageSize = { width: 595, height: 842, infinite: false };

/** Deterministic RNG (SplitMix64, as the Swift tests use). */
export class SplitMix64 {
  private state: bigint;

  constructor(seed: number | bigint) {
    this.state = BigInt.asUintN(64, BigInt(seed));
  }

  next(): bigint {
    const mask = (1n << 64n) - 1n;
    this.state = (this.state + 0x9e3779b97f4a7c15n) & mask;
    let z = this.state;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & mask;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & mask;
    return z ^ (z >> 31n);
  }

  /** Uniform in [0, 1). */
  float(): number {
    return Number(this.next() >> 11n) / 2 ** 53;
  }

  /** Uniform integer in [lo, hi). */
  int(lo: number, hi: number): number {
    return lo + Math.floor(this.float() * (hi - lo));
  }

  bool(): boolean {
    return (this.next() & 1n) === 1n;
  }

  pick<T>(xs: readonly T[]): T {
    const x = xs[this.int(0, xs.length)];
    if (x === undefined) throw new Error("pick from an empty array");
    return x;
  }

  shuffled<T>(xs: readonly T[]): T[] {
    const out = [...xs];
    for (let i = out.length - 1; i > 0; i--) {
      const j = this.int(0, i + 1);
      const t = out[i] as T;
      out[i] = out[j] as T;
      out[j] = t;
    }
    return out;
  }

  uuid(): string {
    const hex = (this.next().toString(16).padStart(16, "0") + this.next().toString(16).padStart(16, "0")).split("");
    hex[12] = "4";
    hex[16] = "89ab"[parseInt(hex[16] ?? "0", 16) & 3] ?? "8";
    const h = hex.join("");
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
  }
}

let uuidCounter = 0;

/** A fresh lowercase UUID, unique within the test run (Swift's `UUID()`). */
export function newUUID(): string {
  uuidCounter += 1;
  return `00000000-0000-4000-8000-${uuidCounter.toString(16).padStart(12, "0")}`;
}

/** `HLC(millis:counter:)` as its 17-digit string. */
export function hlcString(millis: number, counter = 0): string {
  return String(millis).padStart(13, "0") + String(counter).padStart(4, "0");
}

export function hlcMillis(hlc: string): number {
  return Number(hlc.slice(0, 13));
}

/** Swift `HybridClock`, for the HLCs a snapshot writer would issue (no saturation at the top). */
export class HybridClock {
  constructor(public millis = 0, public counter = 0) {}

  get current(): string {
    return hlcString(this.millis, this.counter);
  }

  private bump(next: number): void {
    if (next <= 9999) {
      this.counter = next;
    } else {
      this.millis += 1;
      this.counter = 0;
    }
  }

  tick(wall: number): string {
    if (wall > this.millis) {
      this.millis = wall;
      this.counter = 0;
    } else {
      this.bump(this.counter + 1);
    }
    return this.current;
  }

  observe(remote: string, wall: number): string {
    const rm = hlcMillis(remote), rc = Number(remote.slice(13));
    if (rm > wall + 24 * 60 * 60 * 1000) return this.current;
    const m = Math.max(wall, this.millis, rm);
    if (m === this.millis && m === rm) this.bump(Math.max(this.counter, rc) + 1);
    else if (m === this.millis) this.bump(this.counter + 1);
    else if (m === rm) {
      this.millis = m;
      this.bump(rc + 1);
    } else {
      this.millis = m;
      this.counter = 0;
    }
    return this.current;
  }
}

/** A one-point pen stroke, as Swift's test `stroke(_:parent:)`. */
export function stroke(id: string = newUUID(), parent?: string): Stroke {
  const points = new Float64Array(pointStride);
  // StrokePoint(x: 1, y: 2, w: 2, h: 2) with its defaults t 0, o 1, f 0, az 0, al π/2.
  points.set([1, 2, 0, 2, 2, 1, 0, 0, Math.PI / 2]);
  const s: Stroke = { id, ink: { tool: "pen", color: "#000000FF", width: 2 }, points };
  if (parent !== undefined) s.parent = parent;
  return s;
}

/** A page as an `addPage` op carries it. */
export function page(id: string, order: string): Page {
  return { id, order, strokes: [], items: [] };
}

export function recognition(text: string, words = true): Recognition {
  return { engine: "test-1", text, words: words ? [{ t: text, box: [1, 2, 3, 4] }] : [] };
}

export const op = {
  addPage: (id: string, order: string): Op => ({ op: "addPage", page: page(id, order) }),
  addStroke: (pageId: string, s: Stroke): Op => ({ op: "addStroke", page: pageId, stroke: s }),
  removeStroke: (pageId: string, strokeId: string): Op => ({ op: "removeStroke", page: pageId, strokeId }),
  removePage: (pageId: string): Op => ({ op: "removePage", pageId }),
  setPageOrder: (pageId: string, order: string): Op => ({ op: "setPageOrder", pageId, order }),
  setPageRecognition: (pageId: string, r: Recognition | undefined): Op =>
    ({ op: "setPageRecognition", pageId, recognition: r }),
  setPagePaper: (pageId: string, paper: Paper | undefined): Op => ({ op: "setPagePaper", pageId, paper }),
  setMeta: (change: MetaChange): Op => ({ op: "setMeta", change }),
  title: (value: string): Op => ({ op: "setMeta", change: { field: "title", value } }),
  notebook: (value: string | undefined): Op => ({ op: "setMeta", change: { field: "notebook", value } }),
  favorite: (value: boolean): Op => ({ op: "setMeta", change: { field: "favorite", value } }),
  paper: (value: Paper): Op => ({ op: "setMeta", change: { field: "paper", value } }),
  pageSize: (value: PageSize): Op => ({ op: "setMeta", change: { field: "pageSize", value } }),
  addTag: (tag: string): Op => ({ op: "addTag", tag }),
  removeTag: (tag: string, observed: Origin[]): Op => ({ op: "removeTag", tag, observed }),
  deleteNote: (): Op => ({ op: "deleteNote" }),
  restoreNote: (): Op => ({ op: "restoreNote" }),
};

export function delta(device: string, seq: number, hlc: string, wall: number, ops: Op[], noteId = testNote): Revision {
  return { noteId, device, seq, hlc, wall, app: "test/0", body: { type: "delta", ops } };
}

function cloneIncluded(i: Included): Included {
  return new Included().union(i);
}

/**
 * Swift `SnapshotBuilder.makeSnapshot`: the resolution of `revisions`, its
 * `included` plus the snapshot itself, stamped by `clock` after it observed
 * every input.
 */
export function makeSnapshot(revisions: Revision[], device: string, seq: number, clock: HybridClock,
  wall: number): Revision {
  const revs = canonical(revisions);
  const res = resolve(revs);
  for (const r of revs) clock.observe(r.hlc, wall);
  const included = cloneIncluded(res.included);
  included.insert(device, seq);
  const hlc = clock.tick(wall);
  const first = revs[0];
  if (!first) throw new Error("no revisions");
  return {
    noteId: first.noteId, device, seq, hlc, wall, app: "test/0",
    body: { type: "snapshot", included, state: structuredClone(res.state) },
  };
}

/** Hand-cranked log: explicit HLC millis per revision, auto `seq` per device (Swift `LogBuilder`). */
export class LogBuilder {
  seqs = new Map<string, number>();

  nextSeq(d: string): number {
    const s = (this.seqs.get(d) ?? 0) + 1;
    this.seqs.set(d, s);
    return s;
  }

  /** A delta stamped at `baseMillis + t` (counter 0). */
  delta(d: string, t: number, ops: Op[]): Revision {
    const ms = baseMillis + t;
    return delta(d, this.nextSeq(d), hlcString(ms), ms, ops);
  }

  /** A snapshot by `d` at `baseMillis + t` from `revisions`, with a fresh clock. */
  snapshot(d: string, t: number, from: Revision[]): Revision {
    return makeSnapshot(from, d, this.nextSeq(d), new HybridClock(), baseMillis + t);
  }

  /** A copy (Swift's `var copy = log`). */
  copy(): LogBuilder {
    const l = new LogBuilder();
    l.seqs = new Map(this.seqs);
    return l;
  }
}

export function snapshotParts(r: Revision): { included: Included; state: NoteState } {
  if (r.body.type !== "snapshot") throw new Error("not a snapshot");
  return r.body;
}

export function deltaOps(r: Revision): Op[] {
  if (r.body.type !== "delta") throw new Error("not a delta");
  return r.body.ops;
}

/** The same revision with its state replaced (Swift `rev.body = .snapshot(...)`). */
export function withState(r: Revision, state: NoteState): Revision {
  const { included } = snapshotParts(r);
  return { ...r, body: { type: "snapshot", included: cloneIncluded(included), state } };
}

export function stampOf(r: Revision): Stamp {
  return { hlc: r.hlc, device: r.device };
}

export const zeroStampValue: Stamp = { hlc: zeroHLC, device: zeroDevice };

/** The origin of op `index` in `r`: what a remover of a tag instance observes. */
export function instance(r: Revision, index = 0): Origin {
  return originOf(revisionName(r), index);
}

/** A note state with nothing in it (Swift `NoteState(meta: NoteMeta(created:))`). */
export function emptyState(created: number, pages: Page[] = []): NoteState {
  return {
    deleted: false,
    meta: { title: "", tags: [], favorite: false, created, paper: defaultPaper("blank"), pageSize: { ...letter } },
    pages, recordings: [], tagSet: { instances: [], removed: [] },
  };
}

/**
 * Swift `NoteReducer.apply(_:to:stamp:)`: `state` acts as a snapshot named
 * `(stamp, seq 0)` that covers nothing. (Its wall is the state's `created`,
 * so `created` may differ from Swift's when a delta is older; no test asserts it.)
 */
export function applyDeltas(deltas: Revision[], state: NoteState, stamp: Stamp): NoteState {
  for (const d of deltas) if (d.body.type !== "delta") throw new Error("not a delta");
  const revs = canonical(deltas);
  const base: Revision = {
    noteId: revs[0]?.noteId ?? testNote, device: stamp.device, seq: 0, hlc: stamp.hlc, wall: state.meta.created,
    app: "apply", body: { type: "snapshot", included: new Included(), state: structuredClone(state) },
  };
  return resolve([base, ...revs]).state;
}

export function strokeIds(s: NoteState): string[][] {
  return s.pages.map((p) => p.strokes.map((x) => x.id));
}

/** Every stroke id, sorted (a set). */
export function allStrokeIds(s: NoteState): string[] {
  return [...new Set(s.pages.flatMap((p) => p.strokes.map((x) => x.id)))].sort();
}

// MARK: - Tag writers (Swift `NoteOps`)

export function instancesOf(set: TagSet | undefined, tag: string): Origin[] {
  const key = tagKey(tag);
  return (set?.instances ?? []).filter((i) => tagKey(i.tag) === key).map((i) => i.origin);
}

export function normalizedTags(tags: string[]): string[] {
  const seen = new Set<string>();
  return tags.map(normalizedTag).filter((t) => {
    if (t.length === 0 || seen.has(t.toLowerCase())) return false;
    seen.add(t.toLowerCase());
    return true;
  });
}

/** `NoteOps.addTag(_:to:)`. */
export function addTagOp(tag: string, state: NoteState): Op | undefined {
  const t = normalizedTag(tag);
  if (t.length === 0 || state.meta.tags.some((x) => tagKey(x) === tagKey(t))) return undefined;
  return op.addTag(t);
}

/** `NoteOps.removeTag(_:from:)`: observes every live instance of the key. */
export function removeTagOp(tag: string, state: NoteState): Op | undefined {
  const observed = instancesOf(state.tagSet, tag);
  return observed.length === 0 ? undefined : op.removeTag(normalizedTag(tag), observed);
}

/** `NoteOps.setTags(_:on:)`. */
export function setTagsOps(tags: string[], state: NoteState): Op[] {
  const want = normalizedTags(tags), have = state.meta.tags;
  const spelling = (xs: string[]) => {
    const m = new Map<string, string>();
    for (const x of xs) if (!m.has(tagKey(x))) m.set(tagKey(x), x);
    return m;
  };
  const wantSpelling = spelling(want), haveSpelling = spelling(have);
  const ops: Op[] = [];
  for (const t of have) {
    if (wantSpelling.get(tagKey(t)) === t) continue;
    const o = removeTagOp(t, state);
    if (o) ops.push(o);
  }
  for (const t of want) if (haveSpelling.get(tagKey(t)) !== t) ops.push(op.addTag(t));
  return ops;
}

/** `NoteOps.newNote` without the paper validation: a page, title, notebook, paper, page size, tags. */
export function newNoteOps(title: string, tags: string[] = [], pageId = newUUID()): Op[] {
  return [op.addPage(pageId, "V"), op.title(title), op.notebook(undefined), op.paper(defaultPaper("ruled")),
    op.pageSize(letter), ...normalizedTags(tags).map(op.addTag)];
}

// MARK: - Compaction (format.md §5.3, retention 0)

function superset(a: Included, b: Included): boolean {
  for (const [d, e] of b.entries) {
    const mine = a.entries.get(d);
    if (!mine) {
      if (e.upTo > 0 || e.extra.length > 0) return false;
      continue;
    }
    if (mine.upTo < e.upTo || !e.extra.every((s) => entryCovers(mine, s))) return false;
  }
  return true;
}

/**
 * What survives compaction past the retention window: deltas no snapshot
 * covers, and snapshots no other snapshot's `included` subsumes (of equal
 * ones, the greatest name is kept).
 */
export function compact(revisions: Revision[]): Revision[] {
  const snaps = revisions.filter((r) => r.body.type === "snapshot");
  return revisions.filter((r) => {
    if (r.body.type === "delta") return !snaps.some((s) => snapshotParts(s).included.covers(r.device, r.seq));
    const mine = r.body.included;
    return !snaps.some((s) => {
      if (s === r) return false;
      const other = snapshotParts(s).included;
      if (!superset(other, mine)) return false;
      return !superset(mine, other) || cmpName(revisionName(s), revisionName(r)) > 0;
    });
  });
}
