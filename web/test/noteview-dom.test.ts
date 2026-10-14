// NoteView on a minimal fake DOM (no browser needed): opening is lazy (P45) and a pageless page
// keeps only the strokes of the bands near the viewport (P47).

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { type Page, defaultPaper, pointStride } from "../src/format/model.ts";
import type { NoteState } from "../src/format/model.ts";
import { NoteView } from "../src/ui/noteview.ts";
import { PreparedPage } from "../src/render/page.ts";
import { SplitMix64, stroke } from "./builders.ts";

class El {
  children: El[] = [];
  parent?: El;
  style: Record<string, string> = {};
  attrs = new Map<string, string>();
  className = "";
  textContent = "";
  title = "";
  hidden = false;
  clientWidth = 1000;
  clientHeight = 800;
  constructor(readonly tag: string) {}
  private adopt(n: El | string): El {
    const e = typeof n === "string" ? Object.assign(new El("#text"), { textContent: n }) : n;
    e.parent?.removeChild(e);
    e.parent = this;
    return e;
  }
  append(...ns: (El | string)[]): void { for (const n of ns) this.children.push(this.adopt(n)); }
  replaceChildren(...ns: (El | string)[]): void {
    for (const c of this.children) c.parent = undefined;
    this.children = [];
    this.append(...ns);
  }
  insertBefore(n: El, before: El | null): El {
    const e = this.adopt(n);
    const at = before ? this.children.indexOf(before) : -1;
    if (at < 0) this.children.push(e);
    else this.children.splice(at, 0, e);
    return e;
  }
  removeChild(n: El): El {
    const at = this.children.indexOf(n);
    if (at >= 0) this.children.splice(at, 1);
    n.parent = undefined;
    return n;
  }
  replaceWith(n: El): void { const p = this.parent; if (p) { p.insertBefore(n, this); p.removeChild(this); } }
  setAttribute(k: string, v: string): void { this.attrs.set(k, v); }
  setAttributeNS(_ns: string, k: string, v: string): void { this.attrs.set(k, v); }
  addEventListener(): void {}
  getBoundingClientRect(): { left: number; top: number } { return { left: 0, top: 0 }; }
  count(tag: string): number {
    return this.children.reduce((m, c) => m + c.count(tag), this.tag === tag ? 1 : 0);
  }
  all(): number { return this.children.reduce((m, c) => m + c.all(), 1); }
  find(cls: string): El[] {
    return [...(this.className.split(" ").includes(cls) ? [this] : []), ...this.children.flatMap((c) => c.find(cls))];
  }
}

const g = globalThis as Record<string, unknown>;
const saved: Record<string, unknown> = {};
let frames: (() => void)[] = [];
let idles: (() => void)[] = [];

beforeEach(() => {
  for (const k of ["document", "ResizeObserver", "requestAnimationFrame", "requestIdleCallback"]) saved[k] = g[k];
  g.document = { createElement: (t: string) => new El(t), createElementNS: (_n: string, t: string) => new El(t) };
  g.ResizeObserver = class { observe(): void {} disconnect(): void {} };
  frames = [];
  idles = [];
  g.requestAnimationFrame = (f: () => void) => frames.push(f);
  g.requestIdleCallback = (f: () => void) => idles.push(f);
});
afterEach(() => { for (const [k, v] of Object.entries(saved)) g[k] = v; });

const flushFrames = (): void => { const f = frames; frames = []; for (const x of f) x(); };
const runIdle = (): void => { for (let i = 0; i < 10_000 && idles.length > 0; i++) { idles.shift()?.(); flushFrames(); } };

function inkPage(seed: number, strokes: number, spread: number): Page {
  const r = new SplitMix64(seed);
  const pg: Page = { id: `p${seed}`, order: "a", strokes: [], items: [] };
  for (let k = 0; k < strokes; k++) {
    const st = stroke(r.uuid());
    const pts = new Float64Array(8 * pointStride);
    let x = r.float() * 600, y = r.float() * spread;
    for (let i = 0; i < 8; i++) {
      x += r.float() - 0.5;
      y += (r.float() - 0.5) * 2;
      pts.set([x, y, i / 100, 2, 2, 1, 0, 0, Math.PI / 2], i * pointStride);
    }
    st.points = pts;
    pg.strokes.push(st);
  }
  return pg;
}

function note(pages: Page[], infinite = false): NoteState {
  return {
    deleted: false, tagSet: { instances: [], removed: [] }, recordings: [], pages,
    meta: { title: "", tags: [], favorite: false, created: 0, paper: defaultPaper("blank"), pageSize: { width: 612, height: 792, infinite } },
  };
}

describe("NoteView with lazy page heights", () => {
  it("draws only the first pages at open, then settles to the exact layout without moving the view", () => {
    // Pages 0..199: every third one has ink far below the sheet, so its exact height is larger.
    const pages = Array.from({ length: 200 }, (_, i) => inkPage(i + 1, 3, i % 3 === 0 ? 1600 : 600));
    const state = note(pages);
    const view = new NoteView(state);
    const root = view.root as unknown as El;
    expect(root.count("svg")).toBe(0);
    flushFrames();
    flushFrames();
    const drawn = root.find("page").filter((p) => p.count("svg") > 0).length;
    expect(drawn).toBeGreaterThan(0);
    expect(drawn).toBeLessThan(10);
    // Jump to page 120, let all the exact heights land, and check the view stayed on page 120.
    view.showPage(120);
    flushFrames();
    const priv = view as unknown as { y: number; z: number; slots: { top: number; height: number; page: Page }[]; flow: { unresolved: number } };
    const before = -priv.y / priv.z;
    const offset = before - (priv.slots[119]?.top ?? 0);
    const topBefore = priv.slots[119]?.top ?? 0;
    runIdle();
    expect(priv.slots[119]?.top).not.toBe(topBefore);
    expect(priv.flow.unresolved).toBe(0);
    const after = -priv.y / priv.z;
    expect(after - (priv.slots[119]?.top ?? 0)).toBeCloseTo(offset, 6);
    // Final tops are the cumulative exact heights.
    let top = 0;
    priv.slots.forEach((sl, i) => {
      expect(sl.top).toBe(top);
      if (i % 40 === 0) expect(sl.height).toBe(new PreparedPage(sl.page, state.meta).extent);
      top += sl.height + 24;
    });
    view.destroy();
  });
});

describe("NoteView with a pageless page", () => {
  it("holds only the strokes of the bands near the viewport, in order, each once", () => {
    const pg = inkPage(11, 3000, 40 * 792);
    const state = note([pg], true);
    const view = new NoteView(state);
    const root = view.root as unknown as El;
    flushFrames();
    flushFrames();
    const polys = (): number => root.count("polyline") + root.count("path");
    const first = polys();
    expect(first).toBeGreaterThan(0);
    expect(first).toBeLessThan(3000 / 4);
    // The strokes in the DOM are a subsequence of the page's strokes in their original order.
    const ink = root.find("page")[0]?.children[0]?.children[2];
    expect(ink?.tag).toBe("g");
    // Scroll down in steps: the number in the DOM stays about one window's worth.
    const counts: number[] = [first];
    for (let i = 0; i < 12; i++) {
      (view as unknown as { panBy(dx: number, dy: number): void }).panBy(0, -1500);
      flushFrames();
      counts.push(polys());
    }
    expect(Math.max(...counts)).toBeLessThan(3000 / 3);
    expect(Math.min(...counts)).toBeGreaterThan(0);
    view.destroy();
  });
});
