// Writes web/test/fixtures/render.sempere: a vault encrypted to the throwaway
// test recipient of Tests/SempereTests/Fixtures/sample.key, whose notes
// exercise the renderer (every paper kind, every tool, transforms, an infinite
// page) and the merge (two devices, a snapshot, tags, removals, an orphan,
// attachments, unknown fields). Synthetic content only.
//
// Run: npm run fixture (from web/). age encryption is randomized, so the
// ciphertext changes on every run; the decrypted JSON does not. Then run
// scripts/golden.sh to export the Swift CLI's view of it.

import { armor, identityToRecipient } from "age-encryption";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createVaultWriter, type Ref } from "./fixture-lib.ts";

const web = join(import.meta.dirname, "..");
const keyFile = join(web, "..", "Tests", "SempereTests", "Fixtures", "sample.key");
const out = join(web, "test", "fixtures", "render.sempere");

const identity = readFileSync(keyFile, "utf8").split("\n").find((l) => l.startsWith("AGE-SECRET-KEY-PQ-"));
if (!identity) throw new Error("no identity in sample.key");
const recipient = await identityToRecipient(identity);

// A fixed secret: the fixture is test-only, and a stable secret keeps the tags stable.
const secret = new Uint8Array(32).map((_, i) => (i * 7 + 3) & 0xff);

const enc = new TextEncoder();
const { encrypt, frame, blobName, writeBlob } = createVaultWriter({ secret, out, recipient });

const devA = "a1b2c3d4", devB = "99ee00ff";
const t0 = Date.UTC(2026, 9, 4, 16, 20, 0);

function hlc(offsetSeconds: number, counter = 0): string {
  return String(t0 + offsetSeconds * 1000).padStart(13, "0") + String(counter).padStart(4, "0");
}

function wall(offsetSeconds: number): string {
  return new Date(t0 + offsetSeconds * 1000).toISOString();
}

type Json = Record<string, unknown>;

async function write(noteId: string, rev: Json): Promise<void> {
  const name = `${rev.hlc as string}-${rev.device as string}-${rev.seq as number}.${rev.type as string}.age`;
  const dir = join(out, "notes", noteId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, name), await encrypt(await frame(rev, noteId, name)));
}

function delta(noteId: string, device: string, seq: number, at: number, ops: Json[]): Json {
  return { type: "delta", noteId, device, seq, hlc: hlc(at), wall: wall(at), app: "sempere-web-fixture/1", ops };
}

function id(n: number): string {
  return `f1c70000-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;
}

/** A wavy line of control points. */
function wave(x0: number, y0: number, len: number, opts: { w?: number; o?: number; n?: number; amp?: number } = {}): number[][] {
  const n = opts.n ?? 24;
  return Array.from({ length: n }, (_, i) => {
    const x = x0 + (len * i) / (n - 1);
    const y = y0 + Math.round(Math.sin(i / 2.5) * (opts.amp ?? 8) * 1000) / 1000;
    const w = opts.w ?? 2 + (i % 5) * 0.5;
    return [Math.round(x * 1000) / 1000, y, i * 0.01, w, w, opts.o ?? 1, 0.5, 0.3, 1.2];
  });
}

function stroke(n: number, tool: string, color: string, width: number, points: number[][], extra: Json = {}): Json {
  return { id: id(n), ink: { tool, color, width }, points, ...extra };
}

const letter = { width: 612, height: 792, infinite: false };

rmSync(out, { recursive: true, force: true });
mkdirSync(join(out, "notes"), { recursive: true });

// --- Note 1: every paper kind, one page each, and every tool.
{
  const note = "33333333-3333-4333-8333-333333333333";
  const papers: Json[] = [
    { kind: "blank", spacing: 24, background: "#FFF8E1FF", lineColor: "#D0D8E8FF" },
    { kind: "ruled", spacing: 24, background: "#FFFFFFFF", lineColor: "#D0D8E8FF", marginLeft: 60, marginTop: 50 },
    { kind: "marginRuled", spacing: 20, background: "#FFFFFFFF", lineColor: "#C0C8D8FF" },
    { kind: "grid", spacing: 18, background: "#FFFFFF", lineColor: "#D0D8E880", lineWidth: 0.25 },
    { kind: "dot", spacing: 18, background: "#FFFFFFFF", lineColor: "#9AA3B5FF", dotRadius: 1.2 },
    { kind: "isoDot", spacing: 20, background: "#FFFFFFFF", lineColor: "#9AA3B5FF" },
    { kind: "isoGrid", spacing: 20, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" },
    { kind: "cornell", spacing: 24, background: "#FFFFFFFF", lineColor: "#D0D8E8FF", cueWidth: 140, summaryHeight: 100 },
    { kind: "staff", spacing: 24, background: "#FFFFFFFF", lineColor: "#9AA3B5FF", staffSpacing: 8, staffGap: 36 },
    // Out of range and an unknown kind: readers clamp, and draw an unknown kind as blank (§5.4.2).
    { kind: "ruled", spacing: 24, background: "#1C1C1EFF", lineColor: "#444444FF", lineWidth: 9, marginLeft: 900 },
    { kind: "hexagons", spacing: 30, background: "#E8F5E9FF", lineColor: "#D0D8E8FF", hexSize: 12 },
    { kind: "grid", spacing: 2, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" },
  ];
  const ops: Json[] = [
    { op: "setMeta", field: "title", value: "Papers & tools <test>" },
    { op: "setMeta", field: "paper", value: { kind: "ruled", spacing: 24, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" } },
    { op: "setMeta", field: "pageSize", value: letter },
    { op: "setMeta", field: "notebook", value: "Fixtures/Rendering" },
  ];
  papers.forEach((paper, i) => {
    const pid = id(0x100 + i);
    ops.push({ op: "addPage", page: { id: pid, order: `a${i.toString(36)}`, strokes: [] } });
    ops.push({ op: "setPagePaper", pageId: pid, paper });
  });
  const tools = ["pen", "pencil", "marker", "monoline", "fountainPen", "watercolor", "crayon", "brush"];
  tools.forEach((tool, i) => {
    ops.push({ op: "addStroke", page: id(0x100), stroke: stroke(0x200 + i, tool, i % 2 ? "#1A1A1AFF" : "#2E5BFFCC", 3, wave(60, 80 + i * 60, 480, { o: i === 1 ? 0.6 : 1 })) });
  });
  // Shapes that stress the outline: a dot, a monoline dot, repeated points,
  // zero widths (fallback to the ink width), a sharp zigzag, transforms.
  ops.push({ op: "addStroke", page: id(0x101), stroke: stroke(0x210, "pen", "#000000FF", 4, [[300, 300, 0, 6, 6, 1, 0, 0, 1.5]]) });
  ops.push({ op: "addStroke", page: id(0x101), stroke: stroke(0x211, "monoline", "#FF0000FF", 5, [[320, 300, 0, 2, 2, 1, 0, 0, 1.5], [320, 300, 0.1, 2, 2, 1, 0, 0, 1.5]]) });
  ops.push({ op: "addStroke", page: id(0x101), stroke: stroke(0x212, "pen", "#006400FF", 3, [[100, 400, 0, 0, 0, 1, 0, 0, 1], [100, 400, 0, 0, 0, 1, 0, 0, 1], [200, 450, 0, 0, 0, 1, 0, 0, 1], [300, 400, 0, 4, 4, 0.5, 0, 0, 1]]) });
  ops.push({ op: "addStroke", page: id(0x101), stroke: stroke(0x213, "pen", "#800080FF", 2, [[80, 600, 0, 3, 3, 1, 0, 0, 1], [120, 500, 0, 3, 3, 1, 0, 0, 1], [160, 600, 0, 3, 3, 1, 0, 0, 1], [200, 500, 0, 3, 3, 1, 0, 0, 1], [240, 600, 0, 3, 3, 1, 0, 0, 1]]) });
  ops.push({ op: "addStroke", page: id(0x102), stroke: stroke(0x214, "pen", "#000000FF", 2, wave(100, 200, 200), { transform: [1.5, 0.5, -0.5, 1.5, 40, 30] }) });
  ops.push({ op: "addStroke", page: id(0x102), stroke: stroke(0x215, "monoline", "#000000FF", 2, wave(100, 500, 200), { transform: [0.5, 0, 0, 0.5, 100, 100] }) });
  ops.push({ op: "addStroke", page: id(0x103), stroke: stroke(0x216, "marker", "#FFEB3B80", 12, wave(60, 300, 480, { w: 14, n: 40, amp: 2 })) });
  // A stroke with an unknown future field and a recording link (§7, §5.6).
  ops.push({ op: "addStroke", page: id(0x104), stroke: stroke(0x217, "pen", "#000000FF", 2, wave(60, 300, 300), { pressureCurve: [0, 1], rec: { id: id(0x900), at: 1.25 } }) });
  await write(note, delta(note, devA, 1, 1, ops));
}

// --- Note 2: an infinite page with ink far below its stored height.
{
  const note = "44444444-4444-4444-8444-444444444444";
  const pid = id(0x300);
  await write(note, delta(note, devA, 1, 2, [
    { op: "setMeta", field: "title", value: "Infinite cornell" },
    { op: "setMeta", field: "paper", value: { kind: "cornell", spacing: 24, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" } },
    { op: "setMeta", field: "pageSize", value: { width: 600, height: 900, infinite: true, breakHeight: 700 } },
    { op: "addPage", page: { id: pid, order: "a0", strokes: [] } },
    { op: "addStroke", page: pid, stroke: stroke(0x301, "pen", "#000000FF", 2, wave(200, 100, 300)) },
    { op: "addStroke", page: pid, stroke: stroke(0x302, "pen", "#B00020FF", 2, wave(200, 2500, 300)) },
  ]));
  // A second infinite page with no breakHeight and dot paper on the page itself.
  const pid2 = id(0x303);
  await write(note, delta(note, devB, 1, 3, [
    { op: "addPage", page: { id: pid2, order: "a1", strokes: [] } },
    { op: "setPagePaper", pageId: pid2, paper: { kind: "dot", spacing: 24, background: "#FFFFFFFF", lineColor: "#9AA3B5FF", marginLeft: 50 } },
    { op: "addStroke", page: pid2, stroke: stroke(0x304, "pencil", "#333333FF", 1.5, wave(50, 1800, 500)) },
  ]));
}

// --- Note 3: merging. Two devices, a snapshot, removals, page order,
// recognition, tags (legacy and per-tag), an orphan, attachments.
{
  const note = "55555555-5555-4555-8555-555555555555";
  const p1 = id(0x400), p2 = id(0x401), p3 = id(0x402), ghost = id(0x4ff);
  const a1 = delta(note, devA, 1, 10, [
    { op: "setMeta", field: "title", value: "Merge lab" },
    { op: "setMeta", field: "tags", value: ["Physics", "fall  term", "physics"] },
    { op: "setMeta", field: "paper", value: { kind: "grid", spacing: 20, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" } },
    { op: "setMeta", field: "pageSize", value: letter },
    { op: "addPage", page: { id: p1, order: "a0", strokes: [] } },
    { op: "addPage", page: { id: p2, order: "a1", strokes: [] } },
    { op: "addStroke", page: p1, stroke: stroke(0x410, "pen", "#000000FF", 2, wave(60, 100, 400)) },
    { op: "addStroke", page: p1, stroke: stroke(0x411, "pen", "#000000FF", 2, wave(60, 200, 400)) },
    { op: "addStroke", page: p2, stroke: stroke(0x412, "pen", "#000000FF", 2, wave(60, 100, 400)) },
  ]);
  const b1 = delta(note, devB, 1, 11, [
    { op: "addTag", tag: "  Lab   notes " },
    { op: "addPage", page: { id: p3, order: "a0V", strokes: [] } },
    { op: "addStroke", page: p3, stroke: stroke(0x413, "marker", "#4CAF5080", 10, wave(60, 300, 400, { w: 10 })) },
    { op: "setPageRecognition", pageId: p1, recognition: { engine: "vision-26.7", text: "wave one\nwave two", words: [{ t: "wave", box: [60, 90, 40, 20] }], basis: "0123456789abcdef0123456789abcdef" } },
    { op: "setMeta", field: "favorite", value: true },
  ]);
  const a2 = delta(note, devA, 2, 12, [
    { op: "removeStroke", page: p1, strokeId: id(0x411) },
    { op: "setPageOrder", pageId: p2, order: "Z" },
    { op: "setMeta", field: "notebook", value: " School // Physics " },
  ]);
  // A snapshot on B covering A1, A2 and B1, written as Swift's makeSnapshot would.
  const snapState = {
    deleted: false,
    meta: {
      title: "Merge lab", tags: ["Physics", "fall term", "Lab notes"], notebook: " School // Physics ", favorite: true,
      created: wall(10), paper: { kind: "grid", spacing: 20, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" }, pageSize: letter,
    },
    pages: [
      { id: p2, order: "Z", orderClock: `${hlc(12)}-${devA}`, origin: `${hlc(10)}-${devA}-1-5`, strokes: [
        { ...stroke(0x412, "pen", "#000000FF", 2, wave(60, 100, 400)), origin: `${hlc(10)}-${devA}-1-8` }] },
      { id: p1, order: "a0", orderClock: `${hlc(10)}-${devA}`, origin: `${hlc(10)}-${devA}-1-4`,
        recognition: { engine: "vision-26.7", text: "wave one\nwave two", words: [{ t: "wave", box: [60, 90, 40, 20] }], basis: "0123456789abcdef0123456789abcdef" },
        recognitionClock: `${hlc(11)}-${devB}`, strokes: [
          { ...stroke(0x410, "pen", "#000000FF", 2, wave(60, 100, 400)), origin: `${hlc(10)}-${devA}-1-6` }] },
      { id: p3, order: "a0V", orderClock: `${hlc(11)}-${devB}`, origin: `${hlc(11)}-${devB}-1-1`, futurePageField: { x: 1 }, strokes: [
        { ...stroke(0x413, "marker", "#4CAF5080", 10, wave(60, 300, 400, { w: 10 })), origin: `${hlc(11)}-${devB}-1-2` }] },
    ],
    clocks: { title: `${hlc(10)}-${devA}`, notebook: `${hlc(12)}-${devA}`, favorite: `${hlc(11)}-${devB}`, paper: `${hlc(10)}-${devA}`, pageSize: `${hlc(10)}-${devA}`, deleted: "00000000000000000-00000000" },
    tagSet: {
      instances: [{ tag: "Physics", origin: `${hlc(10)}-${devA}-0-0` }, { tag: "fall term", origin: `${hlc(10)}-${devA}-0-1` },
        { tag: "Lab notes", origin: `${hlc(11)}-${devB}-1-0` }],
      removed: [],
      legacy: { tags: ["Physics", "fall  term", "physics"], clock: `${hlc(10)}-${devA}` },
    },
  };
  const b2 = { type: "snapshot", noteId: note, device: devB, seq: 2, hlc: hlc(13), wall: wall(13), app: "sempere-web-fixture/1",
    included: { [devA]: { upTo: 2, extra: [] }, [devB]: { upTo: 2, extra: [] } }, state: snapState };
  // After the snapshot: A removes a tag it saw, adds one, removes page p3,
  // deletes and restores the note; B (concurrently) adds a stroke to a page
  // nobody has seen (an orphan), an item and a recording.
  const a3 = delta(note, devA, 3, 14, [
    { op: "removeTag", tag: "FALL TERM", observed: [`${hlc(10)}-${devA}-0-1`] },
    { op: "addTag", tag: "Optics" },
    { op: "removePage", pageId: p3 },
    { op: "deleteNote" },
    { op: "restoreNote" },
    { op: "addStroke", page: p1, stroke: stroke(0x414, "fountainPen", "#0D47A1FF", 2.5, wave(60, 400, 450)) },
  ]);
  const b3 = delta(note, devB, 3, 14, [
    { op: "addStroke", page: ghost, stroke: stroke(0x415, "pen", "#000000FF", 2, wave(60, 500, 400)) },
    { op: "addItem", page: p1, item: { id: id(0x800), kind: "text", layer: 100, frame: [72, 600, 300, 40], z: "a0",
      text: { font: "sans", size: 14, color: "#1A1A1AFF", runs: [{ t: "Typed text", b: true }] } } },
    { op: "addRecording", recording: { id: id(0x900), blob: { sha256: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", size: 1000, type: "audio/mp4" },
      started: wall(14), duration: 12.5 } },
    { op: "setMeta", field: "title", value: "Merge lab (B)" },
  ]);
  for (const r of [a1, b1, a2, b2, a3, b3]) await write(note, r);
}

// --- Note 4: deleted, in a notebook, with a page that has no strokes.
{
  const note = "66666666-6666-4666-8666-666666666666";
  await write(note, delta(note, devB, 1, 20, [
    { op: "setMeta", field: "title", value: "Gone" },
    { op: "setMeta", field: "notebook", value: "Fixtures" },
    { op: "setMeta", field: "pageSize", value: { width: 595, height: 842, infinite: false } },
    { op: "addPage", page: { id: id(0x600), order: "a0", strokes: [] } },
    { op: "deleteNote" },
  ]));
}

// --- Blobs (format.md §8.1): framed, Padmé-padded, encrypted, under the keyed name.
const media = join(web, "test", "fixtures", "media");

function blobKind(type: string): string {
  return type.startsWith("image/") ? "image" : type === "application/pdf" ? "pdf" : type.startsWith("audio/") ? "audio"
    : type.startsWith("video/") ? "video"
    : type === "application/vnd.sempere.transcript+json" ? "transcript" : "bin";
}

/** Writes `content` as a blob of `noteId` (unless `skip`) and returns its reference. */
function blob(noteId: string, content: Uint8Array, type: string, opts: { skip?: boolean; asName?: string } = {}): Promise<Ref> {
  return writeBlob(noteId, content, type, blobKind(type), opts);
}

/** A small PDF written by hand: vector shapes and Helvetica text, page boxes and /Rotate per page. */
function makePDF(pages: { media: number[]; crop?: number[]; rotate?: number; content: string }[]): Uint8Array {
  const objs: string[] = [];
  const add = (body: string) => objs.push(body) - 1 + 1;
  const catalog = add("");
  const tree = add("");
  const font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
  const kids: number[] = [];
  for (const p of pages) {
    const stream = add(`<< /Length ${p.content.length} >>\nstream\n${p.content}\nendstream`);
    let page = `<< /Type /Page /Parent ${tree} 0 R /MediaBox [${p.media.join(" ")}] /Resources << /Font << /F1 ${font} 0 R >> >> /Contents ${stream} 0 R`;
    if (p.crop) page += ` /CropBox [${p.crop.join(" ")}]`;
    if (p.rotate) page += ` /Rotate ${p.rotate}`;
    kids.push(add(page + " >>"));
  }
  objs[catalog - 1] = `<< /Type /Catalog /Pages ${tree} 0 R >>`;
  objs[tree - 1] = `<< /Type /Pages /Kids [${kids.map((k) => `${k} 0 R`).join(" ")}] /Count ${kids.length} >>`;
  let pdf = "%PDF-1.4\n";
  const offsets: number[] = [];
  objs.forEach((body, i) => {
    offsets.push(pdf.length);
    pdf += `${i + 1} 0 obj\n${body}\nendobj\n`;
  });
  const xref = pdf.length;
  pdf += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of offsets) pdf += `${String(o).padStart(10, "0")} 00000 n \n`;
  pdf += `trailer\n<< /Size ${objs.length + 1} /Root ${catalog} 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return enc.encode(pdf);
}

// --- Note 5: attachments. Images (orientation, crop, rotation), PDF pages
// (background and figure, CropBox and /Rotate), text boxes (stored breaks,
// invalid breaks, runs, alignment, direction, rotation), placeholders
// (an unknown kind, missing, tampered and HEIC blobs), equations (with and
// without a rendering, §8.2.8), and recordings with a transcript.
{
  const note = "77777777-7777-4777-8777-777777777777";
  const p1 = id(0x700), p2 = id(0x701);
  const photo = await blob(note, readFileSync(join(media, "photo.jpg")), "image/jpeg");
  const dot = await blob(note, readFileSync(join(media, "dot.png")), "image/png");
  const pdf = await blob(note, makePDF([
    { media: [0, 0, 612, 792], content: "0.85 0.9 1 rg 36 36 540 720 re f 0.2 0.3 0.6 RG 4 w 72 600 m 540 680 l S BT /F1 36 Tf 0.1 0.1 0.1 rg 72 700 Td (Synthetic PDF page 1) Tj ET" },
    { media: [0, 0, 400, 300], crop: [20, 20, 380, 280], rotate: 90, content: "1 0.9 0.8 rg 0 0 400 300 re f 0.7 0.1 0.1 rg 40 40 120 80 re f BT /F1 24 Tf 0 0 0 rg 60 200 Td (Rotated page 2) Tj ET" },
  ]), "application/pdf");
  const missing = await blob(note, enc.encode("never written"), "image/png", { skip: true });
  const missingAudio = await blob(note, enc.encode("never written either"), "audio/mp4", { skip: true });
  // A valid blob file stored under another content's name: the name binding fails.
  const forged = await blob(note, readFileSync(join(media, "dot.png")).subarray(0, 100), "image/png", { skip: true });
  await blob(note, readFileSync(join(media, "dot.png")), "image/png", { asName: blobName(Buffer.from(forged.sha256, "hex")) });
  // An equation's rendering: one page, marks only in the equation's colour, no page fill (§8.2.8).
  const equation = await blob(note, makePDF([
    { media: [0, 0, 60, 24], content: "0.102 0.102 0.102 rg 4 10 26 4 re f 36 2 20 20 re f" },
  ]), "application/pdf");
  const heic = await blob(note, Uint8Array.from([0, 0, 0, 24, ...enc.encode("ftypheic"), 0, 0, 0, 0, ...enc.encode("mif1heic")]), "image/heic");
  const tone = await blob(note, readFileSync(join(media, "tone.m4a")), "audio/mp4");
  const rec1 = id(0x980), rec2 = id(0x981);
  const transcript = await blob(note, enc.encode(JSON.stringify({
    format: "sempere-transcript/1", recording: rec1, engine: "synthetic-1", language: "en-US", created: wall(31),
    segments: [
      { start: 0, end: 0.5, text: "A synthetic tone.", confidence: 0.9, words: [{ t: "A", start: 0, end: 0.1 }, { t: "synthetic", start: 0.1, end: 0.3, c: 0.4 }, { t: "tone.", start: 0.3, end: 0.5 }] },
      { start: 0.5, end: 1, text: "Still the tone." },
    ],
  })), "application/vnd.sempere.transcript+json");
  const storedRuns = [
    { t: "Stored breaks keep ", b: true }, { t: "these lines", i: true, color: "#B00020FF" }, { t: " exactly as the app laid them out. " },
    { t: "Big", size: 24, u: true }, { t: " and struck", s: true }, { t: "\n\nAfter a blank line\twith a tab." },
  ];
  const storedText = storedRuns.map((r) => r.t).join("");
  const text = (runs: Json[], extra: Json = {}) => ({ font: "sans", size: 14, color: "#1A1A1AFF", runs, ...extra });
  const item = (n: number, kind: string, layer: number, frame: number[], z: string, extra: Json = {}) =>
    ({ id: id(n), kind, layer, frame, z, ...extra });
  await write(note, delta(note, devA, 1, 30, [
    { op: "setMeta", field: "title", value: "Attachments" },
    { op: "setMeta", field: "paper", value: { kind: "ruled", spacing: 24, background: "#FFFDF5FF", lineColor: "#D0D8E8FF" } },
    { op: "setMeta", field: "pageSize", value: letter },
    { op: "addPage", page: { id: p1, order: "a0", strokes: [] } },
    { op: "addPage", page: { id: p2, order: "a1", strokes: [] } },
    // Page 1: a PDF page as the background, images, text, placeholders, ink on top.
    { op: "addItem", page: p1, item: item(0x710, "pdfPage", 0, [0, 0, 612, 792], "a0", { blob: pdf, pageIndex: 0, pageSize: [612, 792] }) },
    { op: "addItem", page: p1, item: item(0x711, "image", 100, [72, 72, 144, 96], "a0", { blob: photo, pixelSize: [48, 32] }) },
    { op: "addItem", page: p1, item: item(0x712, "image", 100, [260, 72, 64, 96], "a1", { blob: photo, pixelSize: [32, 48], orientation: 6, crop: [4, 8, 24, 36], rotation: 15 }) },
    { op: "addItem", page: p1, item: item(0x713, "image", 100, [360, 80, 100, 60], "a2", { blob: dot, pixelSize: [20, 12], rotation: 90 }) },
    { op: "addItem", page: p1, item: item(0x714, "text", 100, [72, 200, 220, 120], "a3", { text: text(storedRuns,
      { breaks: ["these", "exactly", "them", "Big"].map((w) => [...storedText.slice(0, storedText.indexOf(w))].length) }) }) },
    { op: "addItem", page: p1, item: item(0x715, "text", 100, [320, 200, 220, 80], "a4", { rotation: 30, text: text([
      { t: "Centred, rotated" }, { t: "\nsecond paragraph" }], { align: "center", font: "serif", breaks: [3, 99] }) }) },
    { op: "addItem", page: p1, item: item(0x716, "text", 100, [72, 360, 300, 60], "a5", { text: text([
      { t: "Right to left paragraph   " }, { t: "\nend aligned" }], { dir: "rtl", font: "mono", size: 12 }) }) },
    { op: "addItem", page: p1, item: item(0x717, "text", 100, [400, 360, 140, 30], "a6", { text: text([{ t: "Right" }], { align: "right", color: "#0D47A180" }) }) },
    { op: "addItem", page: p1, item: item(0x718, "sticker", 100, [72, 460, 60, 60], "a7", { emoji: "star" }) },
    { op: "addItem", page: p1, item: item(0x719, "math", 100, [72, 525, 200, 26], "a8", {
      math: { latex: "e^{i\\pi}+1=0", display: true, size: 14, color: "#1A1A1AFF" } }) },
    { op: "addItem", page: p1, item: item(0x71d, "math", 100, [450, 520, 90, 36], "aC", {
      math: { latex: "x^2", display: false, size: 12, color: "#1A1A1AFF", render: equation, renderSize: [60, 24], engine: "synthetic-1" } }) },
    { op: "addItem", page: p1, item: item(0x71a, "image", 100, [230, 460, 60, 60], "a9", { blob: missing, pixelSize: [10, 10] }) },
    { op: "addItem", page: p1, item: item(0x71b, "image", 100, [310, 460, 60, 60], "aA", { blob: forged, pixelSize: [20, 12] }) },
    { op: "addItem", page: p1, item: item(0x71c, "image", 100, [390, 460, 60, 60], "aB", { blob: heic, pixelSize: [10, 10] }) },
    { op: "addStroke", page: p1, stroke: stroke(0x720, "pen", "#000000FF", 2, wave(72, 560, 400), { rec: { id: rec1, at: 0.25 } }) },
    // Page 2: the rotated second PDF page as a cropped, rotated figure; a background-layer PDF page.
    { op: "addItem", page: p2, item: item(0x730, "pdfPage", 0, [36, 36, 270, 360], "a0", { blob: pdf, pageIndex: 1, pageSize: [260, 360], rotation: 5 }) },
    { op: "addItem", page: p2, item: item(0x731, "pdfPage", 100, [340, 400, 200, 150], "a1", { blob: pdf, pageIndex: 0, pageSize: [612, 792], crop: [36, 400, 400, 300], rotation: -20 }) },
    { op: "addItem", page: p2, item: item(0x732, "pdfPage", 100, [72, 600, 100, 100], "a2", { blob: pdf, pageIndex: 7, pageSize: [612, 792] }) },
    { op: "addRecording", recording: { id: rec1, blob: tone, started: wall(30), duration: 1, codec: "aac", sampleRate: 22050, channels: 1, bitRate: 24000, title: "Synthetic tone", transcript } },
    { op: "addRecording", recording: { id: rec2, blob: missingAudio, started: wall(32), duration: 3.5 } },
  ]));
}

// --- Note 6: an infinite page whose extent comes from an item below the ink.
{
  const note = "88888888-8888-4888-8888-888888888888";
  const pid = id(0x800 + 0x80);
  const dot = await blob(note, readFileSync(join(media, "dot.png")), "image/png");
  await write(note, delta(note, devB, 1, 40, [
    { op: "setMeta", field: "title", value: "Long attachments" },
    { op: "setMeta", field: "paper", value: { kind: "grid", spacing: 24, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" } },
    { op: "setMeta", field: "pageSize", value: { width: 600, height: 800, infinite: true } },
    { op: "addPage", page: { id: pid, order: "a0", strokes: [] } },
    { op: "addStroke", page: pid, stroke: stroke(0x881, "pen", "#000000FF", 2, wave(60, 100, 300)) },
    { op: "addItem", page: pid, item: { id: id(0x882), kind: "image", layer: 0, frame: [100, 2400, 200, 120], z: "a0", blob: dot, pixelSize: [20, 12], rotation: 45 } },
    { op: "addItem", page: pid, item: { id: id(0x883), kind: "text", layer: 100, frame: [100, 1500, 400, 50], z: "a1",
      text: { font: "sans", size: 18, color: "#000000FF", runs: [{ t: "Far below the ink" }] } } },
  ]));
}

// --- Note 7: video clips (format.md §8.2.7): posters, a rotated item, no poster, a poster set and
// reset later by another device, and a clip whose blob is missing (its poster still draws).
{
  const note = "7b7b7b7b-7b7b-47b7-87b7-7b7b7b7b7b7b";
  const pid = id(0x900);
  const clip = await blob(note, readFileSync(join(media, "clip.mp4")), "video/mp4");
  const photo = await blob(note, readFileSync(join(media, "photo.jpg")), "image/jpeg");
  const dot = await blob(note, readFileSync(join(media, "dot.png")), "image/png");
  const gone = await blob(note, enc.encode("a clip never written"), "video/quicktime", { skip: true });
  const video = (n: number, frame: number[], z: string, extra: Json = {}) =>
    ({ id: id(n), kind: "video", layer: 100, frame, z, blob: clip, pixelSize: [160, 90], duration: 1, codec: "h264", ...extra });
  await write(note, delta(note, devA, 1, 50, [
    { op: "setMeta", field: "title", value: "Video clips" },
    { op: "setMeta", field: "paper", value: { kind: "ruled", spacing: 24, background: "#FFFDF5FF", lineColor: "#C8D4E8FF" } },
    { op: "setMeta", field: "pageSize", value: letter },
    { op: "addPage", page: { id: pid, order: "a0", strokes: [] } },
    { op: "addItem", page: pid, item: video(0x901, [72, 72, 320, 180], "a0", { poster: photo }) },
    { op: "addItem", page: pid, item: video(0x902, [400, 80, 160, 90], "a1", { rotation: 20, videoRotation: 90, pixelSize: [90, 160] }) },
    { op: "addItem", page: pid, item: video(0x903, [72, 320, 200, 112.5], "a2") },
    { op: "addItem", page: pid, item: video(0x904, [300, 320, 240, 135], "a3", { blob: gone, poster: dot, codec: "hevc", duration: 12.5 }) },
    { op: "addItem", page: pid, item: video(0x905, [72, 480, 96, 54], "a4", { poster: dot }) },
    { op: "addStroke", page: pid, stroke: stroke(0x906, "pen", "#1A1A1AFF", 2, wave(72, 600, 400)) },
  ]));
  await write(note, delta(note, devB, 1, 55, [
    { op: "setItem", page: pid, itemId: id(0x902), field: "poster", value: dot },
    { op: "setItem", page: pid, itemId: id(0x905), field: "poster", value: null },
  ]));
}

// --- Note 8: recordings on the page (format.md §8.2.9): a card with a transcript, a rotated card and a
// small one showing it, a recording without title or transcript, and a card whose recording is missing.
{
  const note = "7c7c7c7c-7c7c-47c7-87c7-7c7c7c7c7c7c";
  const pid = id(0xa00);
  const tone = await blob(note, readFileSync(join(media, "tone.m4a")), "audio/mp4");
  const rec1 = id(0xa80), rec2 = id(0xa81);
  const transcript = await blob(note, enc.encode(JSON.stringify({
    format: "sempere-transcript/1", recording: rec1, engine: "synthetic-1", language: "en-US", created: wall(61),
    segments: [{ start: 0, end: 0.5, text: "A synthetic tone." }],
  })), "application/vnd.sempere.transcript+json");
  const card = (n: number, recording: string, frame: number[], z: string, extra: Json = {}) =>
    ({ id: id(n), kind: "audio", layer: 100, frame, z, recording, ...extra });
  await write(note, delta(note, devA, 1, 60, [
    { op: "setMeta", field: "title", value: "Recordings on the page" },
    { op: "setMeta", field: "paper", value: { kind: "blank", background: "#FFFFFFFF" } },
    { op: "setMeta", field: "pageSize", value: letter },
    { op: "addPage", page: { id: pid, order: "a0", strokes: [] } },
    { op: "addRecording", recording: { id: rec1, blob: tone, started: wall(60), duration: 1, codec: "aac", title: "Lecture", transcript } },
    { op: "addRecording", recording: { id: rec2, blob: tone, started: wall(62), duration: 75.4 } },
    { op: "addItem", page: pid, item: card(0xa01, rec1, [72, 72, 300, 96], "a0", { rec: { id: rec1, at: 0 } }) },
    { op: "addItem", page: pid, item: card(0xa02, rec1, [320, 220, 240, 80], "a1", { rotation: 15 }) },
    { op: "addItem", page: pid, item: card(0xa03, rec1, [72, 360, 200, 30], "a2") },
    { op: "addItem", page: pid, item: card(0xa04, rec2, [72, 440, 260, 96], "a3") },
    { op: "addItem", page: pid, item: card(0xa05, id(0xaff), [360, 440, 200, 60], "a4") },
    { op: "addStroke", page: pid, stroke: stroke(0xa06, "pen", "#1A1A1AFF", 2, wave(72, 600, 400), { rec: { id: rec1, at: 0.5 } }) },
  ]));
}

// --- Note 9: Markdown text boxes (format.md §8.2.4 "Markdown text", §8.5.4): a rotated box with every
// block kind and an unrendered formula, and a box whose formulas have typeset renderings (an inline one at
// the start of a line, a display one), each with the stored layout of its rendered text (computed by
// src/render/markdown.ts; any valid layout makes the CLI and the viewer cut the same lines).
{
  const note = "7d7d7d7d-7d7d-47d7-87d7-7d7d7d7d7d7d";
  const pid = id(0xb00);
  const fnv = (text: string) => {
    let h = 0x811c9dc5;
    for (const b of enc.encode(text)) h = Math.imul(h ^ b, 0x01000193) >>> 0;
    return h.toString(16).padStart(8, "0");
  };
  const a = "# Markdown box\nSome **bold**, *italic*, ~~struck~~ and `code` text, with a [link](https://example.org) and an "
    + "unrendered $x_1$ formula.\n\n- first item that is long enough to wrap\n  1. nested ordered\n- [x] done task\n- [ ] open task"
    + "\n\n> A quoted remark\n---\n```\nlet y = 2\n```";
  const b = "$e^{x}$ starts this line and the text after it wraps on.\n\n$$\\int_0^1 f$$";
  const inline = await blob(note, makePDF([{ media: [0, 0, 56, 18], content: "0.051 0.278 0.631 rg 2 4 52 10 re f" }]), "application/pdf");
  const display = await blob(note, makePDF([{ media: [0, 0, 110, 30], content: "0.051 0.278 0.631 rg 4 4 102 22 re f" }]), "application/pdf");
  await write(note, delta(note, devA, 1, 70, [
    { op: "setMeta", field: "title", value: "Markdown boxes" },
    { op: "setMeta", field: "paper", value: { kind: "blank", background: "#FFFFFFFF" } },
    { op: "setMeta", field: "pageSize", value: letter },
    { op: "addPage", page: { id: pid, order: "a0", strokes: [] } },
    { op: "addItem", page: pid, item: { id: id(0xb01), kind: "text", layer: 100, frame: [72, 72, 260, 170.64], z: "a0", rotation: 10,
      text: { font: "sans", size: 12, color: "#1A1A1AFF", markup: "markdown", runs: [{ t: a }], layout: { of: fnv(a), breaks: [68] } } } },
    { op: "addItem", page: pid, item: { id: id(0xb02), kind: "text", layer: 100, frame: [340, 120, 200, 88.6], z: "a1",
      text: { font: "serif", size: 14, color: "#0D47A1FF", markup: "markdown", runs: [{ t: b }], layout: { of: fnv(b), breaks: [25, 53] },
        math: [
          { latex: "e^{x}", display: false, size: 14, color: "#0D47A1FF", render: inline, renderSize: [56, 18], depth: 4, engine: "synthetic-1" },
          { latex: "\\int_0^1 f", display: true, size: 14, color: "#0D47A1FF", render: display, renderSize: [110, 30], depth: 11, engine: "synthetic-1" },
        ] } } },
    { op: "addStroke", page: pid, stroke: stroke(0xb03, "pen", "#1A1A1AFF", 2, wave(72, 600, 400)) },
  ]));
}

const manifest = {
  format: "sempere/1",
  vaultId: "5a3b1e00-1000-4000-8000-000000000002",
  created: wall(0),
  recipients: [{ key: recipient, label: "TEST-ONLY fixture key", added: wall(0) }],
  vaultSecret: armor.encode(await encrypt(secret)),
  features: ["attachments"],
};
writeFileSync(join(out, "vault.json"), JSON.stringify(manifest, null, 2) + "\n");
console.log(`wrote ${out}`);
