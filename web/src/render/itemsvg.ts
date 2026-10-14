// What each placed item of a page becomes (format.md §8.2.3, §8.5): a text
// box laid out now, an image or PDF page to fetch and place, or a
// placeholder. The SVG nodes follow SVGWriter.swift's `items` group: a
// background item's paper fill, then the item; images inside a clip to their
// rotated frame with one `matrix`; text rotated about the frame's centre.

import type { JSONObject } from "../format/json.ts";
import { type BlobRef, asBlobRef } from "../vault/blobs.ts";
import {
  type Affine, type PreparedItem, backgroundFill, identity, placeholderCommands, playMarkCommands, pointsAttr, rotate, svgImageMatrix,
  svgMatrix,
} from "./items.ts";
import { type PreparedPage, type SVGElementSpec, elementSpec } from "./page.ts";
import type { Transcript } from "../format/transcript.ts";
import { audioCardCommands, audioCardLayout, audioLabel, clipLines, recordingShownBy } from "./audio.ts";
import { fmt, paint, paintHex } from "./primitives.ts";
import { type Measure, type TextContent, type TextLayout, approximateMeasure, fontStacks, layoutText, lineAnchor, textContent } from "./text.ts";

/** An SVG element with children or text (the DOM builder's allow-list decides what is drawn). */
export interface SVGNode {
  tag: string;
  attrs: [string, string][];
  text?: string;
  children?: SVGNode[];
}

export type ItemDraw =
  | { kind: "placeholder"; it: PreparedItem; reason: string }
  | { kind: "text"; it: PreparedItem; content: TextContent; layout: TextLayout }
  | { kind: "image"; it: PreparedItem; ref: BlobRef }
  | {
    kind: "pdf"; it: PreparedItem; ref: BlobRef; pageIndex: number; pageSize: { w: number; h: number };
    /** A math item's render (§8.2.8): drawn on a transparent page, its source as text when it cannot be. */
    math?: { content: TextContent; layout: TextLayout };
  }
  /** A video clip (§8.2.7): its poster (none: a placeholder) under the play mark; the clip plays on request. */
  | { kind: "video"; it: PreparedItem; clip: BlobRef; poster?: BlobRef; duration?: number }
  /** A recording on the page (§8.2.9): the card, its label laid out without the transcript (fetched later). */
  | { kind: "audio"; it: PreparedItem; recording: JSONObject; content: TextContent; layout?: TextLayout };

export interface ResolvedItem {
  /** A background item's paper fill (§8.2.3), drawn first. */
  fill?: SVGElementSpec;
  /** A Markdown box's shapes (§8.5.4), drawn after the fill, under the item. */
  underlay?: SVGElementSpec[];
  draw: ItemDraw;
}

function size(v: unknown): { w: number; h: number } | undefined {
  if (!Array.isArray(v) || v.length !== 2) return undefined;
  const [w, h] = v as [unknown, unknown];
  return typeof w === "number" && typeof h === "number" ? { w, h } : undefined;
}

/** Decides what each item becomes; text is laid out with `measure` when its breaks cannot be used. */
export function resolveItems(prepared: PreparedPage, measure: Measure = approximateMeasure, recordings: JSONObject[] = []): ResolvedItem[] {
  return prepared.items.map((it) => {
    const out: ResolvedItem = { draw: resolveItem(it, measure, recordings) };
    if (it.fillsBackground && prepared.options.paper) out.fill = elementSpec(backgroundFill(it, prepared.drawnPaper));
    if (it.underlay && it.underlay.length > 0) out.underlay = it.underlay.map(elementSpec);
    return out;
  });
}

function resolveItem(it: PreparedItem, measure: Measure, recordings: JSONObject[]): ItemDraw {
  const item: JSONObject = it.item;
  switch (it.kind) {
    case "text": {
      const content = textContent(item);
      if (!content) return { kind: "placeholder", it, reason: "text item without text" };
      return { kind: "text", it, content, layout: layoutText(content, it.frame, measure) };
    }
    case "image": {
      const ref = asBlobRef(item.blob);
      return ref ? { kind: "image", it, ref } : { kind: "placeholder", it, reason: "image without a blob" };
    }
    case "pdfPage": {
      const ref = asBlobRef(item.blob);
      const pageSize = size(item.pageSize);
      const pageIndex = item.pageIndex;
      if (!ref || !pageSize || typeof pageIndex !== "number") return { kind: "placeholder", it, reason: "PDF page without a blob" };
      return { kind: "pdf", it, ref, pageIndex, pageSize };
    }
    case "video": {
      const clip = asBlobRef(item.blob);
      if (!clip) return { kind: "placeholder", it, reason: "video without a blob" };
      const poster = asBlobRef(item.poster);
      const duration = typeof item.duration === "number" ? item.duration : undefined;
      return { kind: "video", it, clip, ...(poster ? { poster } : {}), ...(duration !== undefined ? { duration } : {}) };
    }
    case "audio": {
      const recording = recordingShownBy(item, recordings);
      if (!recording) return { kind: "placeholder", it, reason: "recording missing" };
      return audioDraw(it, recording, measure);
    }
    case "math": {
      // §8.2.8: the stored render as a PDF page without crop, else the source as monospace text.
      const content = mathSource(item);
      if (!content) return { kind: "placeholder", it, reason: "math item without math" };
      const fallback = { content, layout: layoutText(content, it.frame, measure) };
      const m = item.math as JSONObject;
      const ref = asBlobRef(m.render);
      const renderSize = size(m.renderSize);
      if (ref && renderSize) return { kind: "pdf", it, ref, pageIndex: 0, pageSize: renderSize, math: fallback };
      return { kind: "text", it, ...fallback };
    }
    default:
      return { kind: "placeholder", it, reason: `${it.kind} items are not drawn by the viewer` };
  }
}

/** An audio item's card with its label laid out (with the transcript once it is read). */
export function audioDraw(it: PreparedItem, recording: JSONObject, measure: Measure = approximateMeasure,
  transcript?: Transcript): Extract<ItemDraw, { kind: "audio" }> {
  const card = audioCardLayout(it.frame);
  const content = audioLabel(recording, transcript);
  const out: Extract<ItemDraw, { kind: "audio" }> = { kind: "audio", it, recording, content };
  if (card.labelFrame) out.layout = clipLines(layoutText(content, card.labelFrame, measure), card.labelBottom);
  return out;
}

/** The card and icon of an audio item. */
export function audioCardNodes(it: PreparedItem): SVGNode[] {
  return audioCardCommands(it.frame, it.rotation).map((c) => spec(elementSpec(c)));
}

/** An audio item's label, turned with the card (about the card's centre, not the label's). */
export function audioLabelNode(d: Extract<ItemDraw, { kind: "audio" }>): SVGNode | undefined {
  const frame = audioCardLayout(d.it.frame).labelFrame;
  if (!frame || !d.layout) return undefined;
  const inner = textNode({ ...d.it, frame, rotation: 0 }, d.content, d.layout);
  return d.it.rotation === 0 ? inner : { tag: "g", attrs: [["transform", svgMatrix(rotate(d.it.frame, d.it.rotation))]], children: [inner] };
}

/** A math item's source as the text box it is drawn as without its render (Swift `MathItems.sourceView`). */
export function mathSource(item: JSONObject): TextContent | undefined {
  const m = item.math as JSONObject | undefined;
  if (!m || typeof m !== "object" || typeof m.latex !== "string") return undefined;
  const size = typeof m.size === "number" ? m.size : 12;
  const color = typeof m.color === "string" ? m.color : "#000000FF";
  const style = { size, color, bold: false, italic: false, underline: false, strike: false };
  return { font: "mono", size, color, align: "start", dir: "auto", runs: m.latex.length > 0 ? [{ t: m.latex, style }] : [] };
}

function spec(e: SVGElementSpec): SVGNode {
  return { tag: e.tag, attrs: e.attrs };
}

/** The play mark over a video (§8.2.7), drawn whatever is under it. */
export function playMarkNodes(it: PreparedItem): SVGNode[] {
  return playMarkCommands(it.frame, it.rotation).map((c) => spec(elementSpec(c)));
}

/** The placeholder of §8.5.2. */
export function placeholderNodes(it: PreparedItem): SVGNode[] {
  return placeholderCommands(it.corners).map((c) => spec(elementSpec(c)));
}

function fillAttrs(color: string): [string, string][] {
  const p = paint(color);
  const out: [string, string][] = [["fill", paintHex(p)]];
  if (p.alpha < 0.9995) out.push(["fill-opacity", fmt(p.alpha)]);
  return out;
}

/** The rotation of a text item about its frame's centre (identity when not rotated). */
export function textTransform(it: PreparedItem): Affine {
  return it.rotation === 0 ? identity : rotate(it.frame, it.rotation);
}

/**
 * A text item: one `<text>` per drawn line at the format's baseline, one
 * `<tspan>` per run piece, anchored by the alignment and the paragraph's
 * direction; glyphs, shaping and the order inside a line are the browser's.
 */
export function textNode(it: PreparedItem, content: TextContent, layout: TextLayout): SVGNode {
  const lines: SVGNode[] = [];
  for (const line of layout.lines) {
    if (line.pieces.length === 0) continue;
    const { x, anchor } = lineAnchor(content.align, line.rtl, it.frame);
    const attrs: [string, string][] = [
      ["x", fmt(x)], ["y", fmt(line.baseline)], ["font-family", fontStacks[content.font]], ["font-size", fmt(content.size)],
      ["text-anchor", anchor], ["direction", line.rtl ? "rtl" : "ltr"], ["unicode-bidi", "embed"], ["xml:space", "preserve"],
    ];
    if (content.lang !== undefined) attrs.push(["lang", content.lang]);
    lines.push({
      tag: "text", attrs, children: line.pieces.map((p) => {
        const a: [string, string][] = [["font-size", fmt(p.style.size)], ...fillAttrs(p.style.color)];
        if (p.style.bold) a.push(["font-weight", "bold"]);
        if (p.style.italic) a.push(["font-style", "italic"]);
        const deco = [p.style.underline ? "underline" : "", p.style.strike ? "line-through" : ""].filter((d) => d).join(" ");
        if (deco) a.push(["text-decoration", deco]);
        if (p.style.lang !== undefined && p.style.lang !== content.lang) a.push(["lang", p.style.lang]);
        if (p.style.font !== undefined && p.style.font !== content.font) a.push(["font-family", fontStacks[p.style.font]]);
        return { tag: "tspan", attrs: a, text: p.text };
      }),
    });
  }
  const m = textTransform(it);
  return m === identity ? { tag: "g", attrs: [], children: lines } : { tag: "g", attrs: [["transform", svgMatrix(m)]], children: lines };
}

/**
 * A raster (an image, or a rendered PDF crop) `width × height` placed by
 * `transform` (its pixel coordinates → page), clipped to the item's rotated
 * frame. `clipId` must be unique in the document.
 */
export function rasterNode(it: PreparedItem, href: string, width: number, height: number, transform: Affine, clipId: string): SVGNode {
  return {
    tag: "g", attrs: [], children: [
      { tag: "clipPath", attrs: [["id", clipId]], children: [{ tag: "polygon", attrs: [["points", pointsAttr(it.corners)]] }] },
      {
        tag: "g", attrs: [["clip-path", `url(#${clipId})`]], children: [{
          tag: "image", attrs: [["width", String(width)], ["height", String(height)], ["preserveAspectRatio", "none"],
            ["transform", svgImageMatrix(transform)], ["href", href]],
        }],
      },
    ],
  };
}
