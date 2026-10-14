// The note view: pages stacked vertically (or one tall infinite page), drawn
// as SVG built from the same element specs `sempere export --format svg`
// writes, with pan and zoom (wheel, drag, pinch, keyboard). Pages are drawn
// lazily as they come near the viewport.

import { locale, t, tn } from "../i18n/index.ts";
import { type NoteState, type Page, type Paper, paperKind, pointStride } from "../format/model.ts";
import { imageInfo, imageLimits, stripMetadata } from "../render/images.ts";
import {
  type PreparedItem, after, imageTransform, intersect, maxItemsPerPage, pdfCrop, placement, posterTransform, prepareItem, translate,
} from "../render/items.ts";
import {
  type ItemDraw, audioCardNodes, audioDraw, audioLabelNode, placeholderNodes, playMarkNodes, rasterNode, resolveItems, textNode,
} from "../render/itemsvg.ts";
import { type Transcript, decodeTranscript, maxTranscriptBytes } from "../format/transcript.ts";
import type { JSONObject } from "../format/json.ts";
import { asBlobRef } from "../vault/blobs.ts";
import { cmpItems } from "../format/registers.ts";
import { PreparedPage, chunkHeight, defaultRenderOptions, elementSpec } from "../render/page.ts";
import { expandMarkdown } from "../render/markdown.ts";
import { RenderLimits, pointCount } from "../render/primitives.ts";
import { meanScale, transformOf } from "../render/stroke.ts";
import { type Measure, fontStacks } from "../render/text.ts";
import { BlobError, type NoteBlobs } from "../vault/blobs.ts";
import { type BlobKind, blobProblem } from "./errors.ts";
import { h, s, svgTree } from "./dom.ts";
import { NotePDFs, maxPDFBytes } from "./pdf.ts";
import { OrderedLayer, StrokeBands } from "./bands.ts";
import { PageFlow } from "./pageflow.ts";

const gap = 24;
/**
 * Pages are drawn within a screen above and two below the viewport's top, and released (back to
 * their placeholder) once more than `releaseScreens` screens away, so a long note keeps only the
 * pages around the viewport in the DOM.
 */
const releaseScreens = 4;
const minZoom = 0.05, maxZoom = 12;
/** Milliseconds of idle time spent measuring pages per slice, and the delay between slices. */
const idleBudgetMs = 8;

/** Runs `f` when the browser is idle (Safari has no requestIdleCallback: a timer there). */
function whenIdle(f: () => void): void {
  const ric = (globalThis as { requestIdleCallback?: (f: () => void) => number }).requestIdleCallback;
  if (ric) ric(f);
  else setTimeout(f, 16);
}

/** The height a page has until it is measured: the sheet, or for a pageless page one chunk. */
export function provisionalHeight(state: NoteState): number {
  const size = state.meta.pageSize;
  const h = size.infinite ? Math.max(size.height, chunkHeight(defaultRenderOptions, state.meta)) : size.height;
  return h > 0 && Number.isFinite(h) ? h : 200;
}

/** A page's drawn height without outlining it (PreparedPage's extent rule). */
export function pageExtent(page: Page, state: NoteState): number {
  const size = state.meta.pageSize;
  // Each stroke's and item's lowest point and vertical centre (PreparedPage's spans).
  const spans: { maxY: number; centreY: number }[] = [];
  for (const st of page.strokes) {
    const n = st.points.length / pointStride;
    if (n === 0) continue;
    const xf = transformOf(st);
    let radius = Math.abs(st.ink.width), lo = Infinity, hi = -Infinity;
    // Only y is needed: applyTransform's y, inlined, with no allocation per point.
    const pts = st.points, b = xf[1], d = xf[3], ty = xf[5];
    for (let i = 0; i < n; i++) {
      const at = i * pointStride;
      const y = b * (pts[at] ?? 0) + d * (pts[at + 1] ?? 0) + ty;
      lo = Math.min(lo, y);
      hi = Math.max(hi, y);
      radius = Math.max(radius, Math.abs(pts[at + 3] ?? 0), Math.abs(pts[at + 4] ?? 0));
    }
    spans.push({ maxY: hi + Math.min(radius * meanScale(xf), RenderLimits.maxNibWidth) / 2 + 1, centreY: lo / 2 + hi / 2 });
  }
  for (const item of [...page.items].sort(cmpItems).slice(0, maxItemsPerPage)) {
    const p = prepareItem(item);
    if (typeof p === "string") continue;
    // A Markdown box takes part as its pieces (§8.5.4), as in PreparedPage.
    const pieces = expandMarkdown(p)?.pieces;
    if (pieces) spans.push({ maxY: p.maxY, centreY: -Infinity });
    for (const q of pieces ?? [p]) spans.push({ maxY: q.maxY, centreY: q.minY / 2 + q.maxY / 2 });
  }
  let low = 0, below = 0;
  for (const x of spans) {
    low = Math.max(low, x.maxY);
    // Ink centred at or below a finite page adds to its extent (PageComposer.swift).
    if (x.centreY >= size.height) below = Math.max(below, x.maxY);
  }
  const e = size.infinite ? Math.max(size.height, Math.ceil(low), chunkHeight(defaultRenderOptions, state.meta))
    : Math.max(size.height, Math.ceil(Math.min(below, RenderLimits.maxExtent)));
  return Number.isFinite(e) ? Math.min(e, RenderLimits.maxExtent) : size.height;
}

let measureContext: CanvasRenderingContext2D | null | undefined;

/** Text widths from the browser's fonts, for text boxes without usable stored breaks (§8.5.3). */
const canvasMeasure: Measure = (text, style, font) => {
  measureContext ??= document.createElement("canvas").getContext("2d");
  if (!measureContext) return text.length * style.size * 0.5;
  measureContext.font = `${style.italic ? "italic " : ""}${style.bold ? "bold " : ""}${style.size}px ${fontStacks[font]}`;
  return measureContext.measureText(text).width;
};

/** An image, PDF page or video poster waiting to be fetched until it comes on screen. */
interface PendingItem {
  draw: Extract<ItemDraw, { kind: "image" | "pdf" | "video" }>;
  g: SVGElement;
  minX: number;
  maxX: number;
  state: "idle" | "loading" | "done";
  /** PDF pages: pixels per point of the current rendering. */
  scale?: number;
  url?: string;
}

/** An item drawn as a placeholder, and why (format.md §8.5.2). */
export interface ItemProblem {
  page: number;
  item: string;
  kind: string;
  reason: string;
}

let viewCount = 0;

/** Why an attachment cannot be shown; with its kind and limit as `blobProblem` words it. */
function why(e: unknown, kind?: BlobKind, limit = 0): string {
  const known = kind && blobProblem(e, kind, limit);
  if (known) return known;
  if (e instanceof BlobError) return e.code === "missing" ? t("attachment file is missing") : t("attachment unreadable: {detail}", { detail: e.message });
  return e instanceof Error ? e.message : String(e);
}

interface Slot {
  page: Page;
  index: number;
  top: number;
  left: number;
  width: number;
  height: number;
  el: HTMLElement;
  drawn: boolean;
  /** Bumped when the page is released: a load started before then drops its result. */
  generation: number;
  pending: PendingItem[];
  /** Pageless pages: the strokes in the DOM are the ones of the bands near the viewport (P47). */
  bands?: SlotBands;
}

/** A drawn pageless page whose strokes come and go by band. */
interface SlotBands {
  prepared: PreparedPage;
  bands: StrokeBands;
  /** Strokes drawn below the content items, and the rest; each in stroke order. */
  behind: OrderedLayer<Element>;
  ink: OrderedLayer<Element>;
  /** Outline points of the strokes in the DOM, bounded like a whole page's. */
  outline: number;
  /** Outline points of each stroke in the DOM. */
  size: Map<number, number>;
  limitReported: boolean;
}

export class NoteView {
  readonly root: HTMLElement;
  private readonly viewport: HTMLElement;
  private readonly content: HTMLElement;
  private readonly zoomLabel: HTMLElement;
  private slots: Slot[] = [];
  private flow!: PageFlow;
  private idling = false;
  private x = 0;
  private y = 0;
  private z = 1;
  private contentWidth = 1;
  private contentHeight = 1;
  private pending = false;
  private readonly pointers = new Map<number, { x: number; y: number }>();
  private pinch?: { dist: number; z: number; cx: number; cy: number };
  private readonly resize: ResizeObserver;
  private readonly uid = `n${++viewCount}`;
  private readonly pdfs = new NotePDFs();
  private readonly urls = new Set<string>();
  private readonly problems = new Map<string, ItemProblem>();
  /** The list of placeholders and why; the caller puts it with the note's other warnings. */
  readonly problemsEl = h("details", { class: "warning item-problems" });
  private readonly problemsSummary = h("summary");
  private readonly problemsList = h("ul");
  /** Each problem's line in `problemsList`, by the same key as `problems`. */
  private readonly problemItems = new Map<string, HTMLElement>();
  private destroyed = false;
  private rerender?: ReturnType<typeof setTimeout>;
  /**
   * Video and audio items on drawn pages, for taps (page-local rotated frames), in drawing order:
   * a tap plays the topmost one under it, whichever kind (§8.2.7, §8.2.9).
   */
  private readonly playables: Playable[] = [];
  /** Transcripts read for audio cards, by recording id (read once, verified). */
  private readonly transcripts = new Map<string, Promise<Transcript>>();
  private tap?: { x: number; y: number; id: number };

  /**
   * `blobs` reads the note's attachments; without it every image and PDF page is a placeholder.
   * `playVideo` is called with a video item's id when it is tapped (§8.2.7),
   * `playAudio` with the recording id of an audio item (§8.2.9).
   */
  constructor(private readonly state: NoteState, private readonly blobs?: NoteBlobs,
    private readonly playVideo?: (itemId: string) => void, private readonly playAudio?: (recordingId: string) => void) {
    this.content = h("div", { class: "pages" });
    this.viewport = h("div", { class: "viewport", attrs: { tabindex: "0", role: "region", "aria-label": t("Note pages") } }, this.content);
    this.zoomLabel = h("span", { class: "zoom-label" });
    const button = (label: string, title: string, f: () => void) =>
      h("button", { text: label, title, attrs: { type: "button" }, on: { click: f } });
    const toolbar = h("div", { class: "zoom-bar" },
      button("−", t("Zoom out (−)"), () => this.zoomBy(1 / 1.25)), this.zoomLabel,
      button("+", t("Zoom in (+)"), () => this.zoomBy(1.25)),
      button(t("Fit"), t("Fit width (0)"), () => this.fitWidth()), button("1:1", t("Actual size (1)"), () => this.setZoom(1)));
    this.problemsEl.hidden = true;
    this.root = h("div", { class: "note-canvas" }, toolbar, this.viewport);
    this.layout();
    this.bind();
    this.resize = new ResizeObserver(() => this.schedule());
    this.resize.observe(this.viewport);
    requestAnimationFrame(() => this.fitWidth());
  }

  destroy(): void {
    this.destroyed = true;
    this.resize.disconnect();
    clearTimeout(this.rerender);
    this.pdfs.destroy();
    for (const u of this.urls) URL.revokeObjectURL(u);
    this.urls.clear();
  }

  /** Items drawn as placeholders so far (only items that came on screen are tried). */
  itemProblems(): ItemProblem[] {
    return [...this.problems.values()];
  }

  /**
   * Records an item that is a placeholder or not drawn, and why (`it` undefined: a page-level note,
   * `warning` its index among the page's warnings, so drawing the page again replaces it).
   */
  private report(slot: Slot, it: PreparedItem | undefined, reason: string, warning?: number): void {
    const id = it ? String(it.item.id) : `-${warning ?? this.problems.size}`;
    const key = `${slot.index}/${id}`;
    const p: ItemProblem = { page: slot.index + 1, item: it ? id : "", kind: it?.kind ?? "", reason };
    this.problems.set(key, p);
    // One line added or replaced in place (the list keeps the order problems were first reported in).
    const li = h("li", { text: t("Page {page}: {detail}", { page: p.page, detail: `${p.item ? `${p.kind} ${p.item.slice(0, 8)}: ` : ""}${p.reason}` }) });
    const old = this.problemItems.get(key);
    if (old) old.replaceWith(li);
    else this.problemsList.append(li);
    this.problemItems.set(key, li);
    this.problemsSummary.textContent = tn("{count} attachments cannot be shown (crossed boxes on the page)", this.problems.size);
    if (this.problemsEl.hidden) {
      this.problemsEl.hidden = false;
      this.problemsEl.replaceChildren(this.problemsSummary, this.problemsList);
    }
  }

  private layout(): void {
    const pages = this.state.pages;
    const width = this.state.meta.pageSize.width;
    this.contentWidth = Math.max(1, width);
    // Every page starts at a provisional height; exact ones come when a page is drawn or in idle
    // time (`measureSome`), so opening a note is O(pages), not O(points) (P45).
    this.flow = new PageFlow(pages.length, gap, provisionalHeight(this.state), (i) => {
      const page = pages[i];
      let height = 200;
      try {
        if (page) height = pageExtent(page, this.state);
      } catch {
        height = 200;
      }
      return height > 0 ? height : 200;
    });
    this.slots = pages.map((page, index) => {
      const height = this.flow.height(index);
      const el = h("div", { class: "page", attrs: { "aria-label": t("Page {number}", { number: index + 1 }) } },
        h("div", { class: "page-placeholder", text: t("Page {number}", { number: index + 1 }) }));
      el.style.width = `${width}px`;
      el.style.height = `${height}px`;
      el.style.left = `${(this.contentWidth - width) / 2}px`;
      el.style.top = `${this.flow.top(index)}px`;
      const slot: Slot = { page, index, top: this.flow.top(index), left: (this.contentWidth - width) / 2, width, height, el, drawn: false, generation: 0, pending: [] };
      this.content.append(el);
      return slot;
    });
    this.flow.takeMoved();
    this.contentHeight = this.flow.total();
    this.content.style.width = `${this.contentWidth}px`;
    this.content.style.height = `${this.contentHeight}px`;
  }

  /** Brings the slots' positions, the content height and the zoom-independent state in line with the flow. */
  private syncLayout(): void {
    const from = this.flow.takeMoved();
    if (from < 0) return;
    for (let i = from; i < this.slots.length; i++) {
      const slot = this.slots[i];
      if (!slot) continue;
      const top = this.flow.top(i), height = this.flow.height(i);
      if (slot.top !== top) { slot.top = top; slot.el.style.top = `${top}px`; }
      if (slot.height !== height) { slot.height = height; slot.el.style.height = `${height}px`; }
    }
    this.contentHeight = this.flow.total();
    this.content.style.height = `${this.contentHeight}px`;
  }

  /**
   * Runs `f` (which may change page heights) and keeps what is at the top of the screen where it
   * was: the page there stays put even when the pages above it grow or shrink.
   */
  private anchored(f: () => void): void {
    const anchorY = -this.y / this.z;
    const k = this.flow.indexAt(anchorY);
    const offset = anchorY - this.flow.top(k);
    f();
    this.syncLayout();
    const moved = this.flow.top(k) + offset;
    if (moved !== anchorY) {
      this.y = -moved * this.z;
      this.clampPan();
    }
  }

  /** Measures pages nearest the viewport first, a slice at a time while the browser is idle. */
  private measureSome(): void {
    if (this.idling || this.destroyed || this.flow.unresolved === 0) return;
    this.idling = true;
    whenIdle(() => {
      this.idling = false;
      if (this.destroyed) return;
      this.anchored(() => this.flow.resolveNear(-this.y / this.z, idleBudgetMs));
      this.schedule();
      this.measureSome();
    });
  }

  private draw(slot: Slot): void {
    slot.drawn = true;
    try {
      const banded = this.state.meta.pageSize.infinite;
      const prepared = new PreparedPage(slot.page, this.state.meta, { ...defaultRenderOptions, measure: canvasMeasure, lazyOutline: banded });
      const width = this.state.meta.pageSize.width, height = prepared.extent;
      // The exact height replaces the provisional one; what is below moves (the caller keeps the view put).
      this.flow.setExact(slot.index, height);
      const svg = s("svg", [["viewBox", `0 0 ${width} ${height}`], ["width", String(width)], ["height", String(height)]]);
      const paper = s("g"), items = s("g"), ink = s("g");
      for (const c of prepared.fullPagePaper()) {
        const e = elementSpec(c);
        paper.append(s(e.tag, e.attrs));
      }
      prepared.warnings.forEach((w, i) => this.report(slot, undefined, w, i));
      const under = prepared.underIndex();
      // Banded: an empty group at the position of the strokes below the items, filled by `updateBands`.
      const behind = s("g");
      const drawUnder = () => {
        if (banded) { items.append(behind); return; }
        for (const c of prepared.strokeCommands(true)) { const e = elementSpec(c); items.append(s(e.tag, e.attrs)); }
      };
      let n = 0;
      for (const r of resolveItems(prepared, canvasMeasure, this.state.recordings)) {
        if (n++ === under) drawUnder();
        if (r.fill) items.append(s(r.fill.tag, r.fill.attrs));
        for (const u of r.underlay ?? []) items.append(s(u.tag, u.attrs));
        const d = r.draw;
        switch (d.kind) {
          case "placeholder":
            for (const n of placeholderNodes(d.it)) items.append(svgTree(n));
            this.report(slot, d.it, d.reason);
            break;
          case "text":
            items.append(svgTree(textNode(d.it, d.content, d.layout)));
            break;
          case "video": {
            // The poster under the play mark; without one a placeholder (not a problem: §8.2.7).
            const g = s("g");
            items.append(g);
            if (d.poster) {
              const xs = d.it.corners.map((p) => p.x);
              slot.pending.push({ draw: d, g, minX: Math.min(...xs), maxX: Math.max(...xs), state: "idle" });
            } else {
              for (const n of placeholderNodes(d.it)) g.append(svgTree(n));
            }
            for (const n of playMarkNodes(d.it)) items.append(svgTree(n));
            const id = String(d.it.item.id);
            this.playables.push({ slot, it: d.it, play: () => this.playVideo?.(id) });
            break;
          }
          case "audio": {
            // The card now; the transcript joins the label once it is read (§8.2.9).
            for (const n of audioCardNodes(d.it)) items.append(svgTree(n));
            const label = s("g");
            const node = audioLabelNode(d);
            if (node) label.append(svgTree(node));
            items.append(label);
            const recording = String(d.recording.id);
            this.playables.push({ slot, it: d.it, play: () => this.playAudio?.(recording) });
            this.addTranscript(slot, d.it, d.recording, label);
            break;
          }
          default: {
            const g = s("g");
            items.append(g);
            const xs = d.it.corners.map((p) => p.x);
            slot.pending.push({ draw: d, g, minX: Math.min(...xs), maxX: Math.max(...xs), state: "idle" });
          }
        }
      }
      if (under >= n) drawUnder();
      if (banded) {
        // Strokes come in by band as the viewport reaches them (`updateBands`).
        slot.bands = {
          prepared, bands: new StrokeBands(prepared.strokes, height, chunkHeight(defaultRenderOptions, this.state.meta)),
          behind: new OrderedLayer<Element>(behind), ink: new OrderedLayer<Element>(ink), outline: 0, size: new Map(), limitReported: false,
        };
      } else {
        for (const c of prepared.strokeCommands(false)) {
          const e = elementSpec(c);
          ink.append(s(e.tag, e.attrs));
        }
      }
      svg.append(paper, items, ink);
      slot.el.style.height = `${height}px`;
      slot.el.replaceChildren(svg);
    } catch (e) {
      slot.el.replaceChildren(h("div", { class: "page-error", text: t("Page {number} cannot be drawn: {detail}", { number: slot.index + 1, detail: e instanceof Error ? e.message : String(e) }) }));
    }
  }

  /**
   * Puts a drawn page back to its placeholder: its SVG, its attachments' object URLs and its
   * playable items go; loads still running for it drop their results. It is drawn again (the same
   * way) when it comes back near the viewport.
   */
  private release(slot: Slot): void {
    slot.drawn = false;
    slot.generation++;
    for (const p of slot.pending) {
      if (p.url) {
        URL.revokeObjectURL(p.url);
        this.urls.delete(p.url);
      }
    }
    slot.pending = [];
    slot.bands = undefined;
    for (let i = this.playables.length - 1; i >= 0; i--) if (this.playables[i]?.slot === slot) this.playables.splice(i, 1);
    slot.el.replaceChildren(h("div", { class: "page-placeholder", text: t("Page {number}", { number: slot.index + 1 }) }));
  }

  /** Reads the transcript of an audio card's recording and redraws its label with it. */
  private addTranscript(slot: Slot, it: PreparedItem, recording: JSONObject, label: SVGElement): void {
    const ref = asBlobRef(recording.transcript);
    if (!ref || !this.blobs) return;
    const blobs = this.blobs;
    const id = String(recording.id);
    let pending = this.transcripts.get(id);
    if (!pending) {
      pending = blobs.get(ref, maxTranscriptBytes).then(async (b) => decodeTranscript(new Uint8Array(await b.arrayBuffer()), id));
      this.transcripts.set(id, pending);
    }
    pending.then((t) => {
      if (this.destroyed) return;
      const node = audioLabelNode(audioDraw(it, recording, canvasMeasure, t));
      label.replaceChildren(...(node ? [svgTree(node)] : []));
    }).catch((e: unknown) => {
      if (!this.destroyed) this.report(slot, it, t("the recording's transcript is not shown: {detail}", { detail: why(e) }));
    });
  }

  /** Pixels per point a PDF crop needs at the current zoom (at least 2, at most 8). */
  private pdfScale(p: PendingItem): number {
    const d = p.draw as Extract<ItemDraw, { kind: "pdf" }>;
    const crop = pdfCrop(d.it, d.pageSize.w, d.pageSize.h);
    const perPoint = Math.max(d.it.frame.w / crop.w, d.it.frame.h / crop.h);
    return Math.min(Math.max(perPoint * this.z * (globalThis.devicePixelRatio || 1), 2), 8);
  }

  /** Fetches and draws the images and PDF pages that are on screen (or nearly). */
  private loadVisible(top: number, bottom: number, left: number, right: number): void {
    let wantsSharper = false;
    for (const slot of this.slots) {
      if (!slot.drawn || slot.top > bottom || slot.top + slot.height < top) continue;
      for (const p of slot.pending) {
        const it = p.draw.it;
        if (slot.top + it.maxY < top || slot.top + it.minY > bottom || slot.left + p.maxX < left || slot.left + p.minX > right) continue;
        if (p.state === "idle") void this.load(slot, p);
        else if (p.state === "done" && p.draw.kind === "pdf" && p.scale !== undefined && this.pdfScale(p) > p.scale * 1.5) wantsSharper = true;
      }
    }
    if (wantsSharper) {
      clearTimeout(this.rerender);
      this.rerender = setTimeout(() => this.sharpen(top, bottom), 400);
    }
  }

  private sharpen(top: number, bottom: number): void {
    for (const slot of this.slots) {
      for (const p of slot.pending) {
        const it = p.draw.it;
        if (p.state !== "done" || p.draw.kind !== "pdf" || p.scale === undefined) continue;
        if (slot.top + it.maxY < top || slot.top + it.minY > bottom) continue;
        if (this.pdfScale(p) > p.scale * 1.5) void this.load(slot, p);
      }
    }
  }

  private async load(slot: Slot, p: PendingItem): Promise<void> {
    p.state = "loading";
    const generation = slot.generation;
    const d = p.draw;
    const clipId = `${this.uid}-p${slot.index}-i${slot.pending.indexOf(p)}`;
    try {
      if (!this.blobs) throw new Error(t("attachments are not available"));
      let url: string, width: number, height: number, transform;
      if (d.kind === "image" || d.kind === "video") {
        const ref = d.kind === "image" ? d.ref : d.poster;
        if (!ref) throw new Error(t("video without a poster frame"));
        const bytes = new Uint8Array(await (await this.blobs.get(ref, imageLimits.maxBlobBytes)).arrayBuffer());
        const info = imageInfo(bytes);
        const m = d.kind === "image" ? imageTransform(d.it, info.width, info.height) : posterTransform(d.it, info.width, info.height);
        if (typeof m === "string") throw new Error(m);
        url = this.url(new Blob([stripMetadata(bytes) as Uint8Array<ArrayBuffer>], { type: info.type }));
        const img = new Image();
        img.src = url;
        let decoded = true;
        try {
          await img.decode();
        } catch {
          decoded = false;
        }
        if (!decoded || img.naturalWidth !== info.width || img.naturalHeight !== info.height) {
          URL.revokeObjectURL(url);
          this.urls.delete(url);
          throw new Error(decoded ? t("the image does not decode to its stated size") : t("the image cannot be decoded"));
        }
        ({ width, height } = info);
        transform = m;
      } else {
        const blobs = this.blobs;
        const doc = await this.pdfs.document(d.ref.sha256, async () => new Uint8Array(await (await blobs.get(d.ref, maxPDFBytes)).arrayBuffer()));
        const page = await this.pdfs.page(doc, d.pageIndex);
        const eff = NotePDFs.effectiveSize(page);
        const crop = pdfCrop(d.it, eff.w, eff.h);
        // Only the page is drawn: a crop reaching beyond it shows the paper there, as in the exports.
        const shown = intersect(crop, { x: 0, y: 0, w: eff.w, h: eff.h });
        if (!shown) throw new Error(t("the crop lies outside the PDF page"));
        const scale = this.pdfScale(p);
        const canvas = await this.pdfs.render(page, shown, scale, d.math !== undefined);
        const png = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/png"));
        if (!png) throw new Error(t("the PDF page cannot be drawn"));
        url = this.url(png);
        width = shown.w;
        height = shown.h;
        transform = after(placement(crop, d.it.frame, d.it.rotation), translate(shown.x, shown.y));
        p.scale = scale;
      }
      if (this.destroyed || slot.generation !== generation) {
        URL.revokeObjectURL(url);
        this.urls.delete(url);
        return;
      }
      if (p.url) URL.revokeObjectURL(p.url);
      this.urls.delete(p.url ?? "");
      p.url = url;
      p.g.replaceChildren(svgTree(rasterNode(d.it, url, width, height, transform, clipId)));
      p.state = "done";
    } catch (e) {
      if (this.destroyed || slot.generation !== generation) return;
      p.state = "done";
      // A sharper rendering that failed keeps the one already shown, and is not tried again.
      if (p.url) {
        p.scale = Infinity;
        return;
      }
      p.scale = undefined;
      // An equation whose render cannot be drawn shows its source (§8.2.8).
      if (d.kind === "pdf" && d.math) {
        p.g.replaceChildren(svgTree(textNode(d.it, d.math.content, d.math.layout)));
        return;
      }
      p.g.replaceChildren(...placeholderNodes(d.it).map(svgTree));
      this.report(slot, d.it, d.kind === "pdf" ? why(e, "pdf", maxPDFBytes) : why(e, "image", imageLimits.maxBlobBytes));
    }
  }

  private url(b: Blob): string {
    const u = URL.createObjectURL(b);
    this.urls.add(u);
    return u;
  }

  private schedule(): void {
    if (this.pending) return;
    this.pending = true;
    requestAnimationFrame(() => {
      this.pending = false;
      this.apply();
    });
  }

  private apply(): void {
    if (this.destroyed) return;
    const vh = this.viewport.clientHeight;
    const window = () => {
      const top = (-this.y - vh) / this.z, bottom = (-this.y + 2 * vh) / this.z;
      return { top, bottom, farTop: (-this.y - releaseScreens * vh) / this.z, farBottom: (-this.y + (releaseScreens + 1) * vh) / this.z };
    };
    let w = window();
    // Draw the pages in the window, in order, each at the position the pages above it have just
    // given it. Drawing makes a page's height exact, which moves the pages below it.
    this.anchored(() => {
      for (let i = this.flow.indexAt(w.top); i < this.slots.length && this.flow.top(i) <= w.bottom; i++) {
        const slot = this.slots[i];
        if (slot && !slot.drawn) this.draw(slot);
      }
    });
    w = window();
    this.syncLayout();
    for (const slot of this.slots) {
      if (slot.drawn && (slot.top + slot.height < w.farTop || slot.top > w.farBottom)) this.release(slot);
    }
    for (const slot of this.slots) if (slot.drawn && slot.bands) this.updateBands(slot, w);
    this.content.style.transform = `translate(${this.x}px, ${this.y}px) scale(${this.z})`;
    this.zoomLabel.textContent = new Intl.NumberFormat(locale(), { style: "percent" }).format(Math.round(this.z * 100) / 100);
    // Attachments load only when on screen (half a screen ahead).
    const vw = this.viewport.clientWidth;
    this.loadVisible((-this.y - vh / 2) / this.z, (-this.y + 1.5 * vh) / this.z, (-this.x - vw / 2) / this.z, (-this.x + 1.5 * vw) / this.z);
    this.measureSome();
  }

  /** Puts in the strokes of the bands near the viewport and takes out those of bands left behind. */
  private updateBands(slot: Slot, w: { top: number; bottom: number; farTop: number; farBottom: number }): void {
    const sb = slot.bands;
    if (!sb) return;
    const changes = sb.bands.update(w.top - slot.top, w.bottom - slot.top, w.farTop - slot.top, w.farBottom - slot.top);
    for (const i of changes.remove) {
      const st = sb.prepared.strokes[i];
      (st?.behindItems === true ? sb.behind : sb.ink).remove(i);
      st?.discard?.();
      sb.outline -= sb.size.get(i) ?? 0;
      sb.size.delete(i);
    }
    for (const i of changes.add) {
      const st = sb.prepared.strokes[i];
      if (!st) continue;
      try {
        const commands = st.commands;
        const points = commands.reduce((m, c) => m + pointCount(c), 0);
        // The same bound as the page as a whole, on what is drawn at once.
        if (sb.outline + points > RenderLimits.maxOutlinePoints) {
          st.discard?.();
          if (!sb.limitReported) {
            sb.limitReported = true;
            this.report(slot, undefined, t("part of the ink is not drawn: the page has more ink geometry than the renderer accepts at once"), 1000);
          }
          continue;
        }
        sb.outline += points;
        sb.size.set(i, points);
        (st.behindItems === true ? sb.behind : sb.ink).add(i, commands.map((c) => { const e = elementSpec(c); return s(e.tag, e.attrs); }));
      } catch (e) {
        if (!sb.limitReported) {
          sb.limitReported = true;
          this.report(slot, undefined, e instanceof Error ? e.message : String(e), 1000);
        }
      }
    }
  }

  private clampPan(): void {
    const vw = this.viewport.clientWidth, vh = this.viewport.clientHeight;
    this.x = clampX(this.x, this.contentWidth * this.z, vw);
    this.y = clampY(this.y, this.contentHeight * this.z, vh);
  }

  private setZoom(z: number, cx = this.viewport.clientWidth / 2, cy = this.viewport.clientHeight / 2): void {
    const nz = Math.min(Math.max(z, minZoom), maxZoom);
    this.x = cx - ((cx - this.x) * nz) / this.z;
    this.y = cy - ((cy - this.y) * nz) / this.z;
    this.z = nz;
    this.clampPan();
    this.schedule();
  }

  private zoomBy(f: number, cx?: number, cy?: number): void {
    this.setZoom(this.z * f, cx, cy);
  }

  fitWidth(): void {
    const vw = this.viewport.clientWidth || 800;
    this.z = Math.min(Math.max((vw - 32) / this.contentWidth, minZoom), 4);
    this.x = (vw - this.contentWidth * this.z) / 2;
    this.y = 16;
    this.clampPan();
    this.schedule();
  }

  private panBy(dx: number, dy: number): void {
    this.x += dx;
    this.y += dy;
    this.clampPan();
    this.schedule();
  }

  private local(e: { clientX: number; clientY: number }): { x: number; y: number } {
    const r = this.viewport.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  private bind(): void {
    const v = this.viewport;
    v.addEventListener("wheel", (e) => {
      e.preventDefault();
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? v.clientHeight : 1;
      if (e.ctrlKey || e.metaKey) {
        const p = this.local(e);
        this.zoomBy(Math.exp(-e.deltaY * unit * 0.01), p.x, p.y);
      } else {
        this.panBy(-e.deltaX * unit, -e.deltaY * unit);
      }
    }, { passive: false });
    v.addEventListener("pointerdown", (e) => {
      this.tap = this.pointers.size === 0 ? { ...this.local(e), id: e.pointerId } : undefined;
      v.setPointerCapture(e.pointerId);
      this.pointers.set(e.pointerId, this.local(e));
      if (this.pointers.size === 2) {
        const [a, b] = [...this.pointers.values()] as [{ x: number; y: number }, { x: number; y: number }];
        this.pinch = { dist: Math.hypot(a.x - b.x, a.y - b.y), z: this.z, cx: (a.x + b.x) / 2, cy: (a.y + b.y) / 2 };
      }
    });
    v.addEventListener("pointermove", (e) => {
      const prev = this.pointers.get(e.pointerId);
      if (!prev) return;
      const p = this.local(e);
      this.pointers.set(e.pointerId, p);
      if (this.pointers.size === 1) {
        this.panBy(p.x - prev.x, p.y - prev.y);
      } else if (this.pointers.size === 2 && this.pinch) {
        const [a, b] = [...this.pointers.values()] as [{ x: number; y: number }, { x: number; y: number }];
        const cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2;
        this.panBy(cx - this.pinch.cx, cy - this.pinch.cy);
        this.pinch.cx = cx;
        this.pinch.cy = cy;
        const dist = Math.hypot(a.x - b.x, a.y - b.y);
        if (this.pinch.dist > 0) this.setZoom((this.pinch.z * dist) / this.pinch.dist, cx, cy);
      }
    });
    const up = (e: PointerEvent) => {
      const tap = this.tap;
      this.tap = undefined;
      if (e.type === "pointerup" && tap?.id === e.pointerId && this.pointers.size === 1) {
        const p = this.local(e);
        if (Math.hypot(p.x - tap.x, p.y - tap.y) < 6) this.tapAt(p);
      }
      this.pointers.delete(e.pointerId);
      if (this.pointers.size < 2) this.pinch = undefined;
    };
    v.addEventListener("pointerup", up);
    v.addEventListener("pointercancel", up);
    v.addEventListener("keydown", (e) => {
      const step = 60;
      const keys: Record<string, () => void> = {
        "+": () => this.zoomBy(1.25), "=": () => this.zoomBy(1.25), "-": () => this.zoomBy(1 / 1.25),
        "0": () => this.fitWidth(), "1": () => this.setZoom(1),
        ArrowUp: () => this.panBy(0, step), ArrowDown: () => this.panBy(0, -step),
        ArrowLeft: () => this.panBy(step, 0), ArrowRight: () => this.panBy(-step, 0),
        PageUp: () => this.panBy(0, v.clientHeight * 0.9), PageDown: () => this.panBy(0, -v.clientHeight * 0.9),
        " ": () => this.panBy(0, -v.clientHeight * 0.9),
        Home: () => { this.y = 16; this.clampPan(); this.schedule(); },
        End: () => { this.y = -Infinity; this.clampPan(); this.schedule(); },
      };
      const f = keys[e.key];
      if (f && !e.ctrlKey && !e.metaKey && !e.altKey) {
        e.preventDefault();
        f();
      }
    });
  }

  /** A tap at viewport point `p`: plays the topmost video or recording under it. */
  private tapAt(p: { x: number; y: number }): void {
    const x = (p.x - this.x) / this.z, y = (p.y - this.y) / this.z;
    topmostPlayable(this.playables, x, y)?.play();
  }

  /** Scrolls so page `number` (1-based) is at the top. */
  showPage(number: number): void {
    const slot = this.slots[number - 1];
    if (!slot) return;
    this.y = 16 - slot.top * this.z;
    this.clampPan();
    this.schedule();
  }
}

const panMargin = 40;

/**
 * The horizontal offset of content `w` wide in a viewport `vw` wide: centred (no sideways pan at
 * all) while the content fits, otherwise free within `panMargin` of either edge.
 */
export function clampX(x: number, w: number, vw: number): number {
  return w <= vw ? (vw - w) / 2 : Math.min(panMargin, Math.max(vw - w - panMargin, x));
}

/** The vertical offset of content `ht` tall in a viewport `vh` tall, within `panMargin` of the ends. */
export function clampY(y: number, ht: number, vh: number): number {
  return Math.min(panMargin, Math.max(Math.min(vh - ht - panMargin, panMargin), y));
}

/** A video or audio item drawn on a page, and what a tap on it plays. */
export interface Playable {
  slot: { left: number; top: number };
  it: { corners: { x: number; y: number }[] };
  play: () => void;
}

/**
 * The playable item a tap at content point (`x`, `y`) hits: the last drawn (topmost) one whose
 * rotated frame holds the point, so a video drawn over an audio card plays, and the other way round.
 */
export function topmostPlayable<T extends Playable>(playables: readonly T[], x: number, y: number): T | undefined {
  for (let i = playables.length - 1; i >= 0; i--) {
    const p = playables[i];
    if (p && insidePolygon({ x: x - p.slot.left, y: y - p.slot.top }, p.it.corners)) return p;
  }
  return undefined;
}

/** True when `p` lies inside the convex polygon `c` (a rotated frame, either winding). */
export function insidePolygon(p: { x: number; y: number }, c: { x: number; y: number }[]): boolean {
  let sign = 0;
  for (let i = 0; i < c.length; i++) {
    const a = c[i], b = c[(i + 1) % c.length];
    if (!a || !b) return false;
    const cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
    if (cross === 0) continue;
    if (sign === 0) sign = Math.sign(cross);
    else if (Math.sign(cross) !== sign) return false;
  }
  return c.length > 2;
}

/** True when some page uses a paper kind this viewer does not know (drawn blank, §5.4.2). */
export function hasUnknownPaper(state: NoteState): boolean {
  const known = (p: Paper) => paperKind(p) === p.kindName;
  return !known(state.meta.paper) || state.pages.some((p) => p.paper !== undefined && !known(p.paper));
}
