// Tiny DOM builder. The viewer never parses markup (no innerHTML): every
// node is created with createElement / createElementNS and text is set as
// text, so note content can never become markup or script.

import { locale } from "../i18n/index.ts";

type Child = Node | string | null | undefined | false;

export interface Props {
  class?: string;
  text?: string;
  title?: string;
  attrs?: Record<string, string>;
  on?: Partial<{ [K in keyof HTMLElementEventMap]: (e: HTMLElementEventMap[K]) => void }>;
}

export function h<K extends keyof HTMLElementTagNameMap>(tag: K, props: Props = {}, ...children: Child[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  if (props.class) el.className = props.class;
  if (props.text !== undefined) el.textContent = props.text;
  if (props.title !== undefined) el.title = props.title;
  for (const [k, v] of Object.entries(props.attrs ?? {})) el.setAttribute(k, v);
  for (const [k, f] of Object.entries(props.on ?? {})) el.addEventListener(k, f as EventListener);
  for (const c of children) if (c !== null && c !== undefined && c !== false) el.append(c);
  return el;
}

export const svgNS = "http://www.w3.org/2000/svg";

/** Attributes the renderer emits; anything else is refused (defence in depth). */
const allowedSVGAttrs = new Set([
  "x", "y", "width", "height", "x1", "y1", "x2", "y2", "cx", "cy", "r", "points", "d", "fill", "fill-opacity",
  "stroke", "stroke-opacity", "stroke-width", "stroke-linecap", "stroke-linejoin", "viewBox",
  // Items (format.md §8.2): clips, placed images, text.
  "id", "transform", "clip-path", "preserveAspectRatio", "href", "font-family", "font-size", "font-weight", "font-style",
  "text-decoration", "text-anchor", "direction", "unicode-bidi", "lang", "xml:space",
]);
const allowedSVGTags = new Set(["svg", "g", "rect", "line", "circle", "polyline", "path", "polygon", "clipPath", "image", "text", "tspan"]);
const xmlNS = "http://www.w3.org/XML/1998/namespace";

export function s(tag: string, attrs: [string, string][] = []): SVGElement {
  if (!allowedSVGTags.has(tag)) throw new Error(`unexpected SVG element ${tag}`);
  const el = document.createElementNS(svgNS, tag);
  for (const [k, v] of attrs) {
    if (!allowedSVGAttrs.has(k)) throw new Error(`unexpected SVG attribute ${k}`);
    // Images only ever show blobs the page made from verified attachments.
    if (k === "href" && !v.startsWith("blob:")) throw new Error("unexpected image reference");
    if (k === "clip-path" && !/^url\(#[\w-]+\)$/.test(v)) throw new Error("unexpected clip reference");
    if (k === "xml:space") el.setAttributeNS(xmlNS, k, v);
    else el.setAttribute(k, v);
  }
  return el;
}

/** An SVG element tree: tags and attributes through `s`, text as text. */
export function svgTree(n: { tag: string; attrs: [string, string][]; text?: string; children?: typeof n[] }): SVGElement {
  const el = s(n.tag, n.attrs);
  if (n.text !== undefined) el.textContent = n.text;
  for (const c of n.children ?? []) el.append(svgTree(c));
  return el;
}

export function clear(el: Element): void {
  el.replaceChildren();
}

export function formatDate(ms: number | undefined): string {
  if (ms === undefined) return "";
  return new Date(ms).toLocaleString(locale(), { dateStyle: "medium", timeStyle: "short" });
}
