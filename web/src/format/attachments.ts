// Attachment items and recordings (format.md §8). The merge does not apply
// them yet (as in Swift, task A1), but a revision holding an invalid one is
// rejected like any undecodable revision (§8.2.1, §8.2.2, §8.3.1). The rules
// are those of Sources/Sempere/Attachments.swift and JSONValue.swift.

import { type JSONObject, arr, bool, fail, int, isObject, num, obj, opt, optWith, reqWith, round3, str, uuid } from "./json.ts";
import { parseRFC3339 } from "./rfc3339.ts";

/** Most unknown-field values one file may hold (format.md §9, `JSONValue.maxValues`). */
export const maxUnknownValues = 16_384;
/** Deepest an unknown field may sit, from the document root (`JSONValue.maxDepth`). */
export const maxUnknownDepth = 24;

/** The per-file budget of unknown-field values. */
export class Budget {
  remaining = maxUnknownValues;
}

// MARK: - Unknown fields (JSONValue, §7, §9)

/**
 * The depth of `path` from the document root, as the length of Swift's
 * `codingPath`: `$` is the root (0), and each `.key` and each `[i]` adds one
 * level, so `$.ops[3].item` is 3 and `$.state.pages[0].items[2]` is 5. The
 * callers build these paths from the format's fixed key names, which hold no
 * `.` or `[`.
 */
export function pathDepth(path: string): number {
  return path.match(/\.[^.[]*|\[\d+\]/g)?.length ?? 0;
}

/**
 * Decodes `v` as Swift's `JSONValue` at coding-path depth `depth`: each value
 * (nested ones included) takes one from `budget`, and one deeper than
 * `maxUnknownDepth` fails. A non-finite number fails as Swift's `Double`
 * decode does.
 */
function jsonValue(v: unknown, path: string, depth: number, budget: Budget): void {
  if (depth > maxUnknownDepth) fail(path, `unknown field nested deeper than ${maxUnknownDepth}`);
  if (budget.remaining <= 0) fail(path, `more than ${maxUnknownValues} unknown-field values`);
  budget.remaining -= 1;
  if (v === null || typeof v === "string" || typeof v === "boolean") return;
  if (typeof v === "number") {
    if (!Number.isFinite(v)) fail(path, "number out of range");
    return;
  }
  if (Array.isArray(v)) {
    v.forEach((e, i) => jsonValue(e, `${path}[${i}]`, depth + 1, budget));
    return;
  }
  if (isObject(v)) {
    for (const [k, e] of Object.entries(v)) jsonValue(e, `${path}.${k}`, depth + 1, budget);
    return;
  }
  fail(path, "not a JSON value");
}

/** Decodes every key of `o` not in `known` as a `JSONValue` (Swift `extra(excluding:)`). */
function extra(o: JSONObject, known: ReadonlySet<string>, path: string, depth: number, budget: Budget): void {
  for (const [k, v] of Object.entries(o)) {
    if (!known.has(k)) jsonValue(v, `${path}.${k}`, depth + 1, budget);
  }
}

/** Where an object sits: its path, its coding-path depth and the file's budget. */
interface Ctx {
  depth: number;
  budget: Budget;
}

function child(c: Ctx): Ctx {
  return { depth: c.depth + 1, budget: c.budget };
}

// MARK: - Small types

/** `[x, y, w, h]`: exactly four finite numbers (Swift `Rect`, `isAtEnd`). */
function rect(v: unknown, path: string): { w: number; h: number } {
  const a = exactNumbers(v, path, 4);
  return { w: a[2] ?? 0, h: a[3] ?? 0 };
}

/** `[w, h]`: exactly two finite numbers (Swift `Size`). */
function size(v: unknown, path: string): { w: number; h: number } {
  const a = exactNumbers(v, path, 2);
  return { w: a[0] ?? 0, h: a[1] ?? 0 };
}

function exactNumbers(v: unknown, path: string, count: number): number[] {
  const a = arr(v, path);
  if (a.length !== count) fail(path, `expected ${count} numbers`);
  return a.map((e, i) => num(e, `${path}[${i}]`));
}

/** Width and height positive as written, after rounding (`hasPositiveSize`, `isPositive`). */
function positive(w: number, h: number): boolean {
  return round3(w) > 0 && round3(h) > 0;
}

/**
 * Swift's `Color(hex:)`: an optional `#`, then 6 or 8 characters that
 * `UInt32(_, radix: 16)` parses (a sign is tolerated; `-` only for zero).
 * Kept local: `parseColor` lives in model.ts, which imports this file.
 */
function color(v: unknown, path: string): string {
  const s = str(v, path);
  const body = s.startsWith("#") ? s.slice(1) : s;
  const count = [...body].length;
  let digits = body;
  if (digits.startsWith("+")) digits = digits.slice(1);
  else if (digits.startsWith("-") && /^-0+$/.test(digits)) digits = "0";
  if ((count !== 6 && count !== 8) || !/^[0-9a-fA-F]+$/.test(digits)) fail(path, "bad colour");
  return s;
}

function date(v: unknown, path: string): number {
  const ms = parseRFC3339(str(v, path));
  if (ms === undefined) fail(path, "bad date");
  return ms;
}

/** `[String: String]` (`clocks`). */
function stringMap(v: unknown, path: string): JSONObject {
  const o = obj(v, path);
  for (const [k, x] of Object.entries(o)) str(x, `${path}.${k}`);
  return o;
}

/** `{"id", "at"}` (§8.3.3); other keys are ignored, as Swift's `CodingKeys` do. */
function recordingLink(v: unknown, path: string): void {
  const o = obj(v, path);
  reqWith(o, "id", path, uuid);
  reqWith(o, "at", path, num);
}

// MARK: - Blobs (§8.1.1)

/** Largest blob content (§8.4): 1 GiB. */
const maxBlobSize = 2 ** 30;
const blobKeys: ReadonlySet<string> = new Set(["sha256", "size", "type"]);

function blobRef(v: unknown, path: string, c: Ctx): JSONObject {
  const o = obj(v, path);
  const sha = reqWith(o, "sha256", path, str);
  const n = reqWith(o, "size", path, int);
  reqWith(o, "type", path, str);
  extra(o, blobKeys, path, c.depth, c.budget);
  if (!/^[0-9a-f]{64}$/.test(sha) || n < 0 || n > maxBlobSize) fail(path, "bad blob reference (sha256 or size)");
  return o;
}

// MARK: - Text (§8.2.4)

const textLimits = { utf8Bytes: 65_536, runs: 1_000, breaks: 10_000, size: 1_000 };
const runKeys: ReadonlySet<string> = new Set(["t", "b", "i", "u", "s", "color", "size", "lang", "font"]);
const textKeys: ReadonlySet<string> = new Set(["font", "family", "size", "color", "align", "dir", "lang", "runs", "breaks",
  "markup", "layout", "math"]);
const layoutKeys: ReadonlySet<string> = new Set(["of", "breaks"]);
/** Most typeset formulas of one Markdown box (Swift `TextContent.Limits.formulas`). */
const maxFormulas = 1000;

function isValidTextSize(s: number): boolean {
  const r = round3(s);
  return r > 0 && r <= textLimits.size;
}

/** §8.2.4: no C0 controls but `\n` and `\t`. */
function isValidRunText(t: string): boolean {
  for (let i = 0; i < t.length; i++) {
    const u = t.charCodeAt(i);
    if (u < 0x20 && u !== 0x0a && u !== 0x09) return false;
  }
  return true;
}

function utf8Length(s: string): number {
  let n = 0;
  for (const ch of s) {
    const cp = ch.codePointAt(0) ?? 0;
    n += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
  }
  return n;
}

function textRun(v: unknown, path: string, c: Ctx): string {
  const o = obj(v, path);
  const t = reqWith(o, "t", path, str);
  for (const k of ["b", "i", "u", "s"]) optWith(o, k, path, bool);
  optWith(o, "color", path, color);
  const sz = optWith(o, "size", path, num);
  optWith(o, "lang", path, str);
  optWith(o, "font", path, str);
  extra(o, runKeys, path, c.depth, c.budget);
  if (sz !== undefined && !isValidTextSize(sz)) fail(path, "run size out of range");
  if (!isValidRunText(t)) fail(path, "run text holds a control character");
  return t;
}

/** An array of at most `max` elements, counted before any is decoded (Swift `decodeBounded`). */
function bounded<T>(v: unknown, path: string, max: number, f: (e: unknown, path: string) => T): T[] {
  const a = arr(v, path);
  if (a.length > max) fail(path, `more than ${max} elements`);
  return a.map((e, i) => f(e, `${path}[${i}]`));
}

function textContent(v: unknown, path: string, c: Ctx): JSONObject {
  const o = obj(v, path);
  reqWith(o, "font", path, str);
  optWith(o, "family", path, str);
  const sz = reqWith(o, "size", path, num);
  reqWith(o, "color", path, color);
  optWith(o, "align", path, str);
  optWith(o, "dir", path, str);
  optWith(o, "lang", path, str);
  // Runs sit two levels below the content (`runs`, index).
  const runCtx = child(child(c));
  const runs = reqWith(o, "runs", path, (r, p) => bounded(r, p, textLimits.runs, (e, q) => textRun(e, q, runCtx)));
  optWith(o, "breaks", path, (b, p) => bounded(b, p, textLimits.breaks, int));
  // Markdown boxes (§8.2.4 "Markdown text"): Swift `RenderedLayout`, `TypesetFormula`.
  optWith(o, "markup", path, str);
  optWith(o, "layout", path, (l, p) => renderedLayout(l, p, child(c)));
  optWith(o, "math", path, (m, p) => bounded(m, p, maxFormulas, (e, q) => typesetFormula(e, q, child(child(c)))));
  extra(o, textKeys, path, c.depth, c.budget);
  // `limitViolation`; the run and break counts were checked above.
  if (!isValidTextSize(sz)) fail(path, "text size out of range");
  if (utf8Length(runs.join("")) > textLimits.utf8Bytes) fail(path, `text longer than ${textLimits.utf8Bytes} bytes`);
  return o;
}

/** A Markdown box's `layout` (Swift `RenderedLayout`). */
function renderedLayout(v: unknown, path: string, c: Ctx): JSONObject {
  const o = obj(v, path);
  const of = reqWith(o, "of", path, str);
  const breaks = reqWith(o, "breaks", path, (b, p) => bounded(b, p, textLimits.breaks, int));
  extra(o, layoutKeys, path, c.depth, c.budget);
  if (!/^[0-9a-f]{8}$/.test(of)) fail(path, "layout hash is not 8 lowercase hexadecimal digits");
  let last = -1;
  for (const b of breaks) {
    if (!(b > last)) fail(path, "layout breaks are not strictly increasing");
    last = b;
  }
  return o;
}

/** A Markdown box's typeset formula (Swift `TypesetFormula`): a math value with its render and a depth. */
function typesetFormula(v: unknown, path: string, c: Ctx): JSONObject {
  const o = mathContent(v, path, c);
  const depth = o.depth;
  if (typeof depth !== "number") fail(path, "typeset formula without a depth");
  const rs = o.renderSize;
  if (o.render === undefined || !Array.isArray(rs)) fail(path, "typeset formula without a render");
  const h = Array.isArray(rs) && typeof rs[1] === "number" ? rs[1] : 0;
  const d = typeof depth === "number" ? depth : NaN;
  if (!Number.isFinite(d) || Math.round(d * 1000) / 1000 < 0 || Math.round(d * 1000) / 1000 > Math.round(h * 1000) / 1000) {
    fail(path, "formula depth out of range");
  }
  return o;
}

// MARK: - Math (§8.2.8)

/** Most UTF-8 bytes of a LaTeX source (Swift `MathSource.maxBytes`). */
export const mathMaxBytes = 8_192;
const mathKeys: ReadonlySet<string> = new Set(["latex", "display", "size", "color", "render", "renderSize", "engine"]);

/** The media type's essence is `application/pdf` (Swift `BlobKind(mediaType:) == .pdf`). */
function isPDFType(type: string): boolean {
  return (type.split(";")[0] ?? "").trim().replace(/[A-Z]/g, (ch) => ch.toLowerCase()) === "application/pdf";
}

/** A math item's `math` value (Swift `MathContent`): source, style, size, colour, optional render. */
function mathContent(v: unknown, path: string, c: Ctx): JSONObject {
  const o = obj(v, path);
  const latex = reqWith(o, "latex", path, str);
  reqWith(o, "display", path, bool);
  const sz = reqWith(o, "size", path, num);
  reqWith(o, "color", path, color);
  const render = optWith(o, "render", path, (b, p) => blobRef(b, p, child(c)));
  const renderSize = optWith(o, "renderSize", path, size);
  optWith(o, "engine", path, str);
  extra(o, mathKeys, path, c.depth, c.budget);
  // `MathContent.validationError`.
  if (utf8Length(latex) > mathMaxBytes) fail(path, `LaTeX source longer than ${mathMaxBytes} bytes`);
  if (!isValidRunText(latex)) fail(path, "LaTeX source holds a control character");
  if (!isValidTextSize(sz)) fail(path, "math size out of range");
  if ((render === undefined) !== (renderSize === undefined)) fail(path, "math render and renderSize go together");
  if (render && !isPDFType(String(render.type))) fail(path, "math render is not a PDF");
  if (renderSize && !positive(renderSize.w, renderSize.h)) fail(path, "math renderSize must be positive");
  return o;
}

// MARK: - Items (§8.2)

/** The fields every kind has (§8.2.1). */
export const commonItemFields = ["id", "kind", "layer", "frame", "rotation", "z", "parent", "rec", "origin", "clocks"];

/** The fields of a defined kind beyond the common ones; none for others. */
export function kindFields(kind: string): string[] {
  switch (kind) {
    case "text": return ["text"];
    case "image": return ["blob", "pixelSize", "orientation", "crop"];
    case "pdfPage": return ["blob", "pageIndex", "pageSize", "crop"];
    case "video": return ["blob", "pixelSize", "duration", "videoRotation", "codec", "poster"];
    case "math": return ["math"];
    case "audio": return ["recording"];
    default: return [];
  }
}

/** Fields `setItem` may not name (§8.2.2): immutable fields of every kind, and `origin`, `clocks`. */
export const immutableItemFields: ReadonlySet<string> = new Set(["id", "kind", "layer", "parent", "rec", "origin", "clocks",
  "blob", "pixelSize", "orientation", "pageIndex", "pageSize", "duration", "videoRotation", "codec", "recording"]);

/** The `videoRotation` values §8.2.7 allows. */
const videoRotations: ReadonlySet<number> = new Set([0, 90, 180, 270]);

/** Decodes and validates a placed item; returns it as parsed JSON. */
export function decodeItem(v: unknown, path: string, budget: Budget): JSONObject {
  const c: Ctx = { depth: pathDepth(path), budget };
  const o = obj(v, path);
  reqWith(o, "id", path, uuid);
  const kind = reqWith(o, "kind", path, str);
  // `ItemLayer` reads any value as a `JSONValue` (so it is bounded like an
  // unknown field) and never fails otherwise: a non-conforming one is 100.
  const layer = opt(o, "layer");
  if (layer !== undefined) jsonValue(layer, `${path}.layer`, c.depth + 1, budget);
  const frame = reqWith(o, "frame", path, rect);
  optWith(o, "rotation", path, num);
  reqWith(o, "z", path, str);
  optWith(o, "parent", path, uuid);
  optWith(o, "rec", path, recordingLink);
  optWith(o, "origin", path, str);
  optWith(o, "clocks", path, stringMap);
  const mine = kindFields(kind);
  const has = (f: string) => mine.includes(f);
  const fc = child(c);
  const text = has("text") ? optWith(o, "text", path, (t, p) => textContent(t, p, fc)) : undefined;
  const blob = has("blob") ? optWith(o, "blob", path, (b, p) => blobRef(b, p, fc)) : undefined;
  const pixelSize = has("pixelSize") ? optWith(o, "pixelSize", path, size) : undefined;
  const orientation = has("orientation") ? optWith(o, "orientation", path, int) : undefined;
  const crop = has("crop") ? optWith(o, "crop", path, rect) : undefined;
  const pageIndex = has("pageIndex") ? optWith(o, "pageIndex", path, int) : undefined;
  const pageSize = has("pageSize") ? optWith(o, "pageSize", path, size) : undefined;
  const duration = has("duration") ? optWith(o, "duration", path, num) : undefined;
  const videoRotation = has("videoRotation") ? optWith(o, "videoRotation", path, int) : undefined;
  if (has("codec")) optWith(o, "codec", path, str);
  // `poster: null` is the reset register (absent).
  if (has("poster")) optWith(o, "poster", path, (b, p) => blobRef(b, p, fc));
  const math = has("math") ? optWith(o, "math", path, (m, p) => mathContent(m, p, fc)) : undefined;
  const recording = has("recording") ? optWith(o, "recording", path, uuid) : undefined;
  extra(o, new Set([...commonItemFields, ...mine]), path, c.depth, budget);

  // `Item.validationError` (§8.2.1, §8.2.4–§8.2.9).
  if (!positive(frame.w, frame.h)) fail(path, "frame width and height must be positive");
  if (crop && !positive(crop.w, crop.h)) fail(path, "crop width and height must be positive");
  switch (kind) {
    case "text":
      if (!text) fail(path, "text item without text");
      break;
    case "image":
      if (!blob || !pixelSize) fail(path, "image item without blob or pixelSize");
      if (!positive(pixelSize.w, pixelSize.h)) fail(path, "pixelSize must be positive");
      if (orientation !== undefined && (orientation < 1 || orientation > 8)) fail(path, "orientation must be 1...8");
      break;
    case "pdfPage":
      if (!blob || pageIndex === undefined || !pageSize) fail(path, "pdfPage item without blob, pageIndex or pageSize");
      if (pageIndex < 0) fail(path, "pageIndex must not be negative");
      if (!positive(pageSize.w, pageSize.h)) fail(path, "pageSize must be positive");
      break;
    case "video":
      if (!blob || !pixelSize || duration === undefined) fail(path, "video item without blob, pixelSize or duration");
      if (!positive(pixelSize.w, pixelSize.h)) fail(path, "pixelSize must be positive");
      if (!(Number.isFinite(duration) && duration >= 0)) fail(path, "duration must be finite and not negative");
      if (videoRotation !== undefined && !videoRotations.has(videoRotation)) fail(path, "videoRotation must be 0, 90, 180 or 270");
      break;
    case "math":
      if (!math) fail(path, "math item without math");
      break;
    case "audio":
      if (recording === undefined) fail(path, "audio item without recording");
      break;
  }
  return o;
}

/**
 * Swift decodes a `setItem` / `setRecording` `value` twice: as a `JSONValue`
 * in the revision (depth from the revision root, the file's budget), then,
 * for a typed register, from that value re-encoded with a fresh decoder
 * (fresh budget, depth counted from the value). Without `budget` the first
 * pass gets a fresh one.
 */
function changeValue(value: unknown, path: string, budget: Budget | undefined): Ctx {
  if (value !== null) jsonValue(value, path, pathDepth(path), budget ?? new Budget());
  return { depth: 0, budget: new Budget() };
}

/** Validates a `setItem` change (§8.2.2); `path` is the value's, e.g. `$.ops[3].value`. */
export function checkItemChange(field: string, value: unknown, path: string, budget?: Budget): void {
  const c = changeValue(value, path, budget);
  if (immutableItemFields.has(field)) fail(path, `immutable field ${field}`);
  switch (field) {
    case "frame": {
      if (value === null) fail(path, "frame cannot be null");
      const r = rect(value, path);
      if (!positive(r.w, r.h)) fail(path, "invalid frame");
      return;
    }
    case "rotation":
      if (value !== null) num(value, path);
      return;
    case "z":
      if (value === null) fail(path, "z cannot be null");
      str(value, path);
      return;
    case "text":
      if (value === null) fail(path, "text cannot be null");
      textContent(value, path, c);
      return;
    case "math":
      if (value === null) fail(path, "math cannot be null");
      mathContent(value, path, c);
      return;
    case "crop": {
      if (value === null) return;
      const r = rect(value, path);
      if (!positive(r.w, r.h)) fail(path, "invalid crop");
      return;
    }
    case "poster":
      if (value !== null) blobRef(value, path, c);
      return;
    default:
      // Any other field is a register holding any value (§7).
      return;
  }
}

// MARK: - Recordings (§8.3.1)

export const recordingFields = ["id", "blob", "started", "duration", "codec", "sampleRate", "channels", "bitRate", "title",
  "transcript", "parent", "origin", "clocks"];
const recordingKeys: ReadonlySet<string> = new Set(recordingFields);
/** All but the registers `title` and `transcript`. */
const immutableRecordingFields: ReadonlySet<string> = new Set(recordingFields.filter((f) => f !== "title" && f !== "transcript"));

/** Decodes and validates a recording; returns it as parsed JSON. */
export function decodeRecording(v: unknown, path: string, budget: Budget): JSONObject {
  const c: Ctx = { depth: pathDepth(path), budget };
  const fc = child(c);
  const o = obj(v, path);
  reqWith(o, "id", path, uuid);
  reqWith(o, "blob", path, (b, p) => blobRef(b, p, fc));
  reqWith(o, "started", path, date);
  optWith(o, "duration", path, num);
  optWith(o, "codec", path, str);
  for (const k of ["sampleRate", "channels", "bitRate"]) optWith(o, k, path, int);
  optWith(o, "title", path, str);
  optWith(o, "transcript", path, (b, p) => blobRef(b, p, fc));
  optWith(o, "parent", path, uuid);
  optWith(o, "origin", path, str);
  optWith(o, "clocks", path, stringMap);
  extra(o, recordingKeys, path, c.depth, budget);
  return o;
}

/** Validates a `setRecording` change (§8.3.1); `path` is the value's. */
export function checkRecordingChange(field: string, value: unknown, path: string, budget?: Budget): void {
  const c = changeValue(value, path, budget);
  if (immutableRecordingFields.has(field)) fail(path, `immutable field ${field}`);
  if (value === null) return;
  if (field === "title") str(value, path);
  else if (field === "transcript") blobRef(value, path, c);
}
