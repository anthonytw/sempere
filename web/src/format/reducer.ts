// Reconstruction of a note from its revisions (format.md §5.2–§5.6), a port of
// Sources/Sempere/NoteReducer.swift. Collect-then-resolve: every snapshot and
// every delta no snapshot covers is folded into commutative structures
// (removal sets, min-origin evidence per page and stroke, max-key LWW
// registers); the state is built from those, so visiting order never matters.

import {
  Included, type Origin, type RevisionName, type Stamp, cmpName, cmpOrigin, cmpStamp, cmpStr, cmpUTF8, nameStamp,
  originOf, originString, parseOrigin, parseStamp, stampString, zeroDevice, zeroHLC, zeroStamp,
} from "./ids.ts";
import {
  type MetaChange, type NoteMeta, type NoteState, type Page, type Paper, type Recognition, type Revision,
  type Stroke, type TagInstance, type TagRemoval, type TagSet, defaultPaper, revisionName,
} from "./model.ts";
import { StrokeLineage } from "./lineage.ts";
import { normalizedTag, tagKey } from "./tags.ts";
import type { JSONObject } from "./json.ts";
import {
  applyItemRegister, applyRecordingRegister, cmpItems, cmpRecordings, itemRegisters, recordingRegisters,
} from "./registers.ts";

/** Errors from reconstruction (Swift `NoteLogError`). */
export class NoteLogError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "NoteLogError";
  }
}

/** Full deterministic LWW key: stamp, then seq and op index, then the source revision. */
interface OpKey {
  stamp: Stamp;
  seq: number;
  index: number;
  src: RevisionName;
}

function cmpKey(a: OpKey, b: OpKey): number {
  return cmpStamp(a.stamp, b.stamp) || (a.seq < b.seq ? -1 : a.seq > b.seq ? 1 : 0)
    || (a.index < b.index ? -1 : a.index > b.index ? 1 : 0) || cmpName(a.src, b.src);
}

/** A value held by snapshot `src`, last set at `stamp`: beats any op with the same stamp. */
function baseKey(stamp: Stamp, src: RevisionName): OpKey {
  return { stamp, seq: Infinity, index: Infinity, src };
}

/** A register nobody set: loses to everything. */
const unsetKey: OpKey = {
  stamp: zeroStamp, seq: -Infinity, index: -Infinity,
  src: { hlc: zeroHLC, device: zeroDevice, seq: 0, kind: "delta" },
};

class Register<V> {
  constructor(public value: V, public key: OpKey) {}

  offer(v: V, k: OpKey): void {
    if (cmpKey(k, this.key) > 0) {
      this.value = v;
      this.key = k;
    }
  }
}

const clockKeys = ["title", "notebook", "favorite", "paper", "pageSize", "deleted", "lang", "markersBehindText", "recognized"] as const;
type ClockKey = (typeof clockKeys)[number];

type RegisterValue = { key: "meta"; change: MetaChange } | { key: "deleted"; value: boolean };

function registerValue(k: ClockKey, s: NoteState): RegisterValue {
  const m = s.meta;
  switch (k) {
    case "title": return { key: "meta", change: { field: "title", value: m.title } };
    case "notebook": return { key: "meta", change: { field: "notebook", value: m.notebook } };
    case "favorite": return { key: "meta", change: { field: "favorite", value: m.favorite } };
    case "paper": return { key: "meta", change: { field: "paper", value: m.paper } };
    case "pageSize": return { key: "meta", change: { field: "pageSize", value: m.pageSize } };
    case "lang": return { key: "meta", change: { field: "lang", value: m.lang } };
    case "markersBehindText": return { key: "meta", change: { field: "markersBehindText", value: m.markersBehindText === true } };
    case "recognized": return { key: "meta", change: { field: "recognized", value: m.recognized } };
    case "deleted": return { key: "deleted", value: s.deleted };
  }
}

function clockKeyOf(v: RegisterValue): ClockKey {
  return v.key === "deleted" ? "deleted" : v.change.field;
}

function applyRegister(v: RegisterValue, s: NoteState): void {
  if (v.key === "deleted") {
    s.deleted = v.value;
    return;
  }
  const c = v.change;
  switch (c.field) {
    case "title": s.meta.title = c.value; break;
    case "notebook":
      if (c.value === undefined) delete s.meta.notebook;
      else s.meta.notebook = c.value;
      break;
    case "favorite": s.meta.favorite = c.value; break;
    case "paper": s.meta.paper = c.value; break;
    case "pageSize": s.meta.pageSize = c.value; break;
    case "lang":
      if (c.value === undefined) delete s.meta.lang;
      else s.meta.lang = c.value;
      break;
    case "markersBehindText":
      if (c.value) s.meta.markersBehindText = true;
      else delete s.meta.markersBehindText;
      break;
    case "recognized":
      if (c.value === undefined) delete s.meta.recognized;
      else s.meta.recognized = c.value;
      break;
  }
}

function defaultMeta(): NoteMeta {
  return {
    title: "", tags: [], favorite: false, created: 0, paper: defaultPaper("blank"),
    pageSize: { width: 612, height: 792, infinite: false },
  };
}

/** Where a page or stroke was seen and which op added it. */
interface Evidence<T> {
  origin: Origin;
  src: RevisionName;
  item: T;
  page?: string;
}

function beats<T>(a: Evidence<T>, b: Evidence<T>): boolean {
  return (cmpOrigin(a.origin, b.origin) || cmpName(a.src, b.src)) < 0;
}

interface Snap {
  name: RevisionName;
  included: Included;
  state: NoteState;
}

/** Structural equality of decoded revisions (for duplicate detection). */
function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a instanceof Included && b instanceof Included) return deepEqual(a.toJSON(), b.toJSON());
  if (a instanceof Float64Array && b instanceof Float64Array) {
    return a.length === b.length && a.every((v, i) => Object.is(v, b[i]) || v === b[i]);
  }
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const ka = Object.keys(a).filter((k) => (a as Record<string, unknown>)[k] !== undefined);
  const kb = Object.keys(b).filter((k) => (b as Record<string, unknown>)[k] !== undefined);
  if (ka.length !== kb.length) return false;
  return ka.every((k) => deepEqual((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k]));
}

/**
 * Checks one note id, drops exact duplicates, rejects two different revisions
 * with the same `(device, seq)`.
 */
export function canonical(revisions: Revision[]): Revision[] {
  const first = revisions[0];
  if (!first) throw new NoteLogError("no revisions");
  const byKey = new Map<string, Revision>();
  for (const r of revisions) {
    if (r.noteId !== first.noteId) throw new NoteLogError(`mixed notes ${first.noteId} and ${r.noteId}`);
    const k = `${r.device}/${r.seq}`;
    const existing = byKey.get(k);
    if (existing) {
      if (!deepEqual(existing, r)) throw new NoteLogError(`conflicting revisions for device ${r.device} seq ${r.seq}`);
    } else {
      byKey.set(k, r);
    }
  }
  return [...byKey.values()];
}

/** Instance identity: (key, origin). Keys compare canonically (NFC), as Swift strings do. */
function tagId(key: string, o: Origin): string {
  return `${key.normalize("NFC")}\u0000${originString(o)}`;
}

/** Tag instances and removals collected from every source (format.md §5.4.1). */
class TagMerge {
  readonly added = new Map<string, { key: string; origin: Origin; tag: string }>();
  readonly removed = new Map<string, TagRemoval>();

  add(raw: string, origin: Origin): void {
    const tag = normalizedTag(raw);
    if (tag.length === 0) return;
    const key = tagKey(tag);
    const id = tagId(key, origin);
    const cur = this.added.get(id);
    // One identity always has one spelling; pick deterministically regardless.
    if (cur && cmpUTF8(tag, cur.tag) >= 0) return;
    this.added.set(id, { key, origin, tag });
  }

  /** A snapshot's set. */
  addSet(set: TagSet): void {
    for (const i of set.instances) this.add(i.tag, i.origin);
    for (const r of set.removed) this.remove(r);
  }

  remove(r: TagRemoval): void {
    const id = tagId(r.key, r.origin);
    if (!this.removed.has(id)) this.removed.set(id, r);
  }

  /** The tag set: every added instance that no removal names. */
  resolve(): TagSet {
    const live = [...this.added.entries()].filter(([id]) => !this.removed.has(id)).map(([, v]) => v);
    const byOriginKey = (a: { origin: Origin; key: string }, b: { origin: Origin; key: string }) =>
      cmpOrigin(a.origin, b.origin) || cmpUTF8(a.key.normalize("NFC"), b.key.normalize("NFC"));
    const instances: TagInstance[] = live.sort(byOriginKey).map((v) => ({ tag: v.tag, origin: v.origin }));
    const removed = [...this.removed.values()].sort(byOriginKey);
    return { instances, removed };
  }
}

/**
 * The tags on the note, one per key: the spelling of the key's earliest live
 * instance, in the order of those instances (format.md §5.4.1).
 */
export function tagsOf(set: TagSet): string[] {
  const seen = new Set<string>();
  const sorted = set.instances.map((i) => ({ ...i, key: tagKey(i.tag) }))
    .sort((a, b) => cmpOrigin(a.origin, b.origin) || cmpUTF8(a.key.normalize("NFC"), b.key.normalize("NFC")));
  const out: string[] = [];
  for (const i of sorted) {
    const k = i.key.normalize("NFC");
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(i.tag);
  }
  return out;
}

/** An origin is written only when it names a real revision (`seq ≥ 1`). */
function emitted(o: Origin): string | undefined {
  return o.seq >= 1 ? originString(o) : undefined;
}

export interface Resolution {
  state: NoteState;
  /** Everything the state reflects in full. */
  included: Included;
}

/**
 * Reconstructs a note (format.md §5.3): the merge of every snapshot plus every
 * delta no snapshot's `included` covers. Identical for any permutation of
 * `revisions`.
 */
export function reconstruct(revisions: Revision[]): NoteState {
  return resolve(canonical(revisions)).state;
}

export function resolve(revs: Revision[]): Resolution {
  const snaps: Snap[] = [];
  const deltas: Revision[] = [];
  for (const r of revs) {
    if (r.body.type === "delta") deltas.push(r);
    else snaps.push({ name: revisionName(r), included: r.body.included, state: r.body.state });
  }
  let earliest: Revision | undefined;
  for (const r of revs) if (!earliest || cmpName(revisionName(r), revisionName(earliest)) < 0) earliest = r;
  return resolveParts(snaps, deltas, earliest?.wall);
}

function opsOf(r: Revision) {
  return r.body.type === "delta" ? r.body.ops : [];
}

function resolveParts(snapshots: Snap[], deltas: Revision[], earliestWall: number | undefined): Resolution {
  const uncovered = deltas.filter((d) => !snapshots.some((s) => s.included.covers(d.device, d.seq)));

  // Removals: every snapshot's tombstones plus removes in uncovered deltas.
  const removedPages = new Set<string>();
  const removedStrokes = new Set<string>();
  const removedItems = new Set<string>();
  const removedRecordings = new Set<string>();
  for (const s of snapshots) {
    for (const id of s.state.tombstones?.pages ?? []) removedPages.add(id);
    for (const id of s.state.tombstones?.strokes ?? []) removedStrokes.add(id);
    for (const id of s.state.tombstones?.items ?? []) removedItems.add(id);
    for (const id of s.state.tombstones?.recordings ?? []) removedRecordings.add(id);
  }
  for (const d of uncovered) {
    for (const op of opsOf(d)) if (op.op === "removeStroke") removedStrokes.add(op.strokeId);
  }
  // Page, item and recording tombstones and removed tag instances are permanent: every revision counts.
  const tagRemovals: TagRemoval[] = [];
  for (const d of deltas) {
    for (const op of opsOf(d)) {
      if (op.op === "removePage") removedPages.add(op.pageId);
      else if (op.op === "removeItem") removedItems.add(op.itemId);
      else if (op.op === "removeRecording") removedRecordings.add(op.recordingId);
      else if (op.op === "removeTag") {
        const key = tagKey(op.tag);
        for (const o of op.observed) tagRemovals.push({ key, origin: o });
      }
    }
  }

  // Orphans (§5.3): applied but not listed in `included`. A removed page,
  // item or recording is known (its tombstone is permanent).
  const knownPages = new Set(removedPages);
  const knownItems = new Set(removedItems);
  const knownRecordings = new Set(removedRecordings);
  for (const s of snapshots) {
    for (const p of s.state.pages) {
      knownPages.add(p.id);
      for (const it of p.items) knownItems.add(String(it.id));
    }
    for (const r of s.state.recordings) knownRecordings.add(String(r.id));
  }
  for (const d of deltas) {
    for (const op of opsOf(d)) {
      if (op.op === "addPage") knownPages.add(op.page.id);
      else if (op.op === "addItem") knownItems.add(String(op.item.id));
      else if (op.op === "addRecording") knownRecordings.add(String(op.recording.id));
    }
  }
  const isOrphan = (d: Revision) => opsOf(d).some((op) => {
    switch (op.op) {
      case "addStroke": return !knownPages.has(op.page);
      case "setPageOrder":
      case "setPageRecognition":
      case "setPagePaper": return !knownPages.has(op.pageId);
      case "addItem": return !knownPages.has(op.page);
      // On a removed page, a no-op whatever the item (a page removal does not
      // tombstone its items, so after compaction the item may be known nowhere).
      case "setItem": return !knownPages.has(op.page) || (!removedPages.has(op.page) && !knownItems.has(op.itemId));
      case "setRecording": return !knownRecordings.has(op.recordingId);
      default: return false;
    }
  });
  const orphans = new Set(uncovered.filter(isOrphan));

  // LWW registers, one per clock key.
  const defaults: NoteState = {
    deleted: false, meta: defaultMeta(), pages: [], recordings: [], tagSet: { instances: [], removed: [] },
  };
  const registers = new Map<ClockKey, Register<RegisterValue>>();
  for (const k of clockKeys) registers.set(k, new Register(registerValue(k, defaults), unsetKey));
  const offer = (v: RegisterValue, k: OpKey) => registers.get(clockKeyOf(v))?.offer(v, k);
  let created = earliestWall;
  const order = new Map<string, Register<string>>();
  const recognition = new Map<string, Register<Recognition | undefined>>();
  const pagePaper = new Map<string, Register<Paper | undefined>>();
  const pages = new Map<string, Evidence<Page>>();
  const strokes = new Map<string, Evidence<Stroke>>();
  const snapPageIds = new Map<Snap, Set<string>>();
  const snapStrokeIds = new Map<Snap, Set<string>>();
  // Items and recordings: set evidence like strokes, one LWW register per (id, field).
  const items = new Map<string, Evidence<JSONObject>>();
  const recordings = new Map<string, Evidence<JSONObject>>();
  const itemRegs = new Map<string, Map<string, Register<unknown>>>();
  const recordingRegs = new Map<string, Map<string, Register<unknown>>>();
  const snapItemIds = new Map<Snap, Set<string>>();
  const snapRecordingIds = new Map<Snap, Set<string>>();
  const offerRegister = (m: Map<string, Map<string, Register<unknown>>>, id: string, field: string, v: unknown, k: OpKey) => {
    let regs = m.get(id);
    if (!regs) {
      regs = new Map();
      m.set(id, regs);
    }
    const r = regs.get(field);
    if (r) r.offer(v, k);
    else regs.set(field, new Register(v, k));
  };
  const offerItem = (e: Evidence<JSONObject>, key: (field: string) => OpKey) => {
    const id = String(e.item.id);
    const cur = items.get(id);
    if (!cur || beats(e, cur)) items.set(id, e);
    for (const [f, v] of itemRegisters(e.item)) offerRegister(itemRegs, id, f, v, key(f));
  };
  const offerRecording = (e: Evidence<JSONObject>, key: (field: string) => OpKey) => {
    const id = String(e.item.id);
    const cur = recordings.get(id);
    if (!cur || beats(e, cur)) recordings.set(id, e);
    for (const [f, v] of recordingRegisters(e.item)) offerRegister(recordingRegs, id, f, v, key(f));
  };

  const offerOrder = (id: string, v: string, k: OpKey) => {
    const r = order.get(id);
    if (r) r.offer(v, k);
    else order.set(id, new Register(v, k));
  };
  const offerOptional = <V>(m: Map<string, Register<V | undefined>>, id: string, v: V | undefined, k: OpKey) => {
    let r = m.get(id);
    if (!r) {
      r = new Register<V | undefined>(undefined, unsetKey);
      m.set(id, r);
    }
    r.offer(v, k);
  };
  const offerPage = (e: Evidence<Page>) => {
    const cur = pages.get(e.item.id);
    if (cur && !beats(e, cur)) return;
    pages.set(e.item.id, e);
  };
  const offerStroke = (e: Evidence<Stroke>) => {
    const cur = strokes.get(e.item.id);
    if (cur && !beats(e, cur)) return;
    strokes.set(e.item.id, e);
  };
  // Items and recordings are kept as JSON: `null` is an absent optional field (Swift `decodeIfPresent`).
  const optString = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);
  const clock = (s: string | undefined, fallback: Stamp) => (s === undefined ? undefined : parseStamp(s)) ?? fallback;
  const origin = (s: string | undefined, fallback: Origin) => (s === undefined ? undefined : parseOrigin(s)) ?? fallback;

  const tags = new TagMerge();
  for (const s of snapshots) {
    const stamp = nameStamp(s.name);
    for (const k of clockKeys) {
      offer(registerValue(k, s.state), baseKey(clock(s.state.clocks?.[k], stamp), s.name));
    }
    tags.addSet(s.state.tagSet);
    const m = s.state.meta;
    created = Math.min(created ?? m.created, m.created);

    const pageIds = new Set<string>(), strokeIds = new Set<string>(), itemIds = new Set<string>();
    s.state.pages.forEach((p, pos) => {
      pageIds.add(p.id);
      // Without a recorded origin, the holding snapshot is the origin (§5.5).
      offerPage({ origin: origin(p.origin, originOf(s.name, pos)), src: s.name, item: p });
      offerOrder(p.id, p.order, baseKey(clock(p.orderClock, stamp), s.name));
      // A page with neither recognition nor its clock never had one set (§5.5).
      if (p.recognition !== undefined || p.recognitionClock !== undefined) {
        offerOptional(recognition, p.id, p.recognition, baseKey(clock(p.recognitionClock, stamp), s.name));
      }
      // Likewise a page with neither paper nor its clock follows the note (§5.4.2).
      if (p.paper !== undefined || p.paperClock !== undefined) {
        offerOptional(pagePaper, p.id, p.paper, baseKey(clock(p.paperClock, stamp), s.name));
      }
      p.strokes.forEach((st, j) => {
        strokeIds.add(st.id);
        offerStroke({ origin: origin(st.origin, originOf(s.name, j)), src: s.name, item: st, page: p.id });
      });
      p.items.forEach((it, j) => {
        itemIds.add(String(it.id));
        const clocks = it.clocks as Record<string, string> | undefined;
        // A register without a clock is stamped by the snapshot (§8.2.1).
        offerItem({ origin: origin(optString(it.origin), originOf(s.name, j)), src: s.name, item: it, page: p.id },
          (f) => baseKey(clock(clocks?.[f], stamp), s.name));
      });
    });
    const recordingIds = new Set<string>();
    s.state.recordings.forEach((r, j) => {
      recordingIds.add(String(r.id));
      const clocks = r.clocks as Record<string, string> | undefined;
      offerRecording({ origin: origin(optString(r.origin), originOf(s.name, j)), src: s.name, item: r },
        (f) => baseKey(clock(clocks?.[f], stamp), s.name));
    });
    snapPageIds.set(s, pageIds);
    snapStrokeIds.set(s, strokeIds);
    snapItemIds.set(s, itemIds);
    snapRecordingIds.set(s, recordingIds);
  }

  for (const d of uncovered) {
    const name = revisionName(d);
    opsOf(d).forEach((op, i) => {
      const k: OpKey = { stamp: nameStamp(name), seq: d.seq, index: i, src: name };
      switch (op.op) {
        case "addStroke":
          offerStroke({ origin: originOf(name, i), src: name, item: op.stroke, page: op.page });
          break;
        case "addPage":
          // §5.2: the page is added empty.
          offerPage({ origin: originOf(name, i), src: name, item: op.page });
          offerOrder(op.page.id, op.page.order, k);
          break;
        case "setPageOrder": offerOrder(op.pageId, op.order, k); break;
        case "setPageRecognition": offerOptional(recognition, op.pageId, op.recognition, k); break;
        case "setPagePaper": offerOptional(pagePaper, op.pageId, op.paper, k); break;
        case "setMeta": offer({ key: "meta", change: op.change }, k); break;
        case "addTag": tags.add(op.tag, originOf(name, i)); break;
        case "deleteNote": offer({ key: "deleted", value: true }, k); break;
        case "restoreNote": offer({ key: "deleted", value: false }, k); break;
        case "addItem":
          // §8.2.2: the add sets every register at its own stamp.
          offerItem({ origin: originOf(name, i), src: name, item: op.item, page: op.page }, () => k);
          break;
        case "setItem": offerRegister(itemRegs, op.itemId, op.field, op.value, k); break;
        case "addRecording": offerRecording({ origin: originOf(name, i), src: name, item: op.recording }, () => k); break;
        case "setRecording": offerRegister(recordingRegs, op.recordingId, op.field, op.value, k); break;
        // Removals were collected above.
        default: break;
      }
    });
  }

  // Gone if a snapshot covers the revision that added it but does not hold it.
  const removedByCoverage = (o: Origin, id: string, held: Map<Snap, Set<string>>) =>
    snapshots.some((s) => s.included.covers(o.device, o.seq) && !(held.get(s)?.has(id) ?? false));

  const livePages = new Set<string>();
  for (const e of pages.values()) {
    if (!removedPages.has(e.item.id) && !removedByCoverage(e.origin, e.item.id, snapPageIds)) livePages.add(e.item.id);
  }

  // Concurrent replacements of one stroke (§5.6.1): the losers count as removed.
  const lineage = new StrokeLineage(snapshots, deltas.map((d) => ({ name: revisionName(d), rev: d })));
  const superseded = lineage.superseded();
  const byPage = new Map<string, Evidence<Stroke>[]>();
  for (const e of strokes.values()) {
    if (e.page === undefined || !livePages.has(e.page) || removedStrokes.has(e.item.id)
      || removedByCoverage(e.origin, e.item.id, snapStrokeIds) || superseded.has(e.item.id)) continue;
    const list = byPage.get(e.page) ?? [];
    list.push(e);
    byPage.set(e.page, list);
  }

  /** A copy of the evidence's object with every register's winning value and its clock. */
  const resolved = (e: Evidence<JSONObject>, regs: Map<string, Register<unknown>> | undefined,
    apply: (o: JSONObject, f: string, v: unknown) => void): JSONObject => {
    const o: JSONObject = { ...e.item };
    delete o.origin;
    delete o.clocks;
    const em = emitted(e.origin);
    if (em !== undefined) o.origin = em;
    const clocks: Record<string, string> = {};
    for (const [f, reg] of regs ?? []) {
      apply(o, f, reg.value);
      clocks[f] = stampString(reg.key.stamp);
    }
    if (Object.keys(clocks).length > 0) o.clocks = clocks;
    return o;
  };
  const itemsByPage = new Map<string, JSONObject[]>();
  for (const [id, e] of items) {
    if (e.page === undefined || !livePages.has(e.page) || removedItems.has(id)
      || removedByCoverage(e.origin, id, snapItemIds)) continue;
    const list = itemsByPage.get(e.page) ?? [];
    list.push(resolved(e, itemRegs.get(id), applyItemRegister));
    itemsByPage.set(e.page, list);
  }
  const outRecordings: JSONObject[] = [];
  for (const [id, e] of recordings) {
    if (removedRecordings.has(id) || removedByCoverage(e.origin, id, snapRecordingIds)) continue;
    outRecordings.push(resolved(e, recordingRegs.get(id), applyRecordingRegister));
  }
  outRecordings.sort(cmpRecordings);

  const outPages: Page[] = [];
  for (const id of livePages) {
    const e = pages.get(id), reg = order.get(id);
    if (!e || !reg) continue;
    const list = (byPage.get(id) ?? []).sort((a, b) => cmpOrigin(a.origin, b.origin) || cmpStr(a.item.id, b.item.id));
    const page: Page = {
      id, order: reg.value,
      strokes: list.map((x) => {
        const s: Stroke = { ...x.item };
        const o = emitted(x.origin);
        if (o === undefined) delete s.origin;
        else s.origin = o;
        if (s.parent !== undefined && lineage.replaces(s.id)) s.replaces = true;
        else delete s.replaces;
        return s;
      }),
      orderClock: stampString(reg.key.stamp),
      items: (itemsByPage.get(id) ?? []).sort(cmpItems),
    };
    const o = emitted(e.origin);
    if (o !== undefined) page.origin = o;
    const rec = recognition.get(id);
    if (rec) {
      if (rec.value) page.recognition = rec.value;
      page.recognitionClock = stampString(rec.key.stamp);
    }
    if (e.item.parent !== undefined) page.parent = e.item.parent;
    const pp = pagePaper.get(id);
    if (pp) {
      if (pp.value) page.paper = pp.value;
      page.paperClock = stampString(pp.key.stamp);
    }
    outPages.push(page);
  }
  // As Swift: keys that are canonically equal (Swift `!=`) tie and fall back
  // to the id; others order byte-wise (code points), not by normalised form.
  outPages.sort((l, r) => (l.order.normalize("NFC") === r.order.normalize("NFC") ? 0 : cmpUTF8(l.order, r.order))
    || cmpStr(l.id, r.id));

  // What a new `included` would reflect.
  let included = new Included();
  for (const s of snapshots) {
    included = included.union(s.included);
    if (s.name.seq >= 1) included.insert(s.name.device, s.name.seq);
  }
  for (const d of uncovered) if (!orphans.has(d)) included.insert(d.device, d.seq);

  // A stroke tombstone may be dropped only once the revision that added it is covered (§5.4).
  const addOrigins = new Map<string, Origin[]>();
  const pushOrigin = (id: string, o: Origin) => {
    const l = addOrigins.get(id) ?? [];
    l.push(o);
    addOrigins.set(id, l);
  };
  for (const e of strokes.values()) pushOrigin(e.item.id, e.origin);
  for (const d of deltas) {
    const name = revisionName(d);
    opsOf(d).forEach((op, i) => {
      if (op.op === "addStroke") pushOrigin(op.stroke.id, originOf(name, i));
    });
  }
  const keptStrokes = [...new Set([...removedStrokes, ...superseded])].filter((id) =>
    !(addOrigins.get(id) ?? []).some((o) => included.covers(o.device, o.seq)));
  const held = new Set(outPages.flatMap((p) => p.strokes.map((s) => s.id)));
  const lineageRecords = lineage.records(held, superseded);

  const state: NoteState = {
    deleted: false, meta: defaultMeta(), pages: outPages, recordings: outRecordings, tagSet: { instances: [], removed: [] },
  };
  if (keptStrokes.length > 0 || removedPages.size > 0 || removedItems.size > 0 || removedRecordings.size > 0
    || lineageRecords.length > 0 || superseded.size > 0) {
    state.tombstones = {
      strokes: keptStrokes.sort(cmpStr), pages: [...removedPages].sort(cmpStr),
      items: [...removedItems].sort(cmpStr), recordings: [...removedRecordings].sort(cmpStr),
      lineage: lineageRecords, superseded: [...superseded].sort(cmpStr),
    };
  }
  state.meta.created = created ?? 0;
  const clocks: Record<string, string> = {};
  for (const [k, reg] of registers) {
    applyRegister(reg.value, state);
    clocks[k] = stampString(reg.key.stamp);
  }
  state.clocks = clocks;
  for (const r of tagRemovals) tags.remove(r);
  state.tagSet = tags.resolve();
  state.meta.tags = tagsOf(state.tagSet);
  return { state, included };
}
