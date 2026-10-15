// Writes a synthetic stress vault for the large-note checks (docs/web-viewer.md "Stress tests"):
//   note "Stress: 120 pages"       120 letter pages, ~20 strokes each
//   note "Stress: pageless 4000"   one pageless page, 4000 strokes over ~40 000 pt
//   note "Stress: pageless dense" a pageless page with 3000 strokes inside 3000 pt (hundreds per band)
//   note "Stress: 100 deep pages"  100 pageless pages whose ink depth differs, so every page's exact
//                                  height differs from the provisional one (the scroll-anchor check)
// The vault is encrypted to the throwaway test key of Tests/SempereTests/Fixtures/sample.key.
// Synthetic content only; nothing is committed (the output goes to a temporary directory).
//
// Usage: node scripts/make-stress-fixture.ts OUT_DIR [--pages N] [--strokes N] [--deep N] [--dense N]

import { armor, identityToRecipient } from "age-encryption";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createVaultWriter, vaultTags } from "./fixture-lib.ts";

const args = process.argv.slice(2);
const outArg = args[0];
if (!outArg) throw new Error("usage: make-stress-fixture.ts OUT_DIR [--pages N] [--strokes N] [--deep N] [--dense N]");
const out: string = outArg;
const opt = (name: string, dflt: number): number => {
  const i = args.indexOf(`--${name}`);
  return i < 0 ? dflt : Number(args[i + 1]);
};
const pageCount = opt("pages", 120), strokeCount = opt("strokes", 4000), deepCount = opt("deep", 100), denseCount = opt("dense", 3000);

const web = join(import.meta.dirname, "..");
const keyFile = join(web, "..", "Tests", "SempereTests", "Fixtures", "sample.key");
const identity = readFileSync(keyFile, "utf8").split("\n").find((l) => l.startsWith("AGE-SECRET-KEY-PQ-"));
if (!identity) throw new Error("no identity in sample.key");
const recipient = await identityToRecipient(identity);
const secret = new Uint8Array(32).map((_, i) => (i * 11 + 5) & 0xff);
const { encrypt, frame } = createVaultWriter({ secret, out, recipient });

const dev = "a1b2c3d4";
const t0 = Date.UTC(2026, 9, 14, 12, 0, 0);
type Json = Record<string, unknown>;
const hlc = (s: number) => String(t0 + s * 1000).padStart(13, "0") + "0000";
const wall = (s: number) => new Date(t0 + s * 1000).toISOString();
let counter = 0;
const id = (n: number) => `5e550000-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;

/** A small deterministic generator (mulberry32), so every run writes the same ink. */
function rng(seed: number): () => number {
  let a = seed;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function squiggle(r: () => number, x0: number, y0: number, n: number): number[][] {
  const len = 40 + r() * 200;
  return Array.from({ length: n }, (_, i) => {
    const w = 1.5 + (i % 4) * 0.4;
    return [Math.round((x0 + (len * i) / (n - 1)) * 100) / 100, Math.round((y0 + Math.sin(i / 2 + r()) * 6) * 100) / 100, i * 0.01, w, w, 1, 0.5, 0.3, 1.2];
  });
}

const tools = ["pen", "pencil", "marker", "monoline", "fountainPen"];
const stroke = (n: number, r: () => number, x: number, y: number, points: number): Json =>
  ({ id: id(n), ink: { tool: tools[n % tools.length], color: n % 3 ? "#1A1A1AFF" : "#2E5BFFCC", width: 2.5 }, points: squiggle(r, x, y, points) });

async function write(noteId: string, ops: Json[]): Promise<void> {
  const seq = ++counter;
  const rev = { type: "delta", noteId, device: dev, seq, hlc: hlc(seq), wall: wall(seq), app: "sempere-web-stress/1", ops };
  const name = `${rev.hlc}-${dev}-${seq}.delta.age`;
  const dir = join(out, "notes", noteId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, name), await encrypt(await frame(rev, noteId, name)));
}

rmSync(out, { recursive: true, force: true });
mkdirSync(join(out, "notes"), { recursive: true });
const ruled = { kind: "ruled", spacing: 24, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" };
const order = (i: number) => `a${i.toString(36).padStart(4, "0")}`;
let strokeId = 0x1000;

{ // 120 letter pages.
  const note = "51000000-0000-4000-8000-000000000001", r = rng(1);
  const ops: Json[] = [
    { op: "setMeta", field: "title", value: `Stress: ${pageCount} pages` },
    { op: "setMeta", field: "paper", value: ruled },
    { op: "setMeta", field: "pageSize", value: { width: 612, height: 792, infinite: false } },
  ];
  for (let p = 0; p < pageCount; p++) {
    const pid = id(0x100 + p);
    ops.push({ op: "addPage", page: { id: pid, order: order(p), strokes: [] } });
    for (let k = 0; k < 20; k++) ops.push({ op: "addStroke", page: pid, stroke: stroke(strokeId++, r, 60 + r() * 300, 60 + k * 34, 24) });
  }
  await write(note, ops);
}

{ // One pageless page, thousands of strokes.
  const note = "51000000-0000-4000-8000-000000000002", r = rng(2), pid = id(0x2000);
  const height = 40000;
  const ops: Json[] = [
    { op: "setMeta", field: "title", value: `Stress: pageless ${strokeCount}` },
    { op: "setMeta", field: "paper", value: { kind: "grid", spacing: 24, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" } },
    { op: "setMeta", field: "pageSize", value: { width: 600, height: 900, infinite: true } },
    { op: "addPage", page: { id: pid, order: "a0", strokes: [] } },
  ];
  for (let k = 0; k < strokeCount; k++) {
    ops.push({ op: "addStroke", page: pid, stroke: stroke(strokeId++, r, 30 + r() * 350, 20 + (height * k) / strokeCount, 16) });
  }
  await write(note, ops);
}

{ // Many strokes in few screens.
  const note = "51000000-0000-4000-8000-000000000004", r = rng(4), pid = id(0x4000);
  const ops: Json[] = [
    { op: "setMeta", field: "title", value: "Stress: pageless dense" },
    { op: "setMeta", field: "paper", value: { kind: "blank", background: "#FFFFFFFF" } },
    { op: "setMeta", field: "pageSize", value: { width: 600, height: 900, infinite: true } },
    { op: "addPage", page: { id: pid, order: "a0", strokes: [] } },
  ];
  for (let k = 0; k < denseCount; k++) ops.push({ op: "addStroke", page: pid, stroke: stroke(strokeId++, r, 30 + r() * 350, 20 + (3000 * k) / denseCount, 30) });
  await write(note, ops);
}

{ // Pageless pages of differing depth: provisional (one chunk) and exact heights differ.
  const note = "51000000-0000-4000-8000-000000000003", r = rng(3);
  const ops: Json[] = [
    { op: "setMeta", field: "title", value: `Stress: ${deepCount} deep pages` },
    { op: "setMeta", field: "paper", value: { kind: "dot", spacing: 24, background: "#FFFFFFFF", lineColor: "#9AA3B5FF" } },
    { op: "setMeta", field: "pageSize", value: { width: 600, height: 800, infinite: true } },
  ];
  for (let p = 0; p < deepCount; p++) {
    const pid = id(0x3000 + p);
    ops.push({ op: "addPage", page: { id: pid, order: order(p), strokes: [] } });
    const depth = 200 + Math.floor(r() * 3500);
    for (let k = 0; k < 12; k++) ops.push({ op: "addStroke", page: pid, stroke: stroke(strokeId++, r, 60 + r() * 300, 40 + (depth * k) / 11, 20) });
  }
  await write(note, ops);
}

const vaultId = "5e550000-1000-4000-8000-000000000001";
writeFileSync(join(out, "vault.json"), JSON.stringify({
  format: "sempere/1", vaultId, created: wall(0),
  recipients: [{ key: recipient, label: "TEST-ONLY fixture key", added: wall(0) }],
  vaultSecret: armor.encode(await encrypt(secret)),
  ...vaultTags(vaultId, [recipient], secret),
}, null, 2) + "\n");
console.log(`wrote ${out}`);
