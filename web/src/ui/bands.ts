// Banding for tall (infinite) pages (P47). The strokes of such a page are sorted into bands of
// one chunk height by their [minY, maxY]; only the strokes of the bands near the viewport are
// outlined and put in the DOM, in their original drawing order, each exactly once.

/** The vertical span of one stroke. */
export interface Span {
  minY: number;
  maxY: number;
}

export interface BandChanges {
  /** Strokes that now touch a loaded band and were in none before. */
  add: number[];
  /** Strokes that no loaded band touches any more. */
  remove: number[];
}

export class StrokeBands {
  readonly bandCount: number;
  private readonly buckets: number[][];
  /** Loaded bands touching each stroke. */
  private readonly touching: Uint16Array<ArrayBuffer>;
  private readonly loaded = new Set<number>();
  private readonly bandHeight: number;

  constructor(spans: readonly Span[], readonly height: number, bandHeight: number) {
    this.bandCount = Math.max(Math.ceil(height / bandHeight), 1);
    this.bandHeight = bandHeight;
    this.buckets = Array.from({ length: this.bandCount }, () => []);
    this.touching = new Uint16Array(spans.length);
    spans.forEach((sp, i) => {
      const first = this.bandOf(sp.minY), last = this.bandOf(sp.maxY);
      for (let b = first; b <= last; b++) this.buckets[b]?.push(i);
    });
  }

  /** The band holding page-local `y` (clamped to the first and last). */
  bandOf(y: number): number {
    return Math.min(Math.max(Math.floor(y / this.bandHeight), 0), this.bandCount - 1);
  }

  /** The stroke indices of band `b`, ascending. */
  strokesIn(b: number): readonly number[] {
    return this.buckets[b] ?? [];
  }

  loadedBands(): number {
    return this.loaded.size;
  }

  /**
   * Loads the bands touching [nearLo, nearHi] and releases the loaded ones outside [farLo, farHi]
   * (page-local y). Returns the strokes to put in and to take out of the DOM.
   */
  update(nearLo: number, nearHi: number, farLo: number, farHi: number): BandChanges {
    const add: number[] = [], remove: number[] = [];
    const farFirst = this.bandOf(farLo), farLast = this.bandOf(farHi);
    for (const b of [...this.loaded]) {
      if (b >= farFirst && b <= farLast) continue;
      this.loaded.delete(b);
      for (const i of this.buckets[b] ?? []) {
        const n = (this.touching[i] ?? 0) - 1;
        this.touching[i] = n;
        if (n === 0) remove.push(i);
      }
    }
    if (nearHi >= 0 && nearLo <= this.height) {
      for (let b = this.bandOf(nearLo); b <= this.bandOf(nearHi); b++) {
        if (this.loaded.has(b)) continue;
        this.loaded.add(b);
        for (const i of this.buckets[b] ?? []) {
          const n = (this.touching[i] ?? 0) + 1;
          this.touching[i] = n;
          if (n === 1) add.push(i);
        }
      }
    }
    return { add, remove };
  }
}

/** The DOM operations `OrderedLayer` needs of its parent. */
export interface Parent<N> {
  insertBefore(node: N, before: N | null): unknown;
  removeChild(node: N): unknown;
}

/**
 * The elements of the strokes put in so far, kept in stroke order: a stroke that comes in later
 * (its band scrolled into view) goes in front of the next higher stroke already there, so the
 * result paints like the whole page drawn at once.
 */
export class OrderedLayer<N> {
  private order: number[] = [];
  private readonly nodes = new Map<number, N[]>();

  constructor(private readonly parent: Parent<N>) {}

  get size(): number {
    return this.order.length;
  }

  has(i: number): boolean {
    return this.nodes.has(i);
  }

  add(i: number, els: N[]): void {
    if (this.nodes.has(i)) return;
    // The first stroke index above i.
    let lo = 0, hi = this.order.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if ((this.order[mid] ?? 0) < i) lo = mid + 1;
      else hi = mid;
    }
    // Its first element (a stroke may have none).
    let before: N | null = null;
    for (let k = lo; k < this.order.length && before === null; k++) before = this.nodes.get(this.order[k] ?? -1)?.[0] ?? null;
    for (const e of els) this.parent.insertBefore(e, before);
    this.order.splice(lo, 0, i);
    this.nodes.set(i, els);
  }

  remove(i: number): void {
    const els = this.nodes.get(i);
    if (!els) return;
    for (const e of els) this.parent.removeChild(e);
    this.nodes.delete(i);
    let lo = 0, hi = this.order.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if ((this.order[mid] ?? 0) < i) lo = mid + 1;
      else hi = mid;
    }
    if (this.order[lo] === i) this.order.splice(lo, 1);
  }

  clear(): void {
    for (const i of [...this.nodes.keys()]) this.remove(i);
  }
}
