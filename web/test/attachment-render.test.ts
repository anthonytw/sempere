// Rendering rules of attachments: image headers and metadata stripping
// (format.md §8.2.5), placement and orientation (§8.5.1), placeholders
// (§8.5.2), text layout (§8.5.3) and transcripts (§8.3.2).

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { DecodeError } from "../src/format/json.ts";
import { decodeTranscript } from "../src/format/transcript.ts";
import { ImageFormatError, imageInfo, stripMetadata } from "../src/render/images.ts";
import {
  apply, coef, corners, imageTransform, orientation, orientedSize, placeholderCommands, placement, prepareItem, rotate,
} from "../src/render/items.ts";
import { resolveItems, textNode } from "../src/render/itemsvg.ts";
import { PreparedPage } from "../src/render/page.ts";
import {
  type RunStyle, type TextContent, approximateMeasure, breakOpportunities, layoutText, lineAnchor, paragraphIsRTL, textContent, validBreaks,
} from "../src/render/text.ts";
import type { NoteMeta, Page } from "../src/format/model.ts";
import { webFixtures } from "./support.ts";

const media = join(webFixtures, "media");
const photo = new Uint8Array(readFileSync(join(media, "photo.jpg")));
const dot = new Uint8Array(readFileSync(join(media, "dot.png")));

function has(hay: Uint8Array, needle: string): boolean {
  return Buffer.from(hay).includes(Buffer.from(needle, "latin1"));
}

function imageError(f: () => unknown): string {
  try {
    f();
    return "ok";
  } catch (e) {
    if (e instanceof ImageFormatError) return e.message;
    throw e;
  }
}

describe("images", () => {
  it("reads sizes from JPEG and PNG headers", () => {
    expect(imageInfo(photo)).toEqual({ format: "jpeg", width: 48, height: 32, type: "image/jpeg" });
    expect(imageInfo(dot)).toEqual({ format: "png", width: 20, height: 12, type: "image/png" });
  });

  it("strips metadata but keeps the image data", () => {
    expect(has(photo, "Exif") && has(photo, "synthetic test image")).toBe(true);
    const clean = stripMetadata(photo);
    expect(has(clean, "Exif") || has(clean, "synthetic test image")).toBe(false);
    expect(imageInfo(clean)).toEqual(imageInfo(photo));
    expect([...clean.subarray(0, 4)]).toEqual([0xff, 0xd8, 0xff, 0xe0]);
    expect([...clean.subarray(clean.length - 2)]).toEqual([0xff, 0xd9]);
    expect(has(dot, "tEXt")).toBe(true);
    const png = stripMetadata(dot);
    expect(has(png, "tEXt")).toBe(false);
    expect(has(png, "IDAT") && has(png, "IEND")).toBe(true);
    // Idempotent.
    expect(stripMetadata(clean)).toEqual(clean);
  });

  it("adds a missing EOI and drops what follows EOI", () => {
    const cut = photo.subarray(0, photo.length - 2);
    expect([...stripMetadata(cut).subarray(-2)]).toEqual([0xff, 0xd9]);
    const trailer = new Uint8Array([...photo, ...Buffer.from("APPENDED PREVIEW")]);
    expect(has(stripMetadata(trailer), "APPENDED")).toBe(false);
  });

  it("refuses what the format does not allow, and HEIC", () => {
    const sof = (code: number, precision: number, comps: number) => Uint8Array.from([0xff, 0xd8, 0xff, code, 0, 8 + 3 * comps, precision, 0, 16, 0, 16, comps,
      ...Array.from({ length: comps * 3 }, () => 1), 0xff, 0xd9]);
    expect(imageError(() => imageInfo(sof(0xc0, 8, 3)))).toBe("ok");
    expect(imageError(() => imageInfo(sof(0xc0, 8, 4)))).toMatch(/CMYK/);
    expect(imageError(() => imageInfo(sof(0xc0, 12, 3)))).toMatch(/12-bit/);
    expect(imageError(() => imageInfo(sof(0xc9, 8, 3)))).toMatch(/arithmetic/);
    expect(imageError(() => imageInfo(Uint8Array.from([0, 0, 0, 24, ...Buffer.from("ftypheic")])))).toMatch(/HEIC/);
    expect(imageError(() => imageInfo(Buffer.from("GIF89a")))).toMatch(/unsupported/);
    expect(imageError(() => imageInfo(photo.subarray(0, 10)))).not.toBe("ok");
  });

  it("refuses images over the pixel limits before decoding", () => {
    const big = Uint8Array.from([0xff, 0xd8, 0xff, 0xc0, 0, 17, 8, 0xff, 0xff, 0xff, 0xff, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0xff, 0xd9]);
    expect(imageError(() => imageInfo(big))).toMatch(/MP limit/);
    expect(imageError(() => imageInfo(photo, 100))).toMatch(/MP limit/);
  });
});

describe("placement (§8.5.1)", () => {
  it("orients stored pixels as the table says", () => {
    const w = 4, h = 3;
    const table: Record<number, (a: number, b: number) => [number, number]> = {
      1: (a, b) => [a, b], 2: (a, b) => [w - a, b], 3: (a, b) => [w - a, h - b], 4: (a, b) => [a, h - b],
      5: (a, b) => [b, a], 6: (a, b) => [h - b, a], 7: (a, b) => [h - b, w - a], 8: (a, b) => [b, w - a],
    };
    for (let o = 1; o <= 8; o++) {
      const m = orientation(o, w, h);
      for (const [a, b] of [[0, 0], [1, 2], [4, 3]] as [number, number][]) {
        const p = apply(m, { x: a, y: b });
        expect([p.x, p.y]).toEqual((table[o] as (a: number, b: number) => [number, number])(a, b));
      }
      expect(orientedSize(o, w, h)).toEqual(o >= 5 ? { w: h, h: w } : { w, h });
    }
  });

  it("maps the crop onto the frame, then rotates clockwise about its centre", () => {
    const m = placement({ x: 10, y: 20, w: 100, h: 50 }, { x: 0, y: 0, w: 200, h: 100 }, 0);
    expect(apply(m, { x: 10, y: 20 })).toEqual({ x: 0, y: 0 });
    expect(apply(m, { x: 110, y: 70 })).toEqual({ x: 200, y: 100 });
    const r = rotate({ x: 0, y: 0, w: 200, h: 100 }, 90);
    // Clockwise on a y-down page: the top-left corner goes to the top right.
    expect(apply(r, { x: 0, y: 0 })).toEqual({ x: 150, y: -50 });
    expect(corners({ x: 0, y: 0, w: 2, h: 2 }, 180).map((p) => [p.x, p.y])).toEqual([[2, 2], [0, 2], [0, 0], [2, 0]]);
  });

  it("places an image with orientation, crop and rotation like the CLI", () => {
    const it = prepareItem({ id: "x", kind: "image", frame: [260, 72, 64, 96], z: "a", rotation: 15, orientation: 6, crop: [4, 8, 24, 36], pixelSize: [32, 48] });
    if (typeof it === "string") throw new Error(it);
    const m = imageTransform(it, 48, 32);
    if (typeof m === "string") throw new Error(m);
    // Swift: matrix(-0.690184 2.576 -2.576 -0.690184 351.158 64.072) (test/golden/render/7777…/p001.svg).
    expect([m.a, m.b, m.c, m.d].map(coef)).toEqual(["-0.690184", "2.576", "-2.576", "-0.690184"]);
    expect(m.tx).toBeCloseTo(351.158, 3);
    expect(m.ty).toBeCloseTo(64.072, 3);
    expect(imageTransform(it, 4, 4)).toBe("crop lies outside the image");
  });

  it("skips items that cannot be drawn, and draws unknown kinds as placeholders", () => {
    expect(typeof prepareItem({ id: "x", kind: "image", frame: [0, 0, 0, 10], z: "a" })).toBe("string");
    expect(typeof prepareItem({ id: "x", kind: "image", frame: [0, 300_000, 10, 10], z: "a" })).toBe("string");
    expect(typeof prepareItem({ id: "x", kind: "image", frame: [0, 0, 10, 10], z: "a", rotation: Infinity })).toBe("string");
    const p = placeholderCommands(corners({ x: 0, y: 0, w: 10, h: 10 }, 0));
    expect(p.map((c) => c.primitive.kind)).toEqual(["path", "line", "line"]);
    expect(p.every((c) => c.stroke?.r === 0x9a && c.lineWidth === 1)).toBe(true);
    const meta = { pageSize: { width: 100, height: 100, infinite: false }, paper: { kindName: "blank", background: "#FFFFFFFF" } } as unknown as NoteMeta;
    const page = { id: "p", order: "a", strokes: [], items: [
      { id: "b", kind: "sticker", frame: [0, 0, 10, 10], z: "a", layer: 0 },
      { id: "a", kind: "math", frame: [0, 0, 10, 10], z: "a" },
    ] } as unknown as Page;
    const resolved = resolveItems(new PreparedPage(page, meta));
    expect(resolved.map((r) => [r.draw.kind, r.fill !== undefined])).toEqual([["placeholder", true], ["placeholder", false]]);
  });

  it("draws an equation's render as a transparent PDF page, else its source as monospace text (§8.2.8)", () => {
    const meta = { pageSize: { width: 300, height: 200, infinite: false }, paper: { kindName: "blank", background: "#FFFFFFFF" } } as unknown as NoteMeta;
    const render = { sha256: "ab".repeat(32), size: 10, type: "application/pdf" };
    const page = { id: "p", order: "a", strokes: [], items: [
      { id: "a", kind: "math", frame: [10, 10, 120, 24], z: "a", math: { latex: "x^2+1", display: true, size: 14, color: "#1A1A1AFF" } },
      { id: "b", kind: "math", frame: [10, 60, 60, 24], z: "b", rotation: 90,
        math: { latex: "y", display: false, size: 12, color: "#B00020FF", render, renderSize: [30, 12] } },
    ] } as unknown as Page;
    const [a, b] = resolveItems(new PreparedPage(page, meta)).map((r) => r.draw);
    if (a?.kind !== "text" || b?.kind !== "pdf") throw new Error(`${a?.kind} ${b?.kind}`);
    expect(a.content.font).toBe("mono");
    expect(a.content.color).toBe("#1A1A1AFF");
    expect(a.layout.lines.map((l) => l.text)).toEqual(["x^2+1"]);
    expect(b.pageIndex).toBe(0);
    expect(b.pageSize).toEqual({ w: 30, h: 12 });
    expect(b.ref.sha256).toBe("ab".repeat(32));
    expect(b.it.rotation).toBe(90);
    expect(b.math?.content.runs.map((r) => r.t)).toEqual(["y"]);
    expect(b.math?.content.size).toBe(12);
  });

  it("counts items toward the extent: infinite pages, and below a finite page", () => {
    const item = { id: "a", kind: "image", frame: [0, 900, 10, 10], z: "a", rotation: 45 };
    const meta = (infinite: boolean) => ({ pageSize: { width: 100, height: 200, infinite }, paper: { kindName: "blank", background: "#FFFFFFFF" } }) as unknown as NoteMeta;
    const page = { id: "p", order: "a", strokes: [], items: [item] } as unknown as Page;
    expect(new PreparedPage(page, meta(true)).extent).toBe(Math.ceil(905 + 5 * Math.SQRT2));
    expect(new PreparedPage(page, meta(false)).extent).toBe(Math.ceil(905 + 5 * Math.SQRT2));
    const inside = { ...page, items: [{ ...item, frame: [0, 100, 10, 100] }] } as unknown as Page;
    expect(new PreparedPage(inside, meta(false)).extent).toBe(200);
  });
});

function content(runs: [string, Partial<RunStyle>?][], extra: Partial<TextContent> = {}): TextContent {
  const style = (s: Partial<RunStyle> = {}): RunStyle => ({ size: 10, color: "#000000FF", bold: false, italic: false, underline: false, strike: false, ...s });
  return { font: "sans", size: 10, color: "#000000FF", align: "start", dir: "auto", runs: runs.map(([t, s]) => ({ t, style: style(s) })), ...extra };
}

const frame = { x: 10, y: 100, w: 50, h: 20 };
const lines = (c: TextContent, w = frame.w) => layoutText(c, { ...frame, w }).lines.map((l) => l.text);
const scalars = (s: string) => [...s].map((c) => c.codePointAt(0) ?? 0);

describe("text layout (§8.5.3)", () => {
  it("cuts lines exactly at valid stored breaks, whatever the widths", () => {
    const c = content([["one two three four"]], { breaks: [4, 14] });
    expect(lines(c, 1)).toEqual(["one", "two three", "four"]);
    expect(layoutText(c, frame).storedBreaks).toBe(true);
  });

  it("ignores breaks that are not strictly increasing, at a line feed, or inside a cluster", () => {
    const s = scalars("ab\ncd");
    const c = (b: number[]) => validBreaks(content([["ab\ncd"]], { breaks: b }), s);
    expect(c([1, 4])).toEqual([1, 4]);
    for (const bad of [[0], [2], [3], [5], [1, 1], [4, 1]]) expect(c(bad)).toBeUndefined();
    const accent = `e${String.fromCodePoint(0x301)}x`;
    expect(validBreaks(content([[accent]], { breaks: [1] }), scalars(accent))).toBeUndefined();
    expect(validBreaks(content([[accent]], { breaks: [2] }), scalars(accent))).toEqual([2]);
  });

  it("uses the format's vertical metrics: 1.2 S per line, baseline at 0.95 S", () => {
    const l = layoutText(content([["small "], ["Big", { size: 20 }], ["\n\nend"]], { breaks: [6] }), frame).lines;
    expect(l.map((x) => [x.text, x.size, x.top, x.baseline])).toEqual([
      ["small", 10, 100, 109.5], ["Big", 20, 112, 131], ["end", 10, 112 + 24 + 12, 112 + 24 + 12 + 9.5],
    ]);
  });

  it("sizes an empty line by the run holding its line feed", () => {
    const l = layoutText(content([["a\n"], ["\n", { size: 30 }], ["b"]]), frame).lines;
    expect(l.map((x) => x.top)).toEqual([100, 100 + 12 + 36]);
  });

  it("drops trailing white space and draws a tab as four spaces", () => {
    const l = layoutText(content([["a\tb   "]]), { ...frame, w: 1000 }).lines;
    expect(l[0]?.text).toBe("a\tb");
    expect(l[0]?.pieces.map((p) => p.text)).toEqual(["a    b"]);
  });

  it("breaks greedily without stored breaks: spaces, hyphens, CJK, then clusters", () => {
    // approximateMeasure: 5 pt per character at size 10.
    expect(lines(content([["aaa bbb ccc"]]), 40)).toEqual(["aaa bbb", "ccc"]);
    expect(lines(content([["well-known word"]]), 30)).toEqual(["well-", "known", "word"]);
    const cjk = String.fromCodePoint(0x6f22, 0x5b57, 0x6f22, 0x5b57);
    expect(lines(content([[cjk]]), 20)).toEqual([String.fromCodePoint(0x6f22, 0x5b57), String.fromCodePoint(0x6f22, 0x5b57)]);
    expect(lines(content([["abcdefghij"]]), 20)).toEqual(["abcd", "efgh", "ij"]);
    expect(breakOpportunities(scalars("a b"))).toEqual([{ index: 2, mandatory: false }, { index: 3, mandatory: true }]);
    // No break after a no-break space.
    expect(breakOpportunities(scalars(`a${String.fromCodePoint(0xa0)}b`))).toEqual([{ index: 3, mandatory: true }]);
  });

  it("takes an auto paragraph's direction from its first letter", () => {
    expect(paragraphIsRTL(scalars("123 abc"))).toBe(false);
    expect(paragraphIsRTL(scalars(`12 ${String.fromCodePoint(0x5e9, 0x5dc, 0x5d5, 0x5dd)} abc`))).toBe(true);
    expect(paragraphIsRTL(scalars(String.fromCodePoint(0x627, 0x644)))).toBe(true);
    expect(paragraphIsRTL(scalars("!?"))).toBe(false);
    const l = layoutText(content([[`abc\n${String.fromCodePoint(0x5d0)}`]], { dir: "auto" }), frame).lines;
    expect(l.map((x) => x.rtl)).toEqual([false, true]);
    expect(layoutText(content([["abc"]], { dir: "rtl" }), frame).lines[0]?.rtl).toBe(true);
  });

  it("lays out many paragraphs and long words in linear time (§9)", () => {
    const t0 = performance.now();
    expect(layoutText(content([["a\n".repeat(32_768)]]), frame).lines.length).toBe(32_768);
    expect(layoutText(content([["ab\n".repeat(21_845)]], { breaks: [1] }), frame).lines.length).toBe(21_846);
    expect(layoutText(content([["x".repeat(60_000)]]), { ...frame, w: 5000 }).lines.length).toBe(60);
    expect(performance.now() - t0).toBeLessThan(5_000);
  });

  it("anchors lines by alignment and direction", () => {
    const f = { x: 10, y: 0, w: 100, h: 10 };
    expect(lineAnchor("start", false, f)).toEqual({ x: 10, anchor: "start" });
    expect(lineAnchor("start", true, f)).toEqual({ x: 110, anchor: "start" });
    expect(lineAnchor("end", false, f)).toEqual({ x: 110, anchor: "end" });
    expect(lineAnchor("end", true, f)).toEqual({ x: 10, anchor: "end" });
    expect(lineAnchor("left", true, f)).toEqual({ x: 10, anchor: "end" });
    expect(lineAnchor("right", false, f)).toEqual({ x: 110, anchor: "end" });
    expect(lineAnchor("center", true, f)).toEqual({ x: 60, anchor: "middle" });
  });

  it("maps unknown values as renderers must", () => {
    const c = textContent({ text: { font: "fantasy", size: 12, color: "#000000FF", align: "justify", dir: "up", runs: [{ t: "x", b: true }] } });
    expect([c?.font, c?.align, c?.dir, c?.runs[0]?.style.bold]).toEqual(["sans", "start", "auto", true]);
    expect(approximateMeasure("ab", { size: 10 } as RunStyle, "sans")).toBe(10);
  });

  it("builds text nodes: one per drawn line, runs as tspans, rotation about the centre", () => {
    const item = prepareItem({ id: "t", kind: "text", frame: [0, 0, 100, 20], z: "a", rotation: 90, text: {} });
    if (typeof item === "string") throw new Error(item);
    const c = content([["bold", { bold: true }], [" plain\n\nx", { underline: true, strike: true, lang: "de" }]], { lang: "en" });
    const n = textNode(item, c, layoutText(c, item.frame));
    expect(n.attrs).toEqual([["transform", "matrix(0 1 -1 0 60 -40)"]]);
    expect(n.children?.map((t) => t.children?.map((s) => s.text))).toEqual([["bold", " plain"], ["x"]]);
    const plain = n.children?.[0]?.children?.[1]?.attrs ?? [];
    expect(plain).toContainEqual(["text-decoration", "underline line-through"]);
    expect(plain).toContainEqual(["lang", "de"]);
    expect(n.children?.[0]?.children?.[0]?.attrs).toContainEqual(["font-weight", "bold"]);
  });
});

describe("transcripts (§8.3.2)", () => {
  const rec = "11111111-1111-4111-8111-111111111111";
  const base = {
    format: "sempere-transcript/1", recording: rec, engine: "e", language: "en", created: "2026-10-04T17:21:00Z",
    segments: [{ start: 0, end: 1, text: "a b", words: [{ t: "a", start: 0, end: 0.5, c: 0.9 }, { t: "b", start: 0.5, end: 1 }] },
      { start: 1, end: 2, text: "c", confidence: 1 }],
  };
  const decode = (v: unknown, id = rec) => {
    try {
      return decodeTranscript(new TextEncoder().encode(JSON.stringify(v)), id).segments.length;
    } catch (e) {
      if (e instanceof DecodeError) return e.message;
      throw e;
    }
  };

  it("decodes a valid transcript", () => {
    expect(decode(base)).toBe(2);
  });

  it("rejects every rule §8.3.2 states", () => {
    const seg = (s: unknown[]) => ({ ...base, segments: s });
    expect(decode({ ...base, format: "sempere-transcript/2" })).toMatch(/format/);
    expect(decode(base, "22222222-2222-4222-8222-222222222222")).toMatch(/another recording/);
    expect(decode({ ...base, created: "yesterday" })).toMatch(/date/);
    expect(decode(seg([{ start: 2, end: 1, text: "" }]))).toMatch(/start after end/);
    expect(decode(seg([{ start: 0, end: 2, text: "" }, { start: 1, end: 3, text: "" }]))).toMatch(/overlapping/);
    expect(decode(seg([{ start: 0, end: 1, text: "", confidence: 1.5 }]))).toMatch(/confidence/);
    expect(decode(seg([{ start: 0, end: 1, text: "", words: [{ t: "x", start: 0.5, end: 1.5 }] }]))).toMatch(/word outside/);
    expect(decode(seg([{ start: 0, end: 1, text: "", words: [{ t: "x", start: 0.5, end: 0.6 }, { t: "y", start: 0.2, end: 0.3 }] }]))).toMatch(/words out of order/);
    expect(decode(seg([{ start: 0, end: 1, text: "", words: [{ t: "x", start: 0, end: 1, c: -0.1 }] }]))).toMatch(/word confidence/);
    expect(decodeTranscriptBytes(Uint8Array.of(0xff))).toMatch(/UTF-8/);
  });

  function decodeTranscriptBytes(b: Uint8Array): string {
    try {
      decodeTranscript(b, rec);
      return "ok";
    } catch (e) {
      return e instanceof DecodeError ? e.message : "other";
    }
  }
});
