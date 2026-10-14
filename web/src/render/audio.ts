// Audio items (format.md §8.2.9): a recording of the note shown on a page as
// a card — fill and outline, a microphone icon, and a label with the title,
// the duration and the transcript, clipped to the card. Mirrors
// Sources/Sempere/AudioItems.swift (`AudioCard`) and
// Sources/SempereRender/AudioCards.swift so the cross-check against the CLI's
// SVG compares the same elements.

import type { JSONObject } from "../format/json.ts";
import type { Transcript } from "../format/transcript.ts";
import { type Rect, apply, rotate } from "./items.ts";
import type { DrawCommand, Paint, Point } from "./primitives.ts";
import type { TextContent, TextLayout } from "./text.ts";

export const audioCard = {
  fill: "#F1F3F4FF",
  outline: "#DADCE0FF",
  iconFill: "#1A73E8FF",
  titleColor: "#202124FF",
  transcriptColor: "#5F6368FF",
  titleSize: 12,
  transcriptSize: 10,
  transcriptLimit: 2_000,
  titleLimit: 200,
  untitled: "Recording",
} as const;

export interface AudioCardLayout {
  frame: Rect;
  padding: number;
  iconSize: number;
  iconCenter: Point;
  /** The label's text box; undefined when it has no room. */
  labelFrame?: Rect;
  /** Label lines whose bottom is below this are not drawn. */
  labelBottom: number;
}

/** `p = min(8, 0.1 m)`, `d = min(24, m − 2p)` with `m` the frame's shorter side. */
export function audioCardLayout(frame: Rect): AudioCardLayout {
  const m = Math.min(frame.w, frame.h);
  const padding = Math.min(8, 0.1 * m);
  const iconSize = Math.min(24, m - 2 * padding);
  const d = Math.max(iconSize, 0);
  const label = { x: frame.x + 2 * padding + d, y: frame.y + padding, w: frame.w - 3 * padding - d, h: frame.h - 2 * padding };
  const out: AudioCardLayout = {
    frame, padding, iconSize, iconCenter: { x: frame.x + padding + iconSize / 2, y: frame.y + padding + iconSize / 2 },
    labelBottom: frame.y + frame.h - padding,
  };
  if (label.w > 0 && label.h > 0) out.labelFrame = label;
  return out;
}

function hexPaint(hex: string): Paint {
  const n = (i: number) => parseInt(hex.slice(i, i + 2), 16);
  return { r: n(1), g: n(3), b: n(5), alpha: n(7) / 255 };
}

const white: Paint = { r: 255, g: 255, b: 255, alpha: 1 };

/** The card and the icon (§8.2.9 steps 1–2), turned with the item's rotation. */
export function audioCardCommands(frame: Rect, degrees: number): DrawCommand[] {
  const r = rotate(frame, degrees);
  const f = frame;
  const corners = [{ x: f.x, y: f.y }, { x: f.x + f.w, y: f.y }, { x: f.x + f.w, y: f.y + f.h }, { x: f.x, y: f.y + f.h }]
    .map((p) => apply(r, p));
  const out: DrawCommand[] = [{
    primitive: { kind: "path", subpaths: [{ points: corners, closed: true }] }, fill: hexPaint(audioCard.fill),
    stroke: hexPaint(audioCard.outline), lineWidth: 1,
  }];
  const card = audioCardLayout(frame);
  const d = card.iconSize;
  if (!(Number.isFinite(d) && d > 0)) return out;
  const { x: cx, y: cy } = card.iconCenter;
  out.push({ primitive: { kind: "circle", center: apply(r, { x: cx, y: cy }), radius: d / 2 }, fill: hexPaint(audioCard.iconFill), lineWidth: 1 });
  const rad = 0.12 * d, top = cy - 0.3 * d + rad, bottom = cy + 0.08 * d - rad;
  const n = 12;
  const capsule: Point[] = [];
  for (let i = 0; i <= n; i++) {
    const a = Math.PI + (Math.PI * i) / n;
    capsule.push({ x: cx + rad * Math.cos(a), y: top + rad * Math.sin(a) });
  }
  for (let i = 0; i <= n; i++) {
    const a = (Math.PI * i) / n;
    capsule.push({ x: cx + rad * Math.cos(a), y: bottom + rad * Math.sin(a) });
  }
  out.push({ primitive: { kind: "path", subpaths: [{ points: capsule.map((p) => apply(r, p)), closed: true }] }, fill: white, lineWidth: 1 });
  const w = 0.06 * d;
  const arc: Point[] = [];
  for (let i = 0; i <= n; i++) {
    const a = (Math.PI * i) / n;
    arc.push({ x: cx + 0.2 * d * Math.cos(a), y: cy - 0.04 * d + 0.2 * d * Math.sin(a) });
  }
  out.push({ primitive: { kind: "path", subpaths: [{ points: arc.map((p) => apply(r, p)), closed: false }] }, stroke: white, lineWidth: w });
  out.push({ primitive: { kind: "line", from: apply(r, { x: cx, y: cy + 0.16 * d }), to: apply(r, { x: cx, y: cy + 0.3 * d }) }, stroke: white, lineWidth: w });
  out.push({
    primitive: { kind: "line", from: apply(r, { x: cx - 0.12 * d, y: cy + 0.3 * d }), to: apply(r, { x: cx + 0.12 * d, y: cy + 0.3 * d }) },
    stroke: white, lineWidth: w,
  });
  return out;
}

/** The recording an audio item shows: by id, else one restored from it (`parent`, §8.3.3), first by (started, id). */
export function recordingShownBy(item: JSONObject, recordings: JSONObject[]): JSONObject | undefined {
  if (item.kind !== "audio" || typeof item.recording !== "string") return undefined;
  const id = item.recording.toLowerCase();
  const direct = recordings.find((r) => String(r.id).toLowerCase() === id);
  if (direct) return direct;
  // `recordings` come sorted by (started, id) from the reducer.
  return recordings.find((r) => typeof r.parent === "string" && r.parent.toLowerCase() === id);
}

/** Line breaks, tabs and other controls as spaces (a run holds no C0 control but `\n`, `\t`). */
function oneLine(s: string): string {
  return Array.from(s, (c) => {
    const v = c.codePointAt(0) ?? 0;
    return v < 0x20 || v === 0x7f || v === 0x2028 || v === 0x2029 ? " " : c;
  }).join("");
}

function scalars(s: string, limit: number): string {
  return Array.from(s).slice(0, limit).join("");
}

/** The title as the card shows it. */
export function audioTitle(recording: JSONObject): string {
  const t = typeof recording.title === "string" ? recording.title.trim() : "";
  return t === "" ? audioCard.untitled : scalars(t, audioCard.titleLimit);
}

/** `m:ss` or `h:mm:ss` (Swift `Transcript.clock`). */
export function clock(seconds: number): string {
  const s = Number.isFinite(seconds) ? Math.max(0, Math.trunc(Math.min(seconds, 1e9))) : 0;
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  const two = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${two(m)}:${two(sec)}` : `${m}:${two(sec)}`;
}

/** The segments joined by single spaces, cut to 2 000 scalars; undefined when empty. */
export function transcriptExcerpt(t: Transcript): string | undefined {
  const parts = t.segments.map((s) => s.text.split(/\s+/).filter((w) => w !== "").join(" ")).filter((s) => s !== "");
  if (parts.length === 0) return undefined;
  return scalars(parts.join(" "), audioCard.transcriptLimit);
}

/** The label's content (§8.2.9 step 3). */
export function audioLabel(recording: JSONObject, transcript?: Transcript): TextContent {
  const base = { size: audioCard.titleSize, color: audioCard.titleColor, bold: false, italic: false, underline: false, strike: false };
  const runs: TextContent["runs"] = [{ t: oneLine(audioTitle(recording)), style: { ...base, bold: true } }];
  if (typeof recording.duration === "number" && Number.isFinite(recording.duration)) {
    runs.push({ t: ` · ${clock(recording.duration)}`, style: base });
  }
  const excerpt = transcript ? transcriptExcerpt(transcript) : undefined;
  if (transcript && excerpt !== undefined) {
    const style = { ...base, size: audioCard.transcriptSize, color: audioCard.transcriptColor };
    runs.push({ t: `\n${oneLine(excerpt)}`, style: transcript.language ? { ...style, lang: transcript.language } : style });
  }
  return { font: "sans", size: audioCard.titleSize, color: audioCard.titleColor, align: "start", dir: "auto", runs };
}

/** The lines whose bottom (baseline + 0.25 S) is at or above `bottom`, up to the first that is not. */
export function clipLines(layout: TextLayout, bottom: number): TextLayout {
  const lines = [];
  for (const line of layout.lines) {
    if (line.baseline + 0.25 * line.size > bottom + 1e-6) break;
    lines.push(line);
  }
  const last = lines[lines.length - 1];
  return { ...layout, lines, bottom: last ? last.baseline + 0.25 * last.size : 0 };
}
