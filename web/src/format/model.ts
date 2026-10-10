// The format's JSON model (format.md §5.1–§5.6), decoded with the rules of
// Sources/Sempere/Model.swift and Revision.swift, and encoded back the way
// Swift's `InkJSON.encoder` writes it (so a reconstructed note can be compared
// with `sempere export --format json`).

import {
  DecodeError, type JSONObject, arr, arrayOf, bool, fail, int, num, obj, opt, optWith, req, reqWith, round3,
  str, uuid,
} from "./json.ts";
import {
  Included, type Origin, type RevisionKind, type RevisionName, isDeviceID, isHLC, maxSeq, normalizeEntry,
  parseTagInstance, originString,
} from "./ids.ts";
import { parseRFC3339 } from "./rfc3339.ts";
import { type NewerContent, countName, emptyNewer, isNewerFormat, knownFeatures, revisionMarkersNewer } from "./newer.ts";
import { Budget, checkItemChange, checkRecordingChange, decodeItem, decodeRecording } from "./attachments.ts";

export const inkTools = ["pen", "pencil", "marker", "monoline", "fountainPen", "watercolor", "crayon"] as const;
export type InkTool = (typeof inkTools)[number];

/** `#RRGGBBAA`, uppercase: how Swift re-encodes any colour it read. */
export type Color = string;

export interface Ink {
  tool: InkTool;
  color: Color;
  width: number;
}

/** Stride of `Stroke.points`: `[x, y, t, w, h, o, f, az, al]` per control point. */
export const pointStride = 9;

export interface RecordingLink {
  id: string;
  at: number;
}

export interface Stroke {
  id: string;
  ink: Ink;
  /** Control points, `pointStride` numbers each. */
  points: Float64Array;
  /** `[a, b, c, d, tx, ty]`; absent is identity. */
  transform?: number[];
  parent?: string;
  origin?: string;
  rec?: RecordingLink;
  /** Snapshot only: the adding revision also removed `parent` (format.md §5.6.1). */
  replaces?: boolean;
}

export interface RecognitionWord {
  t: string;
  box: [number, number, number, number];
}

export interface Recognition {
  engine: string;
  text: string;
  words: RecognitionWord[];
  basis?: string;
}

export const paperKinds = ["blank", "ruled", "grid", "dot", "marginRuled", "isoDot", "isoGrid", "cornell", "staff"] as const;
export type PaperKind = (typeof paperKinds)[number];

export interface Paper {
  /** `kind` as written; an unknown name renders as blank (§5.4.2). */
  kindName: string;
  spacing: number;
  background: Color;
  lineColor: Color;
  lineWidth: number;
  dotRadius: number;
  marginLeft: number;
  marginTop: number;
  marginColor: Color;
  cueWidth: number;
  summaryHeight: number;
  staffSpacing: number;
  staffGap: number;
}

export interface PageSize {
  width: number;
  height: number;
  infinite: boolean;
  breakHeight?: number;
}

export interface NoteMeta {
  title: string;
  tags: string[];
  notebook?: string;
  favorite: boolean;
  /** Unix milliseconds. */
  created: number;
  paper: Paper;
  pageSize: PageSize;
  /** BCP 47 language of the handwriting (§5.4); absent when unknown. */
  lang?: string;
  /** Marker strokes drawn below content items (§5.4, §8.2.3); absent is false. */
  markersBehindText?: boolean;
  /** The last deliberate recognition run that read the note (§5.4); absent when none. */
  recognized?: RecognitionRecord;
}

/** `meta.recognized` (§5.4; Swift `RecognitionRecord`): `at` in Unix milliseconds. */
export interface RecognitionRecord {
  at: number;
  pages: number;
  read: number;
}

/** Most pages a recognition record may claim (§5.4). */
export const maxRecognizedPages = 100_000;

function recognitionRecord(v: unknown, path: string): RecognitionRecord {
  const o = obj(v, path);
  const r = { at: reqWith(o, "at", path, date), pages: reqWith(o, "pages", path, int), read: reqWith(o, "read", path, int) };
  if (r.pages < 0 || r.pages > maxRecognizedPages || r.read < 0 || r.read > r.pages) fail(path, "recognized counts out of range");
  return r;
}

/**
 * `tag` if it is a plausible BCP 47 tag (§5.4; Swift `NoteMeta.validLanguage`):
 * 1–8 subtags of 1–8 ASCII letters or digits joined by `-`, the first letters
 * only, at most 64 characters; `_` reads as `-`.
 */
export function validLanguage(tag: string): string | undefined {
  const t = tag.replaceAll("_", "-");
  if (t.length === 0 || t.length > 64) return undefined;
  const parts = t.split("-");
  if (parts.length > 8 || !/^[A-Za-z]+$/.test(parts[0] ?? "")) return undefined;
  return parts.every((p) => /^[A-Za-z0-9]{1,8}$/.test(p)) ? t : undefined;
}

export interface Page {
  id: string;
  order: string;
  strokes: Stroke[];
  orderClock?: string;
  origin?: string;
  recognition?: Recognition;
  recognitionClock?: string;
  parent?: string;
  paper?: Paper;
  paperClock?: string;
  /** Placed items (§8.2) as validated JSON objects, in drawing order `(layer, z, id)`. */
  items: JSONObject[];
}

export interface TagInstance {
  tag: string;
  origin: Origin;
}

export interface TagRemoval {
  key: string;
  origin: Origin;
}

export interface TagSet {
  instances: TagInstance[];
  removed: TagRemoval[];
  legacy?: { tags: string[]; clock: string };
}

export interface Tombstones {
  strokes: string[];
  pages: string[];
  items: string[];
  recordings: string[];
  /** Removed strokes that replaced `parent` in revision `by` (format.md §5.4, §5.6.1). */
  lineage: LineageRecord[];
  /** Strokes superseded by a concurrent replacement (§5.6.1). */
  superseded: string[];
}

export interface LineageRecord {
  stroke: string;
  parent: string;
  /** `"<hlc>-<device>-<seq>"` */
  by: string;
}

export interface NoteState {
  deleted: boolean;
  meta: NoteMeta;
  pages: Page[];
  clocks?: Record<string, string>;
  tombstones?: Tombstones;
  tagSet?: TagSet;
  /** Recordings (§8.3) as validated JSON objects, sorted by `(started, id)`. */
  recordings: JSONObject[];
}

export type MetaChange =
  | { field: "title"; value: string }
  | { field: "tags"; value: string[] }
  | { field: "notebook"; value: string | undefined }
  | { field: "favorite"; value: boolean }
  | { field: "paper"; value: Paper }
  | { field: "pageSize"; value: PageSize }
  | { field: "lang"; value: string | undefined }
  | { field: "markersBehindText"; value: boolean }
  | { field: "recognized"; value: RecognitionRecord | undefined };

export type Op =
  | { op: "addStroke"; page: string; stroke: Stroke }
  | { op: "removeStroke"; page: string; strokeId: string }
  | { op: "addPage"; page: Page }
  | { op: "removePage"; pageId: string }
  | { op: "setPageOrder"; pageId: string; order: string }
  | { op: "setPageRecognition"; pageId: string; recognition: Recognition | undefined }
  | { op: "setPagePaper"; pageId: string; paper: Paper | undefined }
  | { op: "setMeta"; change: MetaChange }
  | { op: "addTag"; tag: string }
  | { op: "removeTag"; tag: string; observed: Origin[] }
  | { op: "deleteNote" }
  | { op: "restoreNote" }
  | { op: "addItem"; page: string; item: JSONObject }
  | { op: "removeItem"; page: string; itemId: string }
  /** `value` is `null` when the op has none (a reset). */
  | { op: "setItem"; page: string; itemId: string; field: string; value: unknown }
  | { op: "addRecording"; recording: JSONObject }
  | { op: "removeRecording"; recordingId: string }
  | { op: "setRecording"; recordingId: string; field: string; value: unknown };

export type RevisionBody =
  | { type: "delta"; ops: Op[] }
  | { type: "snapshot"; included: Included; state: NoteState };

export interface Revision {
  noteId: string;
  device: string;
  seq: number;
  hlc: string;
  /** Unix milliseconds. */
  wall: number;
  app: string;
  body: RevisionBody;
  /**
   * Set when the revision was written by a newer version (its `format` or
   * `features`, format.md §7.1) and decoded leniently: what was skipped (§7.4).
   */
  newer?: NewerContent;
}

/** Lenient decoding of a newer revision (§7.4): counts what is skipped. */
interface Lenient {
  newer: NewerContent;
}

/** `arrayOf`, but in a newer revision an element that does not decode is skipped and counted. */
function elements<T>(v: unknown, path: string, lenient: Lenient | undefined, f: (v: unknown, path: string) => T): T[] {
  if (!lenient) return arrayOf(v, path, f);
  const out: T[] = [];
  arr(v, path).forEach((e, i) => {
    try {
      out.push(f(e, `${path}[${i}]`));
    } catch (err) {
      if (!(err instanceof DecodeError)) throw err;
      lenient.newer.skippedElements++;
    }
  });
  return out;
}

export function revisionName(r: Revision): RevisionName {
  return { hlc: r.hlc, device: r.device, seq: r.seq, kind: r.body.type };
}

// MARK: - Decoding

/**
 * `#RRGGBB` or `#RRGGBBAA`, as Swift's `Color(hex:)`, which parses the digits
 * with `UInt32(_:radix:)` (so a leading sign is tolerated). Returns the
 * canonical uppercase `#RRGGBBAA`.
 */
export function parseColor(s: string): Color | undefined {
  const body = s.startsWith("#") ? s.slice(1) : s;
  const count = [...body].length;
  if (count !== 6 && count !== 8) return undefined;
  let digits = body;
  if (digits.startsWith("+")) digits = digits.slice(1);
  else if (digits.startsWith("-")) {
    if (!/^-0+$/.test(digits)) return undefined;
    digits = "0";
  }
  if (!/^[0-9a-fA-F]+$/.test(digits)) return undefined;
  let v = parseInt(digits, 16);
  if (count === 6) v = v * 256 + 255;
  return "#" + (v >>> 0).toString(16).toUpperCase().padStart(8, "0");
}

function color(v: unknown, path: string): Color {
  const s = str(v, path);
  const c = parseColor(s);
  if (c === undefined) fail(path, "bad colour");
  return c;
}

function date(v: unknown, path: string): number {
  const ms = parseRFC3339(str(v, path));
  if (ms === undefined) fail(path, "bad date");
  return ms;
}

function hlc(v: unknown, path: string): string {
  const s = str(v, path);
  if (!isHLC(s)) fail(path, "bad hlc");
  return s;
}

function deviceID(v: unknown, path: string): string {
  const s = str(v, path);
  if (!isDeviceID(s)) fail(path, "bad device id");
  return s;
}

function strings(v: unknown, path: string): string[] {
  return arrayOf(v, path, str);
}

function numbers(v: unknown, path: string, count: number, exact: boolean): number[] {
  const a = arr(v, path);
  if (a.length < count || (exact && a.length > count)) fail(path, `expected ${count} numbers`);
  return a.slice(0, count).map((e, i) => num(e, `${path}[${i}]`));
}

function recordingLink(v: unknown, path: string): RecordingLink {
  const o = obj(v, path);
  return { id: reqWith(o, "id", path, uuid), at: reqWith(o, "at", path, num) };
}

export function decodeStroke(v: unknown, path: string): Stroke {
  const o = obj(v, path);
  const inkO = obj(req(o, "ink", path), `${path}.ink`);
  const toolName = reqWith(inkO, "tool", `${path}.ink`, str);
  const tool: InkTool = (inkTools as readonly string[]).includes(toolName) ? toolName as InkTool : "pen";
  const ink: Ink = {
    tool,
    color: reqWith(inkO, "color", `${path}.ink`, color),
    width: reqWith(inkO, "width", `${path}.ink`, num),
  };
  const pts = arr(req(o, "points", path), `${path}.points`);
  const points = new Float64Array(pts.length * pointStride);
  pts.forEach((p, i) => {
    // Swift's unkeyed decode reads nine numbers and ignores any beyond them.
    const a = numbers(p, `${path}.points[${i}]`, pointStride, false);
    points.set(a, i * pointStride);
  });
  const s: Stroke = { id: reqWith(o, "id", path, uuid), ink, points };
  const transform = optWith(o, "transform", path, (t, p) => numbers(t, p, 6, false));
  if (transform) s.transform = transform;
  const parent = optWith(o, "parent", path, uuid);
  if (parent !== undefined) s.parent = parent;
  const origin = optWith(o, "origin", path, str);
  if (origin !== undefined) s.origin = origin;
  const rec = optWith(o, "rec", path, recordingLink);
  if (rec) s.rec = rec;
  if (optWith(o, "replaces", path, bool)) s.replaces = true;
  return s;
}

export function decodeRecognition(v: unknown, path: string): Recognition {
  const o = obj(v, path);
  const r: Recognition = {
    engine: reqWith(o, "engine", path, str),
    text: reqWith(o, "text", path, str),
    words: reqWith(o, "words", path, (w, p) => arrayOf(w, p, (e, q) => {
      const wo = obj(e, q);
      const box = reqWith(wo, "box", q, (b, bp) => numbers(b, bp, 4, false)) as [number, number, number, number];
      return { t: reqWith(wo, "t", q, str), box };
    })),
  };
  // Readers ignore a basis they do not understand (`try?` in Swift).
  const basis = opt(o, "basis");
  if (typeof basis === "string") r.basis = basis;
  return r;
}

/** The default paper of a kind (Swift's `Paper(kind:)`). */
export function defaultPaper(kindName: string): Paper {
  return {
    kindName, spacing: 24, background: "#FFFFFFFF", lineColor: "#D0D8E8FF", lineWidth: 0.5, dotRadius: 0.9,
    marginLeft: kindName === "marginRuled" ? 72 : 0, marginTop: 0, marginColor: "#F2A6A6FF",
    cueWidth: 150, summaryHeight: 120, staffSpacing: 7, staffGap: 40,
  };
}

/** The kind a renderer draws: an unknown name is blank. */
export function paperKind(p: Paper): PaperKind {
  return (paperKinds as readonly string[]).includes(p.kindName) ? p.kindName as PaperKind : "blank";
}

const paperNumberFields = ["spacing", "lineWidth", "dotRadius", "marginLeft", "marginTop", "cueWidth",
  "summaryHeight", "staffSpacing", "staffGap"] as const;
const paperColorFields = ["background", "lineColor", "marginColor"] as const;

export function decodePaper(v: unknown, path: string): Paper {
  const o = obj(v, path);
  const name = reqWith(o, "kind", path, str);
  // Defaults follow the kind as this reader knows it (an unknown kind is blank).
  const p = defaultPaper(paperKinds.includes(name as PaperKind) ? name : "blank");
  p.kindName = name;
  for (const f of paperNumberFields) {
    const x = optWith(o, f, path, num);
    if (x !== undefined) p[f] = x;
  }
  for (const f of paperColorFields) {
    const x = optWith(o, f, path, color);
    if (x !== undefined) p[f] = x;
  }
  return p;
}

function decodePageSize(v: unknown, path: string): PageSize {
  const o = obj(v, path);
  const s: PageSize = {
    width: reqWith(o, "width", path, num),
    height: reqWith(o, "height", path, num),
    infinite: reqWith(o, "infinite", path, bool),
  };
  const b = optWith(o, "breakHeight", path, num);
  if (b !== undefined) s.breakHeight = b;
  return s;
}

export function decodePage(v: unknown, path: string, budget: Budget, lenient?: Lenient): Page {
  const o = obj(v, path);
  const p: Page = {
    id: reqWith(o, "id", path, uuid),
    order: reqWith(o, "order", path, str),
    strokes: optWith(o, "strokes", path, (s, q) => elements(s, q, lenient, decodeStroke)) ?? [],
    items: optWith(o, "items", path, (s, q) => elements(s, q, lenient, (e, r) => decodeItem(e, r, budget))) ?? [],
  };
  const orderClock = optWith(o, "orderClock", path, str);
  if (orderClock !== undefined) p.orderClock = orderClock;
  const origin = optWith(o, "origin", path, str);
  if (origin !== undefined) p.origin = origin;
  const recognition = optWith(o, "recognition", path, decodeRecognition);
  if (recognition) p.recognition = recognition;
  const recognitionClock = optWith(o, "recognitionClock", path, str);
  if (recognitionClock !== undefined) p.recognitionClock = recognitionClock;
  const parent = optWith(o, "parent", path, uuid);
  if (parent !== undefined) p.parent = parent;
  const paper = optWith(o, "paper", path, decodePaper);
  if (paper) p.paper = paper;
  const paperClock = optWith(o, "paperClock", path, str);
  if (paperClock !== undefined) p.paperClock = paperClock;
  return p;
}

function decodeMeta(v: unknown, path: string): NoteMeta {
  const o = obj(v, path);
  const m: NoteMeta = {
    title: reqWith(o, "title", path, str),
    tags: reqWith(o, "tags", path, strings),
    favorite: reqWith(o, "favorite", path, bool),
    created: reqWith(o, "created", path, date),
    paper: reqWith(o, "paper", path, decodePaper),
    pageSize: reqWith(o, "pageSize", path, decodePageSize),
  };
  const notebook = optWith(o, "notebook", path, str);
  if (notebook !== undefined) m.notebook = notebook;
  // Optional fields: a value of the wrong type reads as absent (§5.4).
  const lang = typeof o.lang === "string" ? validLanguage(o.lang) : undefined;
  if (lang !== undefined) m.lang = lang;
  if (o.markersBehindText === true) m.markersBehindText = true;
  if (o.recognized !== undefined && o.recognized !== null) {
    try {
      m.recognized = recognitionRecord(o.recognized, `${path}.recognized`);
    } catch (e) {
      if (!(e instanceof DecodeError)) throw e;
    }
  }
  return m;
}

function tagOrigin(v: unknown, path: string): Origin {
  const s = str(v, path);
  const o = parseTagInstance(s);
  if (!o) fail(path, "bad tag instance");
  return o;
}

function decodeTagSet(v: unknown, path: string): TagSet {
  const o = obj(v, path);
  const t: TagSet = {
    instances: optWith(o, "instances", path, (a, p) => arrayOf(a, p, (e, q) => {
      const io = obj(e, q);
      return { tag: reqWith(io, "tag", q, str), origin: reqWith(io, "origin", q, tagOrigin) };
    })) ?? [],
    removed: optWith(o, "removed", path, (a, p) => arrayOf(a, p, (e, q) => {
      const ro = obj(e, q);
      return { key: reqWith(ro, "key", q, str), origin: reqWith(ro, "origin", q, tagOrigin) };
    })) ?? [],
  };
  const legacy = optWith(o, "legacy", path, (l, p) => {
    const lo = obj(l, p);
    return { tags: reqWith(lo, "tags", p, strings), clock: reqWith(lo, "clock", p, str) };
  });
  if (legacy) t.legacy = legacy;
  return t;
}

function uuids(v: unknown, path: string): string[] {
  return arrayOf(v, path, uuid);
}

function decodeTombstones(v: unknown, path: string): Tombstones {
  const o = obj(v, path);
  return {
    strokes: optWith(o, "strokes", path, uuids) ?? [],
    pages: optWith(o, "pages", path, uuids) ?? [],
    items: optWith(o, "items", path, uuids) ?? [],
    recordings: optWith(o, "recordings", path, uuids) ?? [],
    lineage: optWith(o, "lineage", path, (a, p) => arrayOf(a, p, lineageRecord)) ?? [],
    superseded: optWith(o, "superseded", path, uuids) ?? [],
  };
}

function lineageRecord(v: unknown, path: string): LineageRecord {
  const o = obj(v, path);
  return { stroke: reqWith(o, "stroke", path, uuid), parent: reqWith(o, "parent", path, uuid), by: reqWith(o, "by", path, str) };
}

function decodeClocks(v: unknown, path: string): Record<string, string> {
  const o = obj(v, path);
  const out: Record<string, string> = {};
  for (const [k, x] of Object.entries(o)) out[k] = str(x, `${path}.${k}`);
  return out;
}

export function decodeState(v: unknown, path: string, budget: Budget, lenient?: Lenient): NoteState {
  const o = obj(v, path);
  const s: NoteState = {
    deleted: reqWith(o, "deleted", path, bool),
    meta: reqWith(o, "meta", path, decodeMeta),
    // The key is required, but null reads as no pages (Swift: contains, then decodeIfPresent).
    pages: req(o, "pages", path) === null ? []
      : reqWith(o, "pages", path, (a, p) => elements(a, p, lenient, (e, q) => decodePage(e, q, budget, lenient))),
    recordings: optWith(o, "recordings", path,
      (a, p) => elements(a, p, lenient, (e, q) => decodeRecording(e, q, budget))) ?? [],
  };
  const clocks = optWith(o, "clocks", path, decodeClocks);
  if (clocks) s.clocks = clocks;
  const tombstones = optWith(o, "tombstones", path, decodeTombstones);
  if (tombstones) s.tombstones = tombstones;
  const tagSet = optWith(o, "tagSet", path, decodeTagSet);
  if (tagSet) s.tagSet = tagSet;
  return s;
}

function decodeIncluded(v: unknown, path: string): Included {
  const o = obj(v, path);
  const inc = new Included();
  for (const [d, e] of Object.entries(o)) {
    if (!isDeviceID(d)) fail(path, `bad device id ${d}`);
    const eo = obj(e, `${path}.${d}`);
    const upTo = reqWith(eo, "upTo", `${path}.${d}`, int);
    const extra = reqWith(eo, "extra", `${path}.${d}`, (a, p) => arrayOf(a, p, int));
    if (upTo > maxSeq || extra.some((x) => x > maxSeq)) fail(`${path}.${d}`, "seq out of range");
    inc.entries.set(d, normalizeEntry(upTo, extra));
  }
  return inc;
}

function decodeMetaChange(o: JSONObject, path: string): MetaChange {
  const field = reqWith(o, "field", path, str);
  switch (field) {
    case "title": return { field, value: reqWith(o, "value", path, str) };
    case "tags": return { field, value: reqWith(o, "value", path, strings) };
    case "notebook": return { field, value: optWith(o, "value", path, str) };
    case "favorite": return { field, value: reqWith(o, "value", path, bool) };
    case "paper": return { field, value: reqWith(o, "value", path, decodePaper) };
    case "pageSize": return { field, value: reqWith(o, "value", path, decodePageSize) };
    case "lang": {
      const value = optWith(o, "value", path, str);
      if (value !== undefined && validLanguage(value) !== value) fail(`${path}.value`, "lang is not a BCP 47 tag");
      return { field, value };
    }
    case "markersBehindText": return { field, value: reqWith(o, "value", path, bool) };
    case "recognized": return { field, value: optWith(o, "value", path, recognitionRecord) };
    default: fail(`${path}.field`, `unknown meta field ${field}`);
  }
}

export function decodeOp(v: unknown, path: string, budget: Budget): Op {
  const o = obj(v, path);
  const op = reqWith(o, "op", path, str);
  switch (op) {
    case "addStroke":
      return { op, page: reqWith(o, "page", path, uuid), stroke: reqWith(o, "stroke", path, decodeStroke) };
    case "removeStroke":
      return { op, page: reqWith(o, "page", path, uuid), strokeId: reqWith(o, "strokeId", path, uuid) };
    case "addPage":
      return { op, page: reqWith(o, "page", path, (p, q) => decodePage(p, q, budget)) };
    case "removePage":
      return { op, pageId: reqWith(o, "pageId", path, uuid) };
    case "setPageOrder":
      return { op, pageId: reqWith(o, "pageId", path, uuid), order: reqWith(o, "order", path, str) };
    case "setPageRecognition":
      return { op, pageId: reqWith(o, "pageId", path, uuid), recognition: optWith(o, "recognition", path, decodeRecognition) };
    case "setPagePaper":
      return { op, pageId: reqWith(o, "pageId", path, uuid), paper: optWith(o, "paper", path, decodePaper) };
    case "setMeta":
      return { op, change: decodeMetaChange(o, path) };
    case "addTag":
      return { op, tag: reqWith(o, "tag", path, str) };
    case "removeTag":
      return {
        op, tag: reqWith(o, "tag", path, str),
        observed: reqWith(o, "observed", path, (a, p) => arrayOf(a, p, tagOrigin)),
      };
    case "deleteNote":
    case "restoreNote":
      return { op };
    case "addItem": {
      const page = reqWith(o, "page", path, uuid);
      return { op, page, item: reqWith(o, "item", path, (i, p) => decodeItem(i, p, budget)) };
    }
    case "removeItem":
      return { op, page: reqWith(o, "page", path, uuid), itemId: reqWith(o, "itemId", path, uuid) };
    case "setItem": {
      const field = reqWith(o, "field", path, str);
      const page = reqWith(o, "page", path, uuid);
      const itemId = reqWith(o, "itemId", path, uuid);
      const value = opt(o, "value") ?? null;
      checkItemChange(field, value, `${path}.value`, budget);
      return { op, page, itemId, field, value };
    }
    case "addRecording":
      return { op, recording: reqWith(o, "recording", path, (r, p) => decodeRecording(r, p, budget)) };
    case "removeRecording":
      return { op, recordingId: reqWith(o, "recordingId", path, uuid) };
    case "setRecording": {
      const field = reqWith(o, "field", path, str);
      const recordingId = reqWith(o, "recordingId", path, uuid);
      const value = opt(o, "value") ?? null;
      checkRecordingChange(field, value, `${path}.value`, budget);
      return { op, recordingId, field, value };
    }
    default:
      // Fail closed on an op this reader does not know, outside a newer revision (format.md §7.4).
      fail(`${path}.op`, `unknown op ${op}`);
  }
}

/** The name a skipped op is counted under (§7.4): its `op`, `setMeta.<field>` and the like. */
function skippedOpName(v: unknown): string {
  if (v === null || typeof v !== "object" || Array.isArray(v)) return "?";
  const o = v as JSONObject;
  if (typeof o.op !== "string") return "?";
  if ((o.op === "setMeta" || o.op === "setItem" || o.op === "setRecording") && typeof o.field === "string") {
    return `${o.op}.${o.field}`;
  }
  return o.op;
}

/** Decodes a revision's JSON (already parsed). */
export function decodeRevision(v: unknown): Revision {
  const path = "$";
  const o = obj(v, path);
  const budget = new Budget();
  const noteId = reqWith(o, "noteId", path, uuid);
  const device = reqWith(o, "device", path, deviceID);
  const seq = reqWith(o, "seq", path, int);
  if (seq < 1 || seq > maxSeq) fail(`${path}.seq`, `seq must be 1...${maxSeq}`);
  const r = {
    noteId, device, seq,
    hlc: reqWith(o, "hlc", path, hlc),
    wall: reqWith(o, "wall", path, date),
    app: reqWith(o, "app", path, str),
  };
  // Version markers (format.md §7.1): a newer revision decodes leniently (§7.4).
  let isNewer: boolean;
  try {
    isNewer = revisionMarkersNewer(o);
  } catch (e) {
    fail(`${path}.format`, e instanceof Error ? e.message : String(e));
  }
  let lenient: Lenient | undefined;
  if (isNewer) {
    const newer = emptyNewer();
    newer.revisions = 1;
    if (typeof o.format === "string" && isNewerFormat(o.format)) countName(newer.formats, o.format);
    if (Array.isArray(o.features)) {
      for (const f of o.features as string[]) if (!knownFeatures.has(f)) countName(newer.features, f);
    }
    lenient = { newer };
  }
  const type = reqWith(o, "type", path, str);
  let body: RevisionBody;
  if (type === "delta") {
    body = {
      type, ops: reqWith(o, "ops", path, (a, p) => {
        if (!lenient) return arrayOf(a, p, (e, q) => decodeOp(e, q, budget));
        const ops: Op[] = [];
        arr(a, p).forEach((e, i) => {
          try {
            ops.push(decodeOp(e, `${p}[${i}]`, budget));
          } catch (err) {
            if (!(err instanceof DecodeError)) throw err;
            countName(lenient.newer.skippedOps, skippedOpName(e));
          }
        });
        return ops;
      }),
    };
  } else if (type === "snapshot") {
    body = {
      type,
      included: reqWith(o, "included", path, decodeIncluded),
      state: reqWith(o, "state", path, (s, p) => decodeState(s, p, budget, lenient)),
    };
  } else {
    fail(`${path}.type`, `unknown revision type ${type}`);
  }
  const rev: Revision = { ...r, body };
  if (lenient) rev.newer = lenient.newer;
  return rev;
}

export function isDecodeError(e: unknown): e is DecodeError {
  return e instanceof DecodeError;
}

// MARK: - Encoding (Swift `InkJSON.encoder`, keys sorted by the caller)

function encodeStroke(s: Stroke): JSONObject {
  const pts: number[][] = [];
  for (let i = 0; i < s.points.length; i += pointStride) {
    pts.push(Array.from(s.points.subarray(i, i + pointStride), round3));
  }
  const o: JSONObject = { id: s.id, ink: { tool: s.ink.tool, color: s.ink.color, width: s.ink.width }, points: pts };
  if (s.transform && !isIdentity(s.transform)) o.transform = s.transform.map(round3);
  if (s.parent !== undefined) o.parent = s.parent;
  if (s.origin !== undefined) o.origin = s.origin;
  if (s.rec) o.rec = { id: s.rec.id, at: round3(s.rec.at) };
  if (s.replaces) o.replaces = true;
  return o;
}

export function isIdentity(t: number[]): boolean {
  return t[0] === 1 && t[1] === 0 && t[2] === 0 && t[3] === 1 && t[4] === 0 && t[5] === 0;
}

export function encodePaper(p: Paper): JSONObject {
  const o: JSONObject = { kind: p.kindName, spacing: p.spacing, background: p.background, lineColor: p.lineColor };
  const d = defaultPaper(paperKind(p));
  for (const f of ["lineWidth", "dotRadius", "marginLeft", "marginTop", "cueWidth", "summaryHeight",
    "staffSpacing", "staffGap", "marginColor"] as const) {
    if (p[f] !== d[f]) o[f] = p[f];
  }
  return o;
}

function encodeRecognition(r: Recognition): JSONObject {
  const o: JSONObject = { engine: r.engine, text: r.text, words: r.words.map((w) => ({ t: w.t, box: w.box.map(round3) })) };
  if (r.basis !== undefined) o.basis = r.basis;
  return o;
}

function encodePage(p: Page): JSONObject {
  const o: JSONObject = { id: p.id, order: p.order, strokes: p.strokes.map(encodeStroke) };
  if (p.orderClock !== undefined) o.orderClock = p.orderClock;
  if (p.origin !== undefined) o.origin = p.origin;
  if (p.recognition) o.recognition = encodeRecognition(p.recognition);
  if (p.recognitionClock !== undefined) o.recognitionClock = p.recognitionClock;
  if (p.parent !== undefined) o.parent = p.parent;
  if (p.paper) o.paper = encodePaper(p.paper);
  if (p.paperClock !== undefined) o.paperClock = p.paperClock;
  if (p.items.length > 0) o.items = p.items;
  return o;
}

/**
 * A reconstructed note as `sempere export --format json` writes it. Items and
 * recordings are emitted as the reducer holds them (validated JSON; writers
 * already round numbers to 3 decimals).
 */
export function encodeState(s: NoteState, formatDate: (ms: number) => string): JSONObject {
  const m = s.meta;
  const meta: JSONObject = {
    title: m.title, tags: m.tags, favorite: m.favorite, created: formatDate(m.created),
    paper: encodePaper(m.paper), pageSize: { ...m.pageSize },
  };
  if (m.notebook !== undefined) meta.notebook = m.notebook;
  if (m.lang !== undefined) meta.lang = m.lang;
  if (m.markersBehindText === true) meta.markersBehindText = true;
  if (m.recognized !== undefined) {
    meta.recognized = { at: formatDate(m.recognized.at), pages: m.recognized.pages, read: m.recognized.read };
  }
  const o: JSONObject = { deleted: s.deleted, meta, pages: s.pages.map(encodePage) };
  if (s.clocks && Object.keys(s.clocks).length > 0) o.clocks = s.clocks;
  const t = s.tombstones;
  if (t && (t.strokes.length || t.pages.length || t.items.length || t.recordings.length || t.lineage.length
    || t.superseded.length)) {
    const to: JSONObject = { strokes: t.strokes, pages: t.pages };
    if (t.items.length) to.items = t.items;
    if (t.recordings.length) to.recordings = t.recordings;
    if (t.lineage.length) to.lineage = t.lineage.map((l) => ({ stroke: l.stroke, parent: l.parent, by: l.by }));
    if (t.superseded.length) to.superseded = t.superseded;
    o.tombstones = to;
  }
  if (s.tagSet) {
    const ts: JSONObject = {
      instances: s.tagSet.instances.map((i) => ({ tag: i.tag, origin: originString(i.origin) })),
      removed: s.tagSet.removed.map((r) => ({ key: r.key, origin: originString(r.origin) })),
    };
    if (s.tagSet.legacy) ts.legacy = s.tagSet.legacy;
    o.tagSet = ts;
  }
  if (s.recordings.length > 0) o.recordings = s.recordings;
  return o;
}

/** Re-exported for callers that only need the revision kind type. */
export type { RevisionKind };
