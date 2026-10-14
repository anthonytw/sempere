// Lazy page heights (P45) and the bands of a pageless page (P47): the pure parts of the note view.

import { describe, expect, it } from "vitest";
import { type Page, pointStride } from "../src/format/model.ts";
import { PreparedPage, defaultRenderOptions, pageSVG } from "../src/render/page.ts";
import { OrderedLayer, StrokeBands } from "../src/ui/bands.ts";
import { PageFlow } from "../src/ui/pageflow.ts";
import { pageExtent, provisionalHeight } from "../src/ui/noteview.ts";
import { SplitMix64, emptyState, stroke } from "./builders.ts";

/** A page of `strokes` strokes of `points` points each, scattered over `[0, spread)` vertically. */
function inkPage(seed: number, strokes: number, points: number, spread: number, length = 6): Page {
  const r = new SplitMix64(seed);
  const pg: Page = { id: `p${seed}`, order: "a", strokes: [], items: [] };
  for (let k = 0; k < strokes; k++) {
    const st = stroke(r.uuid());
    const pts = new Float64Array(points * pointStride);
    let x = r.float() * 600, y = r.float() * spread;
    for (let i = 0; i < points; i++) {
      x += (r.float() - 0.5) * 2;
      y += (r.float() - 0.5) * length;
      pts.set([x, y, i / 100, 2, 2, 1, 0, 0, Math.PI / 2], i * pointStride);
    }
    st.points = pts;
    if (k % 4 === 0) st.transform = [1, 0.01, -0.01, 1, 3, 5];
    pg.strokes.push(st);
  }
  return pg;
}

describe("PageFlow", () => {
  it("opens without measuring anything and measures only what is asked for", () => {
    let calls = 0;
    const flow = new PageFlow(300, 24, 792, () => { calls++; return 800; });
    expect(calls).toBe(0);
    expect(flow.total()).toBe(300 * 792 + 299 * 24);
    expect(flow.unresolved).toBe(300);
    flow.resolve(5);
    flow.resolve(5);
    expect(calls).toBe(1);
    expect(flow.height(5)).toBe(800);
    expect(flow.top(6)).toBe(6 * (792 + 24) + 8);
    expect(flow.total()).toBe(300 * 792 + 299 * 24 + 8);
  });

  it("indexAt finds the page at a position, also in a gap and past the ends", () => {
    const flow = new PageFlow(4, 10, 100, () => 100);
    expect(flow.indexAt(-50)).toBe(0);
    expect(flow.indexAt(0)).toBe(0);
    expect(flow.indexAt(100)).toBe(0);
    expect(flow.indexAt(105)).toBe(1);
    expect(flow.indexAt(110)).toBe(1);
    expect(flow.indexAt(1e9)).toBe(3);
    flow.setExact(0, 300);
    expect(flow.indexAt(250)).toBe(0);
    expect(flow.indexAt(315)).toBe(1);
  });

  it("measures nearest-first, outward, and stops at the budget", () => {
    const order: number[] = [];
    const flow = new PageFlow(21, 0, 10, (i) => { order.push(i); return 10; });
    let t = 0;
    const left = flow.resolveNear(105, 3, () => t++);
    expect(order.length).toBeGreaterThanOrEqual(1);
    expect(order[0]).toBe(10);
    expect(left).toBe(21 - order.length);
    flow.resolveNear(105, 1e9);
    expect(flow.unresolved).toBe(0);
    expect(order.slice(0, 5).map((i) => Math.abs(i - 10))).toEqual([0, 1, 1, 2, 2]);
    expect(new Set(order).size).toBe(21);
  });

  it("reports the first page that moved", () => {
    const flow = new PageFlow(5, 0, 10, () => 20);
    expect(flow.takeMoved()).toBe(-1);
    flow.setExact(3, 20);
    flow.setExact(2, 30);
    expect(flow.takeMoved()).toBe(2);
    expect(flow.takeMoved()).toBe(-1);
    flow.setExact(4, 10);
    expect(flow.takeMoved()).toBe(-1);
  });

  it("opening a dense note visits no points; the exact heights equal PreparedPage's", () => {
    const pages = Array.from({ length: 40 }, (_, i) => inkPage(i + 1, 20, 50, 1200));
    const state = emptyState(0, pages);
    let visited = 0;
    const flow = new PageFlow(pages.length, 24, provisionalHeight(state), (i) => {
      const pg = pages[i] as Page;
      visited += pg.strokes.reduce((m, st) => m + st.points.length / pointStride, 0);
      return pageExtent(pg, state);
    });
    expect(visited).toBe(0);
    flow.resolveNear(0, 1e9);
    expect(visited).toBe(40 * 20 * 50);
    pages.forEach((pg, i) => expect(flow.height(i)).toBe(new PreparedPage(pg, state.meta).extent));
  });

  it("is provisionally one sheet, or one chunk for a pageless note", () => {
    const state = emptyState(0, []);
    expect(provisionalHeight(state)).toBe(792);
    state.meta.pageSize = { width: 612, height: 0, infinite: true };
    expect(provisionalHeight(state)).toBeGreaterThan(0);
  });
});

describe("lazy outlines", () => {
  it("measure the page exactly as the eager preparation does, and outline to the same commands", () => {
    const state = emptyState(0, []);
    state.meta.pageSize = { width: 612, height: 792, infinite: true };
    const pg = inkPage(9, 60, 30, 6000);
    const eager = new PreparedPage(pg, state.meta);
    const lazy = new PreparedPage(pg, state.meta, { ...defaultRenderOptions, lazyOutline: true });
    expect(lazy.extent).toBe(eager.extent);
    expect(lazy.strokes.length).toBe(eager.strokes.length);
    lazy.strokes.forEach((st, i) => {
      const e = eager.strokes[i];
      expect([st.minY, st.maxY, st.centreY]).toEqual([e?.minY, e?.maxY, e?.centreY]);
      expect(st.commands).toEqual(e?.commands);
      st.discard?.();
      expect(st.commands).toEqual(e?.commands);
    });
  });

  it("leave the export untouched: pageSVG outlines eagerly", () => {
    const state = emptyState(0, []);
    const pg = inkPage(3, 5, 10, 500);
    const a = pageSVG(pg, state.meta);
    expect(a.strokes.length).toBeGreaterThan(0);
    expect(pageSVG(pg, state.meta, { ...defaultRenderOptions, lazyOutline: true }).strokes).toEqual(a.strokes);
  });
});

/** Minimal DOM-like parent: children in order. */
class Kids {
  list: string[] = [];
  insertBefore(n: string, before: string | null): void {
    const at = before === null ? this.list.length : this.list.indexOf(before);
    this.list.splice(at, 0, n);
  }
  removeChild(n: string): void {
    this.list.splice(this.list.indexOf(n), 1);
  }
}

describe("StrokeBands", () => {
  const spans = (pg: Page, state = emptyState(0, [])) => {
    state.meta.pageSize = { width: 612, height: 792, infinite: true };
    return new PreparedPage(pg, state.meta, { ...defaultRenderOptions, lazyOutline: true });
  };

  it("keeps stroke order, draws each stroke once, and holds exactly the strokes of the loaded bands", () => {
    for (const seed of [1, 2, 3]) {
      const prepared = spans(inkPage(seed, 400, 12, 20_000, 60));
      const h = 792;
      const bands = new StrokeBands(prepared.strokes, prepared.extent, h);
      const kids = new Kids();
      const layer = new OrderedLayer<string>(kids);
      const r = new SplitMix64(seed);
      for (let step = 0; step < 60; step++) {
        const lo = r.float() * prepared.extent - 500, hi = lo + 200 + r.float() * 3000;
        const c = bands.update(lo, hi, lo - 2000, hi + 2000);
        for (const i of c.remove) layer.remove(i);
        for (const i of c.add) {
          expect(layer.has(i)).toBe(false);
          layer.add(i, [`s${i}a`, `s${i}b`]);
        }
        // Expected: every stroke touching a loaded band, once each, in index order, two elements each.
        const want: string[] = [];
        prepared.strokes.forEach((st, i) => {
          const f = bands.bandOf(st.minY), l = bands.bandOf(st.maxY);
          for (let b = f; b <= l; b++) {
            if (bands.strokesIn(b).includes(i) && layer.has(i)) { want.push(`s${i}a`, `s${i}b`); break; }
          }
        });
        expect(kids.list).toEqual(want);
        expect(new Set(kids.list).size).toBe(kids.list.length);
      }
    }
  });

  it("holds only what the window touches", () => {
    const prepared = spans(inkPage(5, 600, 10, 30_000, 40));
    const bands = new StrokeBands(prepared.strokes, prepared.extent, 792);
    const c = bands.update(10_000, 11_500, 8_000, 13_500);
    const inWindow = prepared.strokes.filter((st) => st.maxY >= bands.bandOf(10_000) * 792 && st.minY < (bands.bandOf(11_500) + 1) * 792);
    expect(c.add.length).toBe(inWindow.length);
    expect(c.add.length).toBeLessThan(prepared.strokes.length / 5);
  });

  it("an element-less stroke does not break the order", () => {
    const kids = new Kids();
    const layer = new OrderedLayer<string>(kids);
    layer.add(5, ["e"]);
    layer.add(3, []);
    layer.add(1, ["a"]);
    layer.add(4, ["d"]);
    expect(kids.list).toEqual(["a", "d", "e"]);
    layer.remove(4);
    layer.remove(3);
    expect(kids.list).toEqual(["a", "e"]);
  });
});
