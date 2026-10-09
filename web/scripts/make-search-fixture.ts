// Writes web/test/fixtures/search.sempere: a small vault, encrypted to the
// throwaway test recipient of Tests/SempereTests/Fixtures/sample.key, whose
// text exercises `sempere search` and the viewer's port of it
// (src/format/phrasesearch.ts): recognised handwriting with word boxes, text
// boxes, an equation, PDF page text, and recording transcripts with accents,
// folded letters, repeated words, long segments (snippets) and line breaks;
// a deleted note, a missing transcript and one naming another recording.
// Synthetic content only.
//
// Run: node scripts/make-search-fixture.ts (from web/). age encryption is
// randomized, so the ciphertext changes on every run; the decrypted JSON does
// not. Then run scripts/golden.sh.

import { armor, identityToRecipient } from "age-encryption";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createVaultWriter } from "./fixture-lib.ts";

const web = join(import.meta.dirname, "..");
const keyFile = join(web, "..", "Tests", "SempereTests", "Fixtures", "sample.key");
const out = join(web, "test", "fixtures", "search.sempere");

const identity = readFileSync(keyFile, "utf8").split("\n").find((l) => l.startsWith("AGE-SECRET-KEY-PQ-"));
if (!identity) throw new Error("no identity in sample.key");
const recipient = await identityToRecipient(identity);
const secret = new Uint8Array(32).map((_, i) => (i * 11 + 5) & 0xff);
const enc = new TextEncoder();

const { encrypt, frame, writeBlob } = createVaultWriter({ secret, out, recipient });

const dev = "5ea4c400";
const t0 = Date.UTC(2026, 9, 8, 9, 0, 0);
const hlc = (s: number) => String(t0 + s * 1000).padStart(13, "0") + "0000";
const wall = (s: number) => new Date(t0 + s * 1000).toISOString();
const id = (n: number) => `5ea4c000-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;

type Json = Record<string, unknown>;

async function write(noteId: string, seq: number, at: number, ops: Json[]): Promise<void> {
  const rev = { type: "delta", noteId, device: dev, seq, hlc: hlc(at), wall: wall(at), app: "sempere-web-fixture/1", ops };
  const name = `${rev.hlc}-${dev}-${seq}.delta.age`;
  const dir = join(out, "notes", noteId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, name), await encrypt(await frame(rev, noteId, name)));
}

/** Writes `content` as a blob of `noteId` (unless `skip`) and returns its reference. */
function blob(noteId: string, content: Uint8Array, type: string, kind: string, skip = false): Promise<Json> {
  return writeBlob(noteId, content, type, kind, { skip });
}

const transcriptType = "application/vnd.sempere.transcript+json";
async function transcript(noteId: string, recording: string, segments: Json[], opts: { skip?: boolean; language?: string } = {}): Promise<Json> {
  const content = enc.encode(JSON.stringify({
    format: "sempere-transcript/1", recording, engine: "synthetic-speech-2", language: opts.language ?? "en-US", created: wall(5),
    segments,
  }));
  return blob(noteId, content, transcriptType, "transcript", opts.skip);
}

const tone = readFileSync(join(web, "test", "fixtures", "media", "tone.m4a"));
const letter = { width: 612, height: 792, infinite: false };
const paper = { kind: "ruled", spacing: 24, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" };

rmSync(out, { recursive: true, force: true });
mkdirSync(join(out, "notes"), { recursive: true });

function words(text: string, y: number): Json[] {
  let x = 40;
  return text.split(/\s+/).filter(Boolean).map((t) => {
    const w = t.length * 9;
    const box = [x, y, w, 20];
    x += w + 6;
    return { t, box };
  });
}

// --- Note 1: every source, with accents, case and repeats.
{
  const note = "5ea4c001-0000-4000-8000-000000000001";
  const p1 = id(0x101), p2 = id(0x102), p3 = id(0x103);
  const rec1 = id(0x180), rec2 = id(0x181);
  const audio = await blob(note, tone, "audio/mp4", "audio");
  const t1 = await transcript(note, rec1, [
    { start: 0, end: 4.5, text: "Welcome back. Today we walk down the Straße to the café, and the café is closed again." },
    { start: 4.5, end: 9.25, text: "Naïve readers expect the résumé on page one; the RESUME is on page two, after the café." },
    { start: 9.25, end: 15, text: "A long pause.\nThen a new line about the STRASSE,\r\nand another about ﬁsh and fish." },
    { start: 75.5, end: 80, text: "Ending: café café café." },
  ]);
  const t2 = await transcript(note, rec2, [
    { start: 3601, end: 3605, text: "Über eine Stunde später: die Straße ist nass." },
  ], { language: "de-DE" });
  await write(note, 1, 0, [
    { op: "setMeta", field: "title", value: "Lecture: cafés & streets" },
    { op: "setMeta", field: "notebook", value: "Search/Fixtures" },
    { op: "setMeta", field: "paper", value: paper },
    { op: "setMeta", field: "pageSize", value: letter },
    { op: "addPage", page: { id: p1, order: "a0", strokes: [] } },
    { op: "addPage", page: { id: p2, order: "a1", strokes: [] } },
    { op: "addPage", page: { id: p3, order: "a2", strokes: [] } },
    { op: "setPageRecognition", pageId: p1, recognition: {
      engine: "vision-26", text: "Café au lait\nthe Straße is long",
      words: [...words("Café au lait", 40), ...words("the Straße is long", 70)] } },
    { op: "setPageRecognition", pageId: p3, recognition: {
      engine: "notability-14", text: "Résumé of the cafe visit, written in a café in a hurry, by the Strasse corner",
      words: words("Résumé of the cafe visit, written in a café in a hurry, by the Strasse corner", 40) } },
    { op: "addItem", page: p2, item: { id: id(0x110), kind: "text", layer: 100, frame: [40, 100, 400, 120], z: "a0",
      text: { font: "sans", size: 14, color: "#1A1A1AFF", runs: [{ t: "Typed: the café on the corner of the Straße. " }, { t: "Café again, bold.", b: true }] } } },
    { op: "addItem", page: p2, item: { id: id(0x111), kind: "math", layer: 100, frame: [40, 260, 200, 40], z: "a1",
      math: { latex: "\\text{café} = \\frac{a}{b}", display: true, size: 20, color: "#1A1A1AFF" } } },
    { op: "addItem", page: p2, item: { id: id(0x112), kind: "pdfPage", layer: 0, frame: [0, 0, 612, 792], z: "a2",
      blob: { sha256: "ab".repeat(32), size: 1000, type: "application/pdf" }, pageIndex: 6, pageSize: [612, 792],
      pageText: { text: "Printed handout\nCAFÉ menu: espresso, latte\nStraße map", engine: "semperepdf-1" } } },
    { op: "addRecording", recording: { id: rec1, blob: audio, started: wall(10), duration: 80, codec: "aac", title: "Walk to the café", transcript: t1 } },
    { op: "addRecording", recording: { id: rec2, blob: audio, started: wall(20), duration: 3605, codec: "aac", title: "Spät", transcript: t2 } },
  ]);
}

// --- Note 2: a title starting with a non-ASCII letter (sorted by code point, after "l"), a page
// without recognition, and a recording without a transcript.
{
  const note = "5ea4c001-0000-4000-8000-000000000002";
  const p1 = id(0x201), p2 = id(0x202);
  const rec = id(0x280);
  const audio = await blob(note, tone, "audio/mp4", "audio");
  await write(note, 1, 30, [
    { op: "setMeta", field: "title", value: "Ärger im Café" },
    { op: "setMeta", field: "pageSize", value: letter },
    { op: "addPage", page: { id: p1, order: "a0", strokes: [] } },
    { op: "addPage", page: { id: p2, order: "a1", strokes: [] } },
    { op: "setPageRecognition", pageId: p2, recognition: { engine: "vision-26", text: "kein Kaffee im CAFE heute", words: words("kein Kaffee im CAFE heute", 40) } },
    { op: "addRecording", recording: { id: rec, blob: audio, started: wall(31), duration: 1, codec: "aac", title: "No transcript" } },
  ]);
}

// --- Note 3: a lowercase title (sorts by lowercased title), transcripts that cannot be read: one missing,
// one naming another recording.
{
  const note = "5ea4c001-0000-4000-8000-000000000003";
  const p1 = id(0x301);
  const recA = id(0x380), recB = id(0x381), recC = id(0x382);
  const audio = await blob(note, tone, "audio/mp4", "audio");
  const missing = await transcript(note, recA, [{ start: 0, end: 1, text: "café missing" }], { skip: true });
  const wrong = await transcript(note, id(0x3ff), [{ start: 0, end: 1, text: "café elsewhere" }]);
  const good = await transcript(note, recC, [{ start: 12.5, end: 14, text: "The last café of the day." }]);
  await write(note, 1, 40, [
    { op: "setMeta", field: "title", value: "broken transcripts" },
    { op: "setMeta", field: "pageSize", value: letter },
    { op: "addPage", page: { id: p1, order: "a0", strokes: [] } },
    { op: "addRecording", recording: { id: recA, blob: audio, started: wall(41), duration: 1, codec: "aac", title: "Missing", transcript: missing } },
    { op: "addRecording", recording: { id: recB, blob: audio, started: wall(42), duration: 1, codec: "aac", title: "Wrong", transcript: wrong } },
    { op: "addRecording", recording: { id: recC, blob: audio, started: wall(43), duration: 14, codec: "aac", transcript: good } },
  ]);
}

// --- Note 4: deleted, so never searched.
{
  const note = "5ea4c001-0000-4000-8000-000000000004";
  const p1 = id(0x401), rec = id(0x480);
  const audio = await blob(note, tone, "audio/mp4", "audio");
  const t = await transcript(note, rec, [{ start: 0, end: 1, text: "A deleted café." }]);
  await write(note, 1, 50, [
    { op: "setMeta", field: "title", value: "Deleted café" },
    { op: "setMeta", field: "pageSize", value: letter },
    { op: "addPage", page: { id: p1, order: "a0", strokes: [] } },
    { op: "setPageRecognition", pageId: p1, recognition: { engine: "vision-26", text: "deleted café", words: words("deleted café", 40) } },
    { op: "addRecording", recording: { id: rec, blob: audio, started: wall(51), duration: 1, codec: "aac", title: "Gone", transcript: t } },
    { op: "deleteNote" },
  ]);
}

const manifest = {
  format: "sempere/1",
  vaultId: "5a3b1e00-1000-4000-8000-000000000003",
  created: wall(0),
  recipients: [{ key: recipient, label: "TEST-ONLY fixture key", added: wall(0) }],
  vaultSecret: armor.encode(await encrypt(secret)),
  features: ["attachments"],
};
writeFileSync(join(out, "vault.json"), JSON.stringify(manifest, null, 2) + "\n");
console.log(`wrote ${out}`);
