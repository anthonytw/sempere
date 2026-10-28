// Registers of placed items and recordings (format.md §8.2.2, §8.3.1), a port
// of Sources/Sempere/AttachmentRegisters.swift. Items and recordings are kept
// as validated JSON objects; every field is a register (merged LWW per field)
// or immutable (set once by the add). Fields a reader does not know are
// registers (§7).

import { cmpStr, cmpUTF8 } from "./ids.ts";
import { textOf } from "./markdown.ts";
import type { JSONObject } from "./json.ts";
import { commonItemFields, immutableItemFields, kindFields, recordingFields } from "./attachments.ts";
import { parseRFC3339 } from "./rfc3339.ts";

const common: ReadonlySet<string> = new Set(commonItemFields);
const knownRecording: ReadonlySet<string> = new Set(recordingFields);

/**
 * The item's registers, field → value (`null` for an absent optional one):
 * `frame`, `rotation`, `z`, the kind's `text`, `crop` or `math`, and every unknown
 * field except those named like an immutable field of some kind.
 */
export function itemRegisters(item: JSONObject): Map<string, unknown> {
  const mine = kindFields(String(item.kind));
  const r = new Map<string, unknown>([["frame", item.frame], ["rotation", item.rotation ?? null], ["z", item.z]]);
  if (mine.includes("text") && item.text !== undefined) r.set("text", item.text);
  if (mine.includes("crop")) r.set("crop", item.crop ?? null);
  if (mine.includes("poster")) r.set("poster", item.poster ?? null);
  if (mine.includes("math") && item.math !== undefined) r.set("math", item.math);
  for (const [k, v] of Object.entries(item)) {
    if (!common.has(k) && !mine.includes(k) && !immutableItemFields.has(k)) r.set(k, v);
  }
  return r;
}

/**
 * Sets one register: `null` resets `rotation` and the kind's own `crop` to
 * absent; any other field (one of another kind included) keeps the value,
 * `null` too (§8.2.1, §8.2.2).
 */
export function applyItemRegister(item: JSONObject, field: string, value: unknown): void {
  const mine = kindFields(String(item.kind));
  if (field === "rotation" || ((field === "crop" || field === "poster") && mine.includes(field))) {
    if (value === null) delete item[field];
    else item[field] = value;
  } else if (common.has(field) || mine.includes(field)) {
    if (field === "frame" || field === "z" || field === "text" || field === "math") item[field] = value;
  } else if (!immutableItemFields.has(field)) {
    item[field] = value;
  }
}

/** The recording's registers: `title`, `transcript` (`null` when absent) and every unknown field. */
export function recordingRegisters(rec: JSONObject): Map<string, unknown> {
  const r = new Map<string, unknown>([["title", rec.title ?? null], ["transcript", rec.transcript ?? null]]);
  for (const [k, v] of Object.entries(rec)) if (!knownRecording.has(k)) r.set(k, v);
  return r;
}

export function applyRecordingRegister(rec: JSONObject, field: string, value: unknown): void {
  if (field === "title" || field === "transcript") {
    if (value === null) delete rec[field];
    else rec[field] = value;
  } else if (!knownRecording.has(field)) {
    rec[field] = value;
  }
}

/** An item's layer as readers order it: an integer 0 … 65 535, anything else 100 (§8.2.1). */
export function itemLayer(item: JSONObject): number {
  const l = item.layer;
  return typeof l === "number" && Number.isInteger(l) && l >= 0 && l <= 65_535 ? l : 100;
}

/** Drawing order (§8.2.3): `(layer, z, id)`, `z` byte-wise (canonically equal keys tie, as in Swift). */
export function cmpItems(l: JSONObject, r: JSONObject): number {
  const ll = itemLayer(l), rl = itemLayer(r);
  if (ll !== rl) return ll < rl ? -1 : 1;
  const lz = String(l.z), rz = String(r.z);
  return (lz.normalize("NFC") === rz.normalize("NFC") ? 0 : cmpUTF8(lz, rz)) || cmpStr(String(l.id), String(r.id));
}

/** Snapshot order of recordings (§5.4): `(started, id)`. */
export function cmpRecordings(l: JSONObject, r: JSONObject): number {
  const ls = parseRFC3339(String(l.started)) ?? 0, rs = parseRFC3339(String(r.started)) ?? 0;
  return (ls < rs ? -1 : ls > rs ? 1 : 0) || cmpStr(String(l.id), String(r.id));
}

/** A math item's LaTeX source (§8.2.8); "" for anything else. */
export function itemLatex(item: JSONObject): string {
  const m = item.math as { latex?: unknown } | undefined;
  return item.kind === "math" && typeof m?.latex === "string" ? m.latex : "";
}

/** A text box's text as search sees it: every run's `t`, concatenated (§8.2.4); a Markdown box's plain text (§8.5.4). */
export function itemText(item: JSONObject): string {
  const text = item.text as JSONObject | undefined;
  return text && typeof text === "object" ? textOf(text) : "";
}
