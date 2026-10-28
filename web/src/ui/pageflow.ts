// Where the pages of a note sit, one under another, without outlining them first.
//
// Opening a note must not walk every point of every page (P45): each page starts with a
// provisional height and gets its exact one (the height `PreparedPage` draws) when it is drawn, or
// in idle time. Everything below a page that changes moves; the view keeps the page at the top of
// the screen where it was (`NoteView.anchored`).

export class PageFlow {
  private readonly hs: number[];
  private readonly ts: number[];
  private readonly done: boolean[];
  private dirty = 0;
  private left: number;
  /** First page whose top moved since `takeMoved` last said so (`Infinity`: none). */
  private moved = Infinity;

  /** `measure(i)` is the exact height of page `i` (the caller makes it total, e.g. 200 on error). */
  constructor(readonly count: number, readonly gap: number, provisional: number, private readonly measure: (i: number) => number) {
    this.hs = Array.from({ length: count }, () => provisional);
    this.ts = new Array<number>(count).fill(0);
    this.done = new Array<boolean>(count).fill(false);
    this.left = count;
  }

  get unresolved(): number {
    return this.left;
  }

  isExact(i: number): boolean {
    return this.done[i] === true;
  }

  height(i: number): number {
    return this.hs[i] ?? 0;
  }

  top(i: number): number {
    this.settle();
    return this.ts[i] ?? 0;
  }

  /** The content height: all pages and the gaps between them. */
  total(): number {
    if (this.count === 0) return 1;
    this.settle();
    const last = this.count - 1;
    return Math.max((this.ts[last] ?? 0) + (this.hs[last] ?? 0), 1);
  }

  private settle(): void {
    if (this.dirty >= this.count) return;
    let top = this.dirty === 0 ? 0 : (this.ts[this.dirty - 1] ?? 0) + (this.hs[this.dirty - 1] ?? 0) + this.gap;
    for (let i = this.dirty; i < this.count; i++) {
      this.ts[i] = top;
      top += (this.hs[i] ?? 0) + this.gap;
    }
    this.dirty = this.count;
  }

  /** The first page ending at or below content `y` (the last page when `y` is past them all). */
  indexAt(y: number): number {
    this.settle();
    let lo = 0, hi = this.count - 1;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if ((this.ts[mid] ?? 0) + (this.hs[mid] ?? 0) >= y) hi = mid;
      else lo = mid + 1;
    }
    return Math.max(lo, 0);
  }

  /** Sets page `i`'s exact height; true when it changed (and the pages below moved). */
  setExact(i: number, height: number): boolean {
    if (i < 0 || i >= this.count) return false;
    if (this.done[i] !== true) {
      this.done[i] = true;
      this.left--;
    }
    if (this.hs[i] === height) return false;
    this.hs[i] = height;
    this.dirty = Math.min(this.dirty, i + 1);
    this.moved = Math.min(this.moved, i);
    return true;
  }

  /** Measures page `i` if that has not been done yet. */
  resolve(i: number): boolean {
    return this.done[i] === true ? false : this.setExact(i, this.measure(i));
  }

  /** Measures pages around content `y` outward until `budgetMs` has passed (at least one); the number left. */
  resolveNear(y: number, budgetMs: number, now: () => number = () => performance.now()): number {
    const start = now();
    let a = this.indexAt(y), b = a + 1;
    while (this.left > 0 && (a >= 0 || b < this.count)) {
      // The nearer unmeasured side first.
      while (a >= 0 && this.done[a] === true) a--;
      while (b < this.count && this.done[b] === true) b++;
      const useA = a >= 0 && (b >= this.count || this.distance(a, y) <= this.distance(b, y));
      const i = useA ? a : b;
      if (i < 0 || i >= this.count) break;
      this.resolve(i);
      if (now() - start >= budgetMs) break;
    }
    return this.left;
  }

  private distance(i: number, y: number): number {
    const t = this.top(i), e = t + (this.hs[i] ?? 0);
    return y < t ? t - y : y > e ? y - e : 0;
  }

  /** The first page that moved or changed height since the last call; `-1` when none did. */
  takeMoved(): number {
    const m = this.moved;
    this.moved = Infinity;
    return m === Infinity ? -1 : m;
  }
}
