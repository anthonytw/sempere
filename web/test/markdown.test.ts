// Markdown text boxes (format.md §8.2.4 "Markdown text", §8.5.4): the
// parser against the Swift tests' cases, and the layout against the shared
// fixtures (Tests/SempereTests/Fixtures/text/markdown.json), which the
// Swift renderer and the app's tests read too: with the stored layout the
// lines, baselines and formula boxes are the same whatever the fonts.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { JSONObject } from "../src/format/json.ts";
import { type MDAtom, type MDEntry, MarkdownDocument, Style, markdownHash, textOf } from "../src/format/markdown.ts";
import { expandMarkdown, layoutMarkdown } from "../src/render/markdown.ts";
import { prepareItem } from "../src/render/items.ts";
import { PreparedPage } from "../src/render/page.ts";
import { resolveItems } from "../src/render/itemsvg.ts";
import { Budget, decodeItem } from "../src/format/attachments.ts";
import { fixtures } from "./support.ts";

function describeDoc(source: string): string[] {
  const out: string[] = [];
  const name = (st: number) => (st & Style.bold ? "b" : "") + (st & Style.italic ? "i" : "") + (st & Style.strike ? "s" : "")
    + (st & Style.code ? "c" : "") + (st & Style.link ? "l" : "");
  const text = (atoms: MDAtom[]) => {
    let s = "", style = 0;
    for (const a of atoms) {
      if (a.style !== style) { s += `{${name(a.style)}}`; style = a.style; }
      if (a.kind.k === "char") s += String.fromCodePoint(a.kind.c);
      else if (a.kind.k === "formula") s += a.kind.display ? `[$$${a.kind.latex}$$]` : `[$${a.kind.latex}$]`;
      else s += "⏎";
    }
    return s;
  };
  const walk = (entries: MDEntry[], prefix: string) => {
    for (const e of entries) {
      const gap = e.blankBefore ? "+" : "";
      const b = e.block;
      switch (b.t) {
        case "paragraph": out.push(`${prefix}${gap}p:${text(b.atoms)}`); break;
        case "heading": out.push(`${prefix}${gap}h${b.level}:${text(b.atoms)}`); break;
        case "code": out.push(`${prefix}${gap}code:${text(b.atoms)}`); break;
        case "math": out.push(`${prefix}${gap}math:${text([b.atom])}`); break;
        case "rule": out.push(`${prefix}${gap}rule`); break;
        case "quote": out.push(`${prefix}${gap}quote`); walk(b.entries, `${prefix}> `); break;
        case "list":
          out.push(prefix + gap + (b.list.bullet !== undefined ? `ul${String.fromCodePoint(b.list.bullet)}` : `ol${b.list.start}`));
          for (const item of b.list.items) {
            const task = item.task === undefined ? "" : item.task ? "[x]" : "[ ]";
            out.push(`${prefix}  ${item.blankBefore ? "+" : ""}item${task}`);
            walk(item.blocks, `${prefix}    `);
          }
          break;
      }
    }
  };
  walk(new MarkdownDocument(source).blocks, "");
  return out;
}

describe("Markdown parser (Swift MarkdownTests)", () => {
  it("parses headings, paragraphs and hard breaks", () => {
    expect(describeDoc("# Title #\n\nLine one\nline two  \n## Sub")).toEqual(["h1:Title", "+p:Line one⏎line two", "h2:Sub"]);
    expect(describeDoc("#nope\n####### seven")).toEqual(["p:#nope⏎####### seven"]);
  });
  it("matches emphasis", () => {
    expect(describeDoc("a **bold** and *it* and ~~gone~~")).toEqual(["p:a {b}bold{} and {i}it{} and {s}gone"]);
    expect(describeDoc("***both*** x")).toEqual(["p:{bi}both{} x"]);
    expect(describeDoc("snake_case_name and 2 * 3 * 4")).toEqual(["p:snake_case_name and 2 * 3 * 4"]);
    expect(describeDoc("**unclosed and *mixed**")).toEqual(["p:*{i}unclosed and mixed"]);
  });
  it("reads code spans, escapes and math", () => {
    expect(describeDoc("use `a*b*c` and \\*not\\*")).toEqual(["p:use {c}a*b*c{} and *not*"]);
    expect(describeDoc("``a ` b`` and `x")).toEqual(["p:{c}a ` b{} and `x"]);
    expect(describeDoc("Let $f(x) = x^2$ cost $5 and $6")).toEqual(["p:Let [$f(x) = x^2$] cost $5 and $6"]);
    expect(describeDoc("inline $$\\sum_i$$ display style")).toEqual(["p:inline [$$\\sum_i$$] display style"]);
    expect(describeDoc("$$\n\\int_0^1 x\\,dx\n$$\nafter")).toEqual(["math:[$$\\int_0^1 x\\,dx$$]", "p:after"]);
    expect(describeDoc("$$ a^2 $$")).toEqual(["math:[$$a^2$$]"]);
    expect(describeDoc("$$x$$ is nice")).toEqual(["p:[$$x$$] is nice"]);
    expect(describeDoc("$ x$")).toEqual(["p:$ x$"]);
  });
  it("reads links, images and autolinks", () => {
    const src = "see [the *docs*](https://example.org/a_(b) \"t\") and ![alt](x.png) <https://e.org>";
    expect(new MarkdownDocument(src).links).toEqual(["https://example.org/a_(b)", "https://e.org"]);
    expect(describeDoc(src)).toEqual(["p:see {l}the {il}docs{} and alt {l}https://e.org"]);
    expect(describeDoc("[not a link] (x)")).toEqual(["p:[not a link] (x)"]);
  });
  it("reads lists, quotes, rules and code", () => {
    expect(describeDoc("- one\n- two\n  - nested\n\n- three\n\n1. a\n2. b")).toEqual(["ul-", "  item", "    p:one", "  item", "    p:two",
      "    ul-", "      item", "        p:nested", "  +item", "    p:three", "+ol1", "  item", "    p:a", "  item", "    p:b"]);
    expect(describeDoc("- [ ] todo\n- [x] done\n* other")).toEqual(["ul-", "  item[ ]", "    p:todo", "  item[x]", "    p:done", "ul*",
      "  item", "    p:other"]);
    expect(describeDoc("> quoted *text*\n> > deeper\n\n---\n```swift\nlet a = 1\n  b\n```\nafter")).toEqual(["quote",
      "> p:quoted {i}text", "> quote", "> > p:deeper", "+rule", "code:{c}let a = 1⏎  b", "p:after"]);
    expect(describeDoc("- - -")).toEqual(["rule"]);
  });
  it("gives the plain text", () => {
    expect(new MarkdownDocument("# Title\n\n- **bold** [link](https://x.y)\n- $x^2$\n\n> `code`\n---").plainText)
      .toEqual("Title\nbold link\nx^2\ncode");
  });
  it("stays bounded on hostile input", () => {
    const start = Date.now();
    for (const s of ["$1 ".repeat(20000), "[](".repeat(20000), "*a _b ".repeat(10000), "`".repeat(30000) + "x", "<ab:".repeat(15000),
      "> ".repeat(200) + "x"]) {
      expect(typeof new MarkdownDocument(s).plainText).toBe("string");
    }
    expect(Date.now() - start).toBeLessThan(20000);
  });
  it("keeps nested emphasis linear (Swift testNestedEmphasisStaysLinear)", () => {
    expect(describeDoc("*a *b c* d*")).toEqual(["p:{i}a b c d"]);
    expect(describeDoc("**a *b ~~c~~ d* e**")).toEqual(["p:{b}a {bi}b {bis}c{bi} d{b} e"]);
    expect(describeDoc("_a _b c_ d_")).toEqual(["p:{i}a b c d"]);
    const n = 65536 - 8;
    const start = Date.now();
    for (const s of ["*a ".repeat(n / 6 | 0) + "a* ".repeat(n / 6 | 0), "_a ".repeat(n / 6 | 0) + "a_ ".repeat(n / 6 | 0),
      "~~a ".repeat(n / 8 | 0) + "a~~ ".repeat(n / 8 | 0), "$$\n" + "\n".repeat(n - 4) + "x"]) {
      expect(typeof new MarkdownDocument(s).plainText).toBe("string");
    }
    // About 0.3 s here; quadratic emphasis took 2.6 s in V8 (40 s in a Swift debug build).
    expect(Date.now() - start).toBeLessThan(1500);
    const atoms = new MarkdownDocument("*a ".repeat(50) + "a* ".repeat(50)).blocks
      .flatMap((e) => (e.block.t === "paragraph" ? e.block.atoms : []));
    expect(new Set(atoms.map((a) => a.style))).toEqual(new Set([Style.italic]));
  });
  it("hashes like Swift", () => {
    expect(markdownHash("")).toBe("811c9dc5");
    expect(markdownHash("a")).toBe("e40c292c");
  });
});

interface Case {
  name: string;
  frame: number[];
  text: JSONObject;
  storedLayout: boolean;
  lines: { paragraph: number; start?: number; text: string; baseline: number }[];
  height: number;
  boxes: number[][];
  plain: string;
}

const cases = (JSON.parse(readFileSync(join(fixtures, "text", "markdown.json"), "utf8")) as { cases: Case[] }).cases;

describe("Markdown layout (shared fixtures)", () => {
  it("has the cases", () => expect(cases.map((c) => c.name)).toEqual(["mixed", "formula-boxes", "stale-layout", "rtl", "empty"]));
  for (const c of cases) {
    it(`lays out ${c.name} as the Swift renderer does`, () => {
      const [x, y, w, h] = c.frame as [number, number, number, number];
      const laid = layoutMarkdown(c.text, { x, y, w, h });
      expect(laid.usedStoredBreaks).toBe(c.storedLayout);
      if (c.storedLayout || c.name === "stale-layout" || c.name === "empty") {
        expect(laid.lines).toEqual(c.lines);
        expect(Math.round(laid.height * 1000) / 1000).toBe(c.height);
        expect(laid.boxes.map((b) => [Math.round(b.frame.y * 1000) / 1000, b.frame.w, b.frame.h])).toEqual(c.boxes);
      }
      if (c.storedLayout) expect(laid.breaks).toEqual((c.text.layout as { breaks: number[] }).breaks);
      expect(textOf(c.text)).toBe(c.plain);
      // Every fixture value is valid to the viewer's reader.
      expect(() => decodeItem({ id: "00000000-0000-4000-8000-000000000001", kind: "text", frame: c.frame, z: "a0", text: c.text },
        "item", new Budget())).not.toThrow();
    });
  }

  it("expands a box into text and math items with its shapes underneath, turned with the box", () => {
    const c = cases.find((k) => k.name === "formula-boxes") as Case;
    const it0 = prepareItem({ id: "x", kind: "text", frame: c.frame, z: "a0", rotation: 90, text: c.text });
    if (typeof it0 === "string") throw new Error(it0);
    const md = expandMarkdown(it0);
    const kinds = md?.pieces.map((p) => p.kind) ?? [];
    expect(kinds[0]).toBe("text");
    expect(kinds.filter((k) => k === "math")).toHaveLength(4);
    expect(kinds.slice(-4)).toEqual(["math", "math", "math", "math"]);
    expect(md?.pieces.every((p) => p.rotation === 90)).toBe(true);
    expect(md?.unrendered).toBe(0);
    const mixed = cases.find((k) => k.name === "mixed") as Case;
    const page = { id: "p", order: "a", strokes: [], items: [{ id: "00000000-0000-4000-8000-000000000002", kind: "text",
      frame: mixed.frame, z: "a0", text: mixed.text }] } as unknown as ConstructorParameters<typeof PreparedPage>[0];
    const meta = { pageSize: { width: 400, height: 600 }, paper: { kind: "blank", background: "#FFFFFFFF" } } as unknown as
      ConstructorParameters<typeof PreparedPage>[1];
    const prepared = new PreparedPage(page, meta);
    expect(prepared.warnings.some((w) => w.includes("2 formulas are drawn as its LaTeX source"))).toBe(true);
    const resolved = resolveItems(prepared);
    expect(resolved[0]?.underlay?.length ?? 0).toBeGreaterThan(5);
    expect(resolved.every((r) => r.draw.kind === "text")).toBe(true);
  });

  it("counts a box's pieces toward the items-per-page cap (Swift testMarkdownPiecesCountTowardTheItemsPerPageCap)", () => {
    const text = { size: 12, color: "#000000FF", markup: "markdown", runs: [{ t: "x\n\n".repeat(3000) }] };
    const items = [0, 1, 2, 3].map((k) => ({ id: `00000000-0000-4000-8000-00000000001${k}`, kind: "text",
      frame: [0, k * 50000, 300, 49000], z: `a${k}`, text }));
    const meta = { pageSize: { width: 400, height: 300, infinite: true }, paper: { kind: "blank", background: "#FFFFFFFF" } } as
      unknown as ConstructorParameters<typeof PreparedPage>[1];
    const page = (list: unknown[]) => ({ id: "p", order: "a", strokes: [], items: list }) as unknown as
      ConstructorParameters<typeof PreparedPage>[0];
    const all = new PreparedPage(page(items), meta);
    expect(all.items.length).toBe(10000);
    expect(all.warnings.some((w) => w.includes("more than 10000 items"))).toBe(true);
    const one = new PreparedPage(page([items[0]]), meta);
    expect(one.items.length).toBeLessThan(10000);
    expect(one.warnings.some((w) => w.includes("items; the rest"))).toBe(false);
  });
});
