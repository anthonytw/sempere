// Seeded mutation fuzzing of the parsers that see untrusted bytes (format.md
// §9): every failure must be the reader's typed error, never another
// exception, a hang or an unbounded allocation. Quick mode (about a second);
// SEMPERE_FUZZ_LONG=1 runs longer, as in the Swift tests.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { DecodeError } from "../src/format/json.ts";
import { decodeRevision } from "../src/format/model.ts";
import { NoteLogError, reconstruct } from "../src/format/reducer.ts";
import { renderSVG } from "../src/render/page.ts";
import { RenderError } from "../src/render/primitives.ts";
import { SourceError, parseIndex, propfindNames } from "../src/vault/source.ts";
import { VaultError, parseManifest } from "../src/vault/vault.ts";
import { golden, webFixtures } from "./support.ts";
import { PreparedPage } from "../src/render/page.ts";
import { resolveItems } from "../src/render/itemsvg.ts";
import { ImageFormatError, imageInfo, stripMetadata } from "../src/render/images.ts";
import { decodeTranscript } from "../src/format/transcript.ts";
import { SummariesError, decodeSummaries, readSummaries } from "../src/vault/summaries.ts";
import { ConfigError, parseConfig } from "../src/vault/config.ts";
import { sealFor, unlockFixture } from "./support.ts";
import { BlobError, verifyPlaintext } from "../src/vault/blobs.ts";
import { createHash } from "node:crypto";
import { KeyFileError, unwrapKey, workFactor, wrappedBytes } from "../src/vault/keyfile.ts";
import { foldTerm, occurrences, prepare, snippet } from "../src/format/occurrences.ts";
import { fixtures } from "./support.ts";

const iterations = process.env.SEMPERE_FUZZ_LONG ? 20_000 : 600;

/** xorshift32: deterministic per seed. */
function rng(seed: number): () => number {
  let x = seed >>> 0 || 1;
  return () => {
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    return (x >>> 0) / 2 ** 32;
  };
}

const interesting: unknown[] = [null, true, false, 0, -1, 1.5, 1e308, -1e308, 2 ** 53, 2 ** 53 + 2, "", "x", "#GGGGGG",
  "2026-02-30T00:00:00Z", "00000000000000000", "ffffffff", "11111111-1111-4111-8111-111111111111", [], {}, [1, 2], { op: "x" }];

function mutate(v: unknown, r: () => number, depth = 0): unknown {
  const pick = <T>(a: readonly T[]): T => a[Math.floor(r() * a.length)] as T;
  if (depth > 0 && r() < 0.15) return pick(interesting);
  if (Array.isArray(v)) {
    const a: unknown[] = (v as unknown[]).map((e) => (r() < 0.2 ? mutate(e, r, depth + 1) : e));
    if (r() < 0.05) a.pop();
    if (r() < 0.05 && a.length) a.push(a[0]);
    return a;
  }
  if (v && typeof v === "object") {
    const o: Record<string, unknown> = { ...(v as Record<string, unknown>) };
    for (const k of Object.keys(o)) {
      if (r() < 0.05) delete o[k];
      else if (r() < 0.2) o[k] = mutate(o[k], r, depth + 1);
    }
    return o;
  }
  if (typeof v === "number") return r() < 0.5 ? v * (r() * 4 - 2) : pick(interesting);
  if (typeof v === "string") return r() < 0.5 ? v.slice(0, Math.floor(r() * v.length)) : pick(interesting);
  return pick(interesting);
}

/**
 * Revisions in plain JSON, from the Swift CLI's state exports wrapped as
 * snapshots, each also as a newer revision (format.md §7.4) with an unknown op.
 */
function seeds(): unknown[] {
  return plainSeeds().flatMap((r) => {
    const o = r as Record<string, unknown>;
    const newer: Record<string, unknown> = { ...o, format: "sempere/2", features: ["tables"] };
    if (Array.isArray(o.ops)) newer.ops = [...(o.ops as unknown[]), { op: "warp", by: [1, 2] }, { op: "setMeta", field: "color", value: 1 }];
    return [r, newer];
  });
}

function plainSeeds(): unknown[] {
  const ids = ["11111111-1111-4111-8111-111111111111", "55555555-5555-4555-8555-555555555555", "77777777-7777-4777-8777-777777777777"];
  return ids.flatMap((id) => {
    const dir = id.startsWith("1") ? "sample" : "render";
    const state = JSON.parse(readFileSync(join(golden, dir, `${id}.json`), "utf8")) as unknown;
    return [{
      type: "snapshot", noteId: id, device: "a1b2c3d4", seq: 9, hlc: "17911308990000000", wall: "2026-10-04T16:30:00.000Z",
      app: "fuzz", included: { a1b2c3d4: { upTo: 8, extra: [] } }, state,
    }, {
      type: "delta", noteId: id, device: "99ee00ff", seq: 3, hlc: "17911308990000001", wall: "2026-10-04T16:30:00.000Z",
      app: "fuzz", ops: [{ op: "addTag", tag: "x" }, { op: "setMeta", field: "title", value: "t" },
        { op: "setPagePaper", pageId: "f1c70000-0000-4000-8000-000000000001", paper: { kind: "dot", spacing: 4, background: "#FFF", lineColor: "#000" } },
        { op: "removeTag", tag: "x", observed: ["17911308990000001-99ee00ff-0-0"] }],
    }];
  });
}

describe("fuzz", () => {
  it("decodes, merges and renders mutated revisions with typed errors only", () => {
    const base = seeds();
    const r = rng(0x5e3a);
    let decoded = 0;
    for (let i = 0; i < iterations; i++) {
      const v = mutate(base[i % base.length], r);
      try {
        const rev = decodeRevision(v);
        decoded++;
        const state = reconstruct([rev]);
        for (const p of state.pages.slice(0, 2)) {
          try {
            renderSVG(p, state.meta);
            resolveItems(new PreparedPage(p, state.meta));
          } catch (e) {
            if (!(e instanceof RenderError)) throw e;
          }
        }
      } catch (e) {
        if (!(e instanceof DecodeError || e instanceof NoteLogError)) {
          throw new Error(`iteration ${i}: ${String(e)}\n${JSON.stringify(v).slice(0, 2000)}`, { cause: e });
        }
      }
    }
    expect(decoded).toBeGreaterThan(0);
  });

  it("parses mutated manifests, indexes and PROPFIND bodies with typed errors only", () => {
    const r = rng(0xbeef);
    const manifest = JSON.parse(readFileSync(join(golden, "..", "fixtures", "render.sempere", "vault.json"), "utf8")) as unknown;
    const index = { format: "sempere-index/1", notes: { "11111111-1111-4111-8111-111111111111": ["17911308010000000-a1b2c3d4-1.delta.age"] } };
    const enc = new TextEncoder();
    for (let i = 0; i < iterations; i++) {
      for (const [v, f, E] of [[manifest, parseManifest, VaultError], [index, parseIndex, SourceError]] as const) {
        const bytes = enc.encode(JSON.stringify(mutate(v, r)));
        if (r() < 0.2) bytes[Math.floor(r() * bytes.length)] = Math.floor(r() * 256);
        try {
          f(bytes);
        } catch (e) {
          if (!(e instanceof E)) throw e;
        }
      }
      const xml = `<d:multistatus><d:href>${"/a/%zz&#x110000;&amp;<b>".slice(0, Math.floor(r() * 24))}</d:href></d:multistatus>`;
      expect(Array.isArray(propfindNames(xml))).toBe(true);
    }
  });

  it("reads mutated published summaries and configs with typed errors only", async () => {
    const r = rng(0x5a11);
    const content = JSON.parse(readFileSync(join(golden, "render.summaries.json"), "utf8")) as { vaultId: string };
    const config = { vault: "./vault/", listing: "webdav", allowOtherVaults: false };
    const { vault } = await unlockFixture(join(golden, "..", "fixtures", "render.sempere"));
    for (let i = 0; i < iterations; i++) {
      const v = mutate(content, r);
      try {
        decodeSummaries(v, content.vaultId);
      } catch (e) {
        if (!(e instanceof SummariesError)) throw e;
      }
      try {
        parseConfig(JSON.stringify(mutate(config, r)), "https://x/");
      } catch (e) {
        if (!(e instanceof ConfigError)) throw e;
      }
      // Sealed for real (so it authenticates) every so often, through the whole reader.
      if (i % 20 === 0) {
        const sealed = await sealFor(vault, v);
        if (r() < 0.3) sealed[Math.floor(r() * sealed.length)] = Math.floor(r() * 256);
        try {
          await readSummaries(sealed, vault);
        } catch (e) {
          if (!(e instanceof SummariesError)) throw e;
        }
      }
    }
  });

  it("reads mutated images, transcripts and blob plaintexts with typed errors only", async () => {
    const r = rng(0xa77a);
    const flip = (b: Uint8Array): Uint8Array => {
      const out = b.slice(0, r() < 0.1 ? Math.floor(r() * b.length) : b.length);
      const n = 1 + Math.floor(r() * 4);
      for (let k = 0; k < n && out.length; k++) out[Math.floor(r() * out.length)] = Math.floor(r() * 256);
      return out;
    };
    const images = ["photo.jpg", "dot.png"].map((f) => new Uint8Array(readFileSync(join(webFixtures, "media", f))));
    const rec = "11111111-1111-4111-8111-111111111111";
    const transcript = { format: "sempere-transcript/1", recording: rec, engine: "e", language: "en", created: "2026-10-04T17:21:00Z",
      segments: [{ start: 0, end: 1, text: "a b", confidence: 0.5, words: [{ t: "a", start: 0, end: 0.5, c: 0.9 }, { t: "b", start: 0.5, end: 1 }] }] };
    const content = new TextEncoder().encode("hello, sempere!\n");
    const ref = { sha256: createHash("sha256").update(content).digest("hex"), size: content.length, type: "text/plain" };
    const framed = new Uint8Array(64);
    framed.set(new TextEncoder().encode("INKB"));
    framed[4] = 1;
    framed.set(createHash("sha256").update(content).digest(), 5);
    framed[44] = content.length;
    framed.set(content, 45);
    for (let i = 0; i < iterations; i++) {
      const img = flip(images[i % 2] as Uint8Array);
      try {
        imageInfo(img);
        stripMetadata(img);
      } catch (e) {
        if (!(e instanceof ImageFormatError)) throw new Error(`image iteration ${i}: ${String(e)}`, { cause: e });
      }
      try {
        decodeTranscript(new TextEncoder().encode(JSON.stringify(mutate(transcript, r))), rec);
      } catch (e) {
        if (!(e instanceof DecodeError)) throw new Error(`transcript iteration ${i}: ${String(e)}`, { cause: e });
      }
      if (i % 10 === 0) {
        const bytes = flip(framed);
        try {
          await verifyPlaintext(new Blob([bytes as Uint8Array<ArrayBuffer>]).stream(), ref);
        } catch (e) {
          if (!(e instanceof BlobError)) throw new Error(`blob iteration ${i}: ${String(e)}`, { cause: e });
        }
      }
    }
  });

  it("reads mutated passphrase-wrapped key files with typed errors only", async () => {
    const r = rng(0x6b65);
    const dir = join(fixtures, "sample.sempere", "keys");
    const { readdirSync } = await import("node:fs");
    const stored = new Uint8Array(readFileSync(join(dir, readdirSync(dir)[0] ?? "")));
    const kit = readFileSync(join(webFixtures, "paper-kit-passphrase.txt"), "utf8");
    for (let i = 0; i < iterations; i++) {
      const bytes = stored.slice(0, r() < 0.1 ? Math.floor(r() * stored.length) : stored.length);
      // Mostly in the header, where the parser looks.
      const n = 1 + Math.floor(r() * 3);
      for (let k = 0; k < n && bytes.length; k++) bytes[Math.floor(r() * Math.min(bytes.length, r() < 0.8 ? 120 : bytes.length))] = Math.floor(r() * 256);
      const chars = [...kit];
      for (let k = 0; k < n; k++) chars[Math.floor(r() * chars.length)] = String.fromCharCode(Math.floor(r() * 128));
      for (const input of [bytes, chars.join("")]) {
        try {
          const file = wrappedBytes(input);
          const logN = workFactor(file);
          // scrypt runs only on files whose header parses; at work factor 15 it is quick.
          if (i % 50 === 0 && logN <= 15) await unwrapKey(file, "sempere-test");
        } catch (e) {
          if (!(e instanceof KeyFileError)) throw new Error(`key file iteration ${i}: ${String(e)}`, { cause: e });
        }
      }
    }
  });

  it("finds phrases in random text without failing or leaving the text", () => {
    const r = rng(0x5ea4);
    const alphabet = ["a", "E", "é", "e\u0301", "\u0301", "ß", "SS", "ﬃ", "İ", "\ufe0f", "👍🏽", "\n", " ", "\r\n", "が", "\uff21", "न्", "\u200c", "\ud800", "x"];
    const pick = () => alphabet[Math.floor(r() * alphabet.length)] ?? "";
    for (let i = 0; i < iterations * 5; i++) {
      const text = Array.from({ length: Math.floor(r() * 40) }, pick).join("");
      const term = Array.from({ length: 1 + Math.floor(r() * 4) }, pick).join("");
      const t = prepare(text);
      let last = 0;
      for (const [a, b] of occurrences(t, foldTerm(term))) {
        expect(a >= last && b >= a && b <= t.cps.length).toBe(true);
        last = b;
        expect(typeof snippet(t, [a, b])).toBe("string");
      }
    }
  });
});
