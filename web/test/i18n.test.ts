// The viewer's languages (docs/web-viewer.md "Languages"): every interface string has Spanish, the
// placeholders and plural forms agree between languages, the language is picked from the browser's
// list with a stored override, and no interface string in src/ui bypasses the catalog.

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { catalog } from "../src/i18n/catalog.ts";
import {
  type Plural, type TextKey, choosePreference, detectLocale, entries, isPreference, locale, matchLocale, resolve, setLocale, storedPreference, storePreference, t, tn,
} from "../src/i18n/index.ts";
import { formatBytes } from "../src/ui/caching.ts";
import { blobProblem } from "../src/ui/errors.ts";
import { BlobError } from "../src/vault/blobs.ts";

afterEach(() => {
  setLocale("en");
  Reflect.deleteProperty(globalThis, "localStorage");
});

/** The texts of a Spanish or English column: one, or the plural forms. */
const values = (v: string | Plural): string[] => (typeof v === "string" ? [v] : [v.one, v.other, ...(v.many === undefined ? [] : [v.many])]);
const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1] ?? "").sort();
/** The English words of a key with command names and file names taken out (those stay English). */
const prose = (key: string) => key.replace(/sempere [a-z-]+( [a-z-]+)*/g, "").replace(/\S*\.json|\S*\.sempere\S*|docs\/\S+/g, "");

describe("the catalog", () => {
  it("has a Spanish text for every key, and every count has its plural forms", () => {
    expect(entries().length).toBeGreaterThan(100);
    for (const [key, e] of entries()) {
      if (e.en === undefined) {
        expect(typeof e.es, key).toBe("string");
        expect((e.es as string).trim(), key).not.toBe("");
      } else {
        // English one/other; Spanish one/many/other (CLDR), the key being English `other`.
        expect(e.en.other, key).toBe(key);
        expect(Object.keys(e.en).sort(), key).toEqual(["one", "other"]);
        expect(Object.keys(e.es).sort(), key).toEqual(["many", "one", "other"]);
        for (const form of values(e.es)) expect(form.trim(), key).not.toBe("");
      }
    }
  });

  it("uses the same placeholders in every form of every language", () => {
    for (const [key, e] of entries()) {
      const want = placeholders(key);
      const forms = e.en === undefined ? values(e.es) : [...values(e.en), ...values(e.es)];
      for (const form of forms) expect(placeholders(form), `${key} → ${form}`).toEqual(want);
      if (e.en !== undefined) expect(want, key).toContain("count");
    }
  });

  it("does not leave English in the Spanish column", () => {
    for (const [key, e] of entries()) {
      if (e.en !== undefined) continue;
      expect(e.es, key).not.toBe(key);
    }
  });

  it("follows the Spanish glossary (docs/localization.md)", () => {
    const spanish = entries().flatMap(([key, e]) => values(e.es).map((v): [string, string] => [key, v]));
    for (const [key, es] of spanish) {
      // Passkey is “llave de acceso”; a vault's key is “clave”, never “llave”.
      expect(es.replace(/llaves? de acceso/gi, ""), `${key} → ${es}`).not.toMatch(/\bllaves?\b/i);
      expect(prose(es), `${key} → ${es}`).not.toMatch(/libreta|caja fuerte|contrase[ñn]a de acceso|\bnotebook\b|\bvault\b/i);
      const words = prose(key);
      if (/\bvaults?\b/i.test(words)) expect(es, key).toMatch(/b[óo]veda/i);
      if (/\bnotebooks?\b/i.test(words)) expect(es, key).toMatch(/cuaderno/i);
      if (/\btags?\b/i.test(words)) expect(es, key).toMatch(/etiqueta/i);
      if (/\bpassphrase\b/i.test(words)) expect(es, key).toMatch(/frase de contrase[ñn]a/i);
      if (/\bpasskeys?\b/i.test(words)) expect(es, key).toMatch(/llave de acceso|llaves de acceso/i);
      if (/\btranscripts?\b/i.test(words)) expect(es, key).toMatch(/transcripci/i);
      if (/\brecordings?\b/i.test(words)) expect(es, key).toMatch(/grabaci/i);
    }
  });
});

describe("t and tn", () => {
  it("are the English text in English, with values filled in", () => {
    expect(t("Lock")).toBe("Lock");
    expect(t("Notebook: {name}", { name: "A › B" })).toBe("Notebook: A › B");
    expect(t("Page {number}", { number: 3 })).toBe("Page 3");
  });

  it("translate in Spanish and keep values (notebook names are vault data, never translated)", () => {
    setLocale("es");
    expect(t("Lock")).toBe("Bloquear");
    expect(t("Notebook: {name}", { name: "Trabajo/Work" })).toBe("Cuaderno: Trabajo/Work");
    expect(t("All notes")).toBe("Todas las notas");
  });

  it("leave a placeholder alone when no value is given", () => {
    expect(t("Page {number}")).toBe("Page {number}");
  });

  it("pick the plural form of the language (Spanish `many` is for millions)", () => {
    expect([0, 1, 2, 5].map((n) => tn("{count} notes", n))).toEqual(["0 notes", "1 note", "2 notes", "5 notes"]);
    setLocale("es");
    expect([0, 1, 2, 5].map((n) => tn("{count} notes", n))).toEqual(["0 notas", "1 nota", "2 notas", "5 notas"]);
    expect(tn("{count} notes", 1_000_000)).toBe("1.000.000 de notas");
    expect(tn("{count} unreadable revisions", 1)).toBe("1 revisión ilegible");
    expect(tn("{count} keys", 3)).toBe("3 claves");
  });

  it("have a Spanish form for every plural key and every count", () => {
    setLocale("es");
    for (const [key, e] of entries()) {
      if (e.en === undefined) continue;
      for (const n of [0, 1, 2, 21, 1_000_000]) {
        const text = tn(key as Parameters<typeof tn>[0], n);
        expect(text, `${key} ${n}`).not.toMatch(/\{\w+\}/);
      }
    }
  });

  it("use the same text for English as the code did before: counts of one", () => {
    expect(tn("{count} with problems", 1)).toBe("1 with a problem");
    expect(tn("{count} ops skipped", 5)).toBe("5 ops skipped");
  });

  it("word a missing or over-limit attachment alike for every kind, with the limit and the CLI hint", () => {
    const tooLarge = new BlobError("tooLarge", "attachment of 9 bytes is over this viewer's 256 MiB limit");
    const missing = new BlobError("missing", "no file");
    for (const kind of ["audio", "video", "image", "pdf"] as const) {
      expect(blobProblem(tooLarge, kind, 256 * 2 ** 20), kind).toMatch(/\(256 MiB\); export it with the CLI/);
      expect(blobProblem(missing, kind, 1), kind).toMatch(/missing from the vault \(or not synced yet\)/);
    }
    expect(blobProblem(new BlobError("corrupt", "x"), "audio", 1)).toBeUndefined();
    expect(blobProblem(new Error("x"), "audio", 1)).toBeUndefined();
    setLocale("es");
    expect(blobProblem(tooLarge, "audio", 256 * 2 ** 20)).toBe("La grabación es mayor de lo que reproduce este visor (256 MiB); expórtala con la CLI.");
  });

  it("format sizes and numbers in the language", () => {
    expect(formatBytes(1536 * 1024)).toBe("1.5 MiB");
    setLocale("es");
    expect(formatBytes(1536 * 1024)).toBe("1,5 MiB");
  });
});

describe("choosing the language", () => {
  it("takes the first supported language of the browser's list, in the user's order", () => {
    expect(detectLocale(["es-MX", "en-US"])).toBe("es");
    expect(detectLocale(["fr-FR", "es", "en"])).toBe("es");
    expect(detectLocale(["en-GB", "es"])).toBe("en");
    expect(detectLocale(["fr", "de"])).toBe("en");
    expect(detectLocale([])).toBe("en");
    expect(matchLocale("ES_es")).toBe("es");
    expect(matchLocale("esperanto")).toBeUndefined();
  });

  it("lets an explicit choice override the browser, and `auto` follow it", () => {
    expect(resolve("en", ["es"])).toBe("en");
    expect(resolve("es", ["en"])).toBe("es");
    expect(resolve("auto", ["es-ES"])).toBe("es");
    expect(isPreference("auto") && isPreference("en") && isPreference("es")).toBe(true);
    expect(isPreference("fr")).toBe(false);
    expect(isPreference(undefined)).toBe(false);
  });

  it("remembers the choice in the browser, ignoring anything else it finds there", () => {
    const store = new Map<string, string>();
    Object.defineProperty(globalThis, "localStorage", { configurable: true, value: {
      getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => void store.set(k, v), removeItem: (k: string) => void store.delete(k),
    } });
    expect(storedPreference()).toBe("auto");
    storePreference("es");
    expect(storedPreference()).toBe("es");
    storePreference("auto");
    expect(storedPreference()).toBe("auto");
    expect(store.size).toBe(0);
    store.set("sempere-viewer-language", "klingon");
    expect(storedPreference()).toBe("auto");
    choosePreference("es");
    expect(locale()).toBe("es");
    choosePreference("en");
    expect(locale()).toBe("en");
    expect(storedPreference()).toBe("en");
  });

  it("works where storage is blocked", () => {
    const blocked = () => {
      throw new DOMException("denied", "SecurityError");
    };
    Object.defineProperty(globalThis, "localStorage", { configurable: true, value: { getItem: blocked, setItem: blocked, removeItem: blocked } });
    expect(storedPreference()).toBe("auto");
    expect(() => storePreference("es")).not.toThrow();
    expect(() => choosePreference("es")).not.toThrow();
    expect(locale()).toBe("es");
  });
});

describe("interface strings", () => {
  /** Strings that are not words of the interface: names, URLs, symbols, numbers. */
  const verbatim = new Set(["Sempere", "WebDAV", "https://example.org/Notes.sempere/", "AGE-SECRET-KEY-PQ-1…", "−", "+", "1:1", "KB", "MB",
    // Developer errors that are never shown: a missing IndexedDB (falls back to memory) and the DOM builder's invariants.
    "no IndexedDB", "unexpected image reference", "unexpected clip reference"]);
  const uiDir = join(import.meta.dirname, "..", "src", "ui");
  const files = readdirSync(uiDir).filter((f) => f.endsWith(".ts"));

  it("always go through the catalog in src/ui (no English literal where text is shown)", () => {
    const literal = /\b(text|title|placeholder|textContent)\b"?\s*[:=]\s*"((?:[^"\\]|\\.)*)"|"aria-label":\s*"((?:[^"\\]|\\.)*)"/g;
    const template = /\b(text|title|textContent)\b\s*[:=]\s*`((?:[^`\\]|\\.)*)`/g;
    const errors = /\b(?:Error|SourceError)\(\s*"((?:[^"\\]|\\.)*)"/g;
    const bad: string[] = [];
    for (const f of files) {
      const src = readFileSync(join(uiDir, f), "utf8").split("\n").filter((l) => !/^\s*(\/\/|\*|\/\*)/.test(l)).join("\n");
      for (const m of src.matchAll(literal)) {
        const s = m[2] ?? m[3] ?? "";
        if (/[A-Za-z]{2}/.test(s) && !verbatim.has(s)) bad.push(`${f}: "${s}"`);
      }
      for (const m of src.matchAll(template)) {
        if (/\btn?\(/.test(m[2] ?? "")) continue; // a template that holds translated parts
        const s = (m[2] ?? "").replace(/\$\{[^}]*\}/g, "");
        if (/[A-Za-z]{3,} [A-Za-z]{2,}/.test(s)) bad.push(`${f}: \`${m[2]}\``);
      }
      for (const m of src.matchAll(errors)) if (/[A-Za-z]{2}/.test(m[1] ?? "") && !verbatim.has(m[1] ?? "")) bad.push(`${f}: Error("${m[1]}")`);
    }
    expect(bad).toEqual([]);
  });

  it("are all in the catalog: every t/tn call names a key, and every key is used", () => {
    const used = new Set<string>();
    const call = /\b(?:t|tn)\(\s*"((?:[^"\\]|\\.)*)"/g;
    const roots = [join(import.meta.dirname, "..", "src")];
    const walk = (dir: string): string[] => readdirSync(dir, { withFileTypes: true }).flatMap((d) =>
      d.isDirectory() ? walk(join(dir, d.name)) : d.name.endsWith(".ts") ? [join(dir, d.name)] : []);
    for (const file of roots.flatMap(walk)) {
      if (file.includes("/i18n/")) continue;
      for (const m of readFileSync(file, "utf8").matchAll(call)) used.add(JSON.parse(`"${m[1]}"`) as string);
    }
    const keys = new Set(Object.keys(catalog));
    expect([...used].filter((k) => !keys.has(k))).toEqual([]);
    expect([...keys].filter((k) => !used.has(k))).toEqual([]);
  });

  it("type-checks: keys are typed", () => {
    const k: TextKey = "Lock";
    expect(t(k)).toBe("Lock");
  });
});
