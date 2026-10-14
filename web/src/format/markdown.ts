// Markdown text boxes (format.md §8.2.4 "Markdown text", §8.5.4): the parser
// of the dialect, the plain text and the rendered paragraphs (font
// independent), as Sources/Sempere/Markdown.swift, MarkdownPlan.swift and
// MarkdownText.swift compute them. Every byte may be hostile (§9): linear
// scans, nesting bounded by `maxDepth`, link parts bounded.

import type { JSONObject } from "./json.ts";

export const markdownMaxDepth = 16;
const maxLinkPart = 1000;

export const enum Style { bold = 1, italic = 2, strike = 4, code = 8, link = 16 }

export type AtomKind =
  | { k: "char"; c: number }
  | { k: "formula"; latex: string; display: boolean }
  | { k: "break" };

export interface MDAtom {
  kind: AtomKind;
  offset: number;
  style: number;
  link?: number;
  latexOffsets?: number[];
}

export type MDBlock =
  | { t: "paragraph"; atoms: MDAtom[] }
  | { t: "heading"; level: number; atoms: MDAtom[] }
  | { t: "code"; atoms: MDAtom[] }
  | { t: "math"; atom: MDAtom }
  | { t: "rule"; offset: number }
  | { t: "quote"; entries: MDEntry[] }
  | { t: "list"; list: MDList };

export interface MDEntry { block: MDBlock; blankBefore: boolean }
export interface MDList { bullet?: number; delimiter?: number; start: number; items: MDItem[] }
export interface MDItem { task?: boolean; blocks: MDEntry[]; blankBefore: boolean }

interface Line { start: number; end: number }

const isSpaceOrTab = (c: number | undefined) => c === 0x20 || c === 0x09;
const isDigit = (c: number | undefined) => c !== undefined && c >= 0x30 && c <= 0x39;
export function isASCIIPunct(c: number | undefined): boolean {
  return c !== undefined && ((c >= 0x21 && c <= 0x2f) || (c >= 0x3a && c <= 0x40) || (c >= 0x5b && c <= 0x60) || (c >= 0x7b && c <= 0x7e));
}

/** Unicode `White_Space` (Swift `properties.isWhitespace`). */
export function isWhite(c: number): boolean {
  return (c >= 0x09 && c <= 0x0d) || c === 0x20 || c === 0x85 || c === 0xa0 || c === 0x1680 || (c >= 0x2000 && c <= 0x200a)
    || c === 0x2028 || c === 0x2029 || c === 0x202f || c === 0x205f || c === 0x3000;
}
const punct = /[\p{P}\p{S}]/u;
const control = /\p{Cc}/u;
function isPunct(c: number | undefined): boolean {
  if (c === undefined) return false;
  return isASCIIPunct(c) || punct.test(String.fromCodePoint(c));
}
const white = (c: number | undefined) => c === undefined || isWhite(c);

function str(cs: number[]): string {
  let s = "";
  for (let i = 0; i < cs.length; i += 4096) s += String.fromCodePoint(...cs.slice(i, i + 4096));
  return s;
}

/** A Markdown source parsed (format.md §8.5.4). */
export class MarkdownDocument {
  readonly blocks: MDEntry[];
  readonly links: string[] = [];
  private readonly src: number[];

  constructor(source: string) {
    const src: number[] = [];
    for (const ch of source) src.push(ch.codePointAt(0) ?? 0);
    this.src = src;
    const lines: Line[] = [];
    let start = 0;
    src.forEach((c, i) => {
      if (c === 0x0a) {
        lines.push({ start, end: i });
        start = i + 1;
      }
    });
    lines.push({ start, end: src.length });
    this.blocks = this.parseBlocks(lines, 0);
  }

  /** Every rendered paragraph's text, formulas as their source, joined with line feeds. */
  get plainText(): string {
    const out: number[] = [];
    let first = true;
    const atoms = (list: MDAtom[]) => {
      if (!first) out.push(0x0a);
      first = false;
      for (const a of list) {
        if (a.kind.k === "char") out.push(a.kind.c);
        else if (a.kind.k === "formula") for (const ch of a.kind.latex) out.push(ch.codePointAt(0) ?? 0);
        else out.push(0x0a);
      }
    };
    const walk = (entries: MDEntry[]) => {
      for (const e of entries) {
        const b = e.block;
        switch (b.t) {
          case "paragraph": case "heading": case "code": atoms(b.atoms); break;
          case "math": atoms([b.atom]); break;
          case "rule": break;
          case "quote": walk(b.entries); break;
          case "list": for (const item of b.list.items) walk(item.blocks); break;
        }
      }
    };
    walk(this.blocks);
    return str(out);
  }

  // MARK: Blocks

  private isBlank(l: Line): boolean {
    for (let i = l.start; i < l.end; i++) if (!isSpaceOrTab(this.src[i])) return false;
    return true;
  }

  private indent(l: Line): { columns: number; count: number } {
    let cols = 0, n = 0;
    while (l.start + n < l.end && isSpaceOrTab(this.src[l.start + n])) {
      cols += this.src[l.start + n] === 0x09 ? 4 : 1;
      n++;
    }
    return { columns: cols, count: n };
  }

  private dropIndent(l: Line, columns: number): Line {
    const out = { ...l };
    let cols = 0;
    while (cols < columns && out.start < out.end && isSpaceOrTab(this.src[out.start])) {
      cols += this.src[out.start] === 0x09 ? 4 : 1;
      out.start++;
    }
    return out;
  }

  private opening(l: Line): Line | undefined {
    const { columns, count } = this.indent(l);
    return columns <= 3 ? { start: l.start + count, end: l.end } : undefined;
  }

  private run(c: number, from: number, to: number): number {
    let j = from;
    while (j < to && this.src[j] === c) j++;
    return j - from;
  }

  private fence(t: Line): [number, number] | undefined {
    if (t.start >= t.end) return undefined;
    const c = this.src[t.start] ?? 0;
    if (c !== 0x60 && c !== 0x7e) return undefined;
    const n = this.run(c, t.start, t.end);
    if (n < 3) return undefined;
    if (c === 0x60) for (let k = t.start + n; k < t.end; k++) if (this.src[k] === 0x60) return undefined;
    return [c, n];
  }

  private startsMath(t: Line): boolean {
    if (t.end - t.start < 2 || this.src[t.start] !== 0x24 || this.src[t.start + 1] !== 0x24) return false;
    let e = t.end;
    while (e > t.start + 2 && isSpaceOrTab(this.src[e - 1])) e--;
    for (let k = t.start + 2; k + 1 < e; k++) {
      if (this.src[k] === 0x24 && this.src[k + 1] === 0x24) return k + 2 === e;
    }
    return true;
  }

  private heading(t: Line): number | undefined {
    const n = this.run(0x23, t.start, t.end);
    if (n < 1 || n > 6) return undefined;
    if (!(t.start + n === t.end || isSpaceOrTab(this.src[t.start + n]))) return undefined;
    return n;
  }

  private isRule(t: Line): boolean {
    if (t.start >= t.end) return false;
    const c = this.src[t.start];
    if (c !== 0x2d && c !== 0x2a && c !== 0x5f) return false;
    let count = 0;
    for (let i = t.start; i < t.end; i++) {
      if (this.src[i] === c) count++;
      else if (!isSpaceOrTab(this.src[i])) return false;
    }
    return count >= 3;
  }

  private listMarker(l: Line): { bullet?: number; number: number; delimiter?: number; contentStart: number; column: number } | undefined {
    const { columns: cols, count: n } = this.indent(l);
    if (cols > 3) return undefined;
    const p = l.start + n;
    if (p >= l.end) return undefined;
    let bullet: number | undefined, delimiter: number | undefined;
    let number = 0, m: number;
    const c = this.src[p] ?? 0;
    if (c === 0x2d || c === 0x2b || c === 0x2a) {
      bullet = c;
      m = 1;
    } else {
      let d = 0;
      while (p + d < l.end && d < 10 && isDigit(this.src[p + d])) d++;
      if (d < 1 || d > 9 || p + d >= l.end || (this.src[p + d] !== 0x2e && this.src[p + d] !== 0x29)) return undefined;
      for (let k = 0; k < d; k++) number = number * 10 + ((this.src[p + k] ?? 0x30) - 0x30);
      delimiter = this.src[p + d];
      m = d + 1;
    }
    const after = p + m;
    if (!(after === l.end || isSpaceOrTab(this.src[after]))) return undefined;
    let k = 0, kcols = 0;
    while (after + k < l.end && isSpaceOrTab(this.src[after + k]) && kcols < 5) {
      kcols += this.src[after + k] === 0x09 ? 4 : 1;
      k++;
    }
    let restBlank = true;
    for (let q = after + k; q < l.end; q++) if (!isSpaceOrTab(this.src[q])) { restBlank = false; break; }
    let contentStart = after + k;
    if (kcols === 0 || kcols > 4 || restBlank) {
      kcols = 1;
      contentStart = Math.min(after + 1, l.end);
      if (restBlank) contentStart = l.end;
    }
    const out: { bullet?: number; number: number; delimiter?: number; contentStart: number; column: number } = {
      number, contentStart, column: cols + m + kcols,
    };
    if (bullet !== undefined) out.bullet = bullet;
    if (delimiter !== undefined) out.delimiter = delimiter;
    return out;
  }

  private startsBlock(l: Line, depth: number): boolean {
    const t = this.opening(l);
    if (!t) return false;
    if (this.fence(t) || this.startsMath(t) || this.heading(t) !== undefined || this.isRule(t)) return true;
    if (depth >= markdownMaxDepth) return false;
    if (t.start < t.end && this.src[t.start] === 0x3e) return true;
    return this.listMarker(l) !== undefined;
  }

  private parseBlocks(lines: Line[], depth: number): MDEntry[] {
    const out: MDEntry[] = [];
    const src = this.src;
    let blank = false;
    let i = 0;
    while (i < lines.length) {
      const l = lines[i] as Line;
      if (this.isBlank(l)) { blank = true; i++; continue; }
      const blankBefore = blank && out.length > 0;
      blank = false;
      const t = this.opening(l);
      if (!t) {
        const [b, next] = this.paragraph(lines, i, depth);
        out.push({ block: b, blankBefore });
        i = next;
        continue;
      }
      const fence = this.fence(t);
      if (fence) {
        const [c, n] = fence;
        const ind = this.indent(l).columns;
        const atoms: MDAtom[] = [];
        let j = i + 1;
        let firstLine = true;
        while (j < lines.length) {
          const u = this.opening(lines[j] as Line);
          if (u && u.start < u.end && src[u.start] === c) {
            const r = this.run(c, u.start, u.end);
            let rest = true;
            for (let q = u.start + r; q < u.end; q++) if (!isSpaceOrTab(src[q])) { rest = false; break; }
            if (r >= n && rest) { j++; break; }
          }
          const content = this.dropIndent(lines[j] as Line, ind);
          if (!firstLine) atoms.push({ kind: { k: "break" }, offset: (lines[j] as Line).start - 1, style: Style.code });
          firstLine = false;
          for (let k = content.start; k < content.end; k++) atoms.push({ kind: { k: "char", c: src[k] ?? 0 }, offset: k, style: Style.code });
          j++;
        }
        out.push({ block: { t: "code", atoms }, blankBefore });
        i = j;
        continue;
      }
      if (this.startsMath(t)) {
        const m = this.displayMath(lines, i, t);
        if (m) {
          out.push({ block: { t: "math", atom: m[0] }, blankBefore });
          i = m[1];
          continue;
        }
      }
      const level = this.heading(t);
      if (level !== undefined) {
        let s = t.start + level, e = t.end;
        while (s < e && isSpaceOrTab(src[s])) s++;
        while (e > s && isSpaceOrTab(src[e - 1])) e--;
        let h = e;
        while (h > s && src[h - 1] === 0x23) h--;
        if (h < e && (h === s || isSpaceOrTab(src[h - 1]))) {
          e = h;
          while (e > s && isSpaceOrTab(src[e - 1])) e--;
        }
        const chars: [number, number][] = [];
        for (let k = s; k < e; k++) chars.push([k, src[k] ?? 0]);
        out.push({ block: { t: "heading", level, atoms: this.inline(chars) }, blankBefore });
        i++;
        continue;
      }
      if (this.isRule(t)) {
        out.push({ block: { t: "rule", offset: t.start }, blankBefore });
        i++;
        continue;
      }
      if (depth < markdownMaxDepth && t.start < t.end && src[t.start] === 0x3e) {
        const inner: Line[] = [];
        let j = i;
        for (; j < lines.length; j++) {
          const u = this.opening(lines[j] as Line);
          if (!u || u.start >= u.end || src[u.start] !== 0x3e) break;
          let s = u.start + 1;
          if (s < u.end && isSpaceOrTab(src[s])) s++;
          inner.push({ start: s, end: u.end });
        }
        out.push({ block: { t: "quote", entries: this.parseBlocks(inner, depth + 1) }, blankBefore });
        i = j;
        continue;
      }
      const first = depth < markdownMaxDepth ? this.listMarker(l) : undefined;
      if (first) {
        const list: MDList = { start: first.number, items: [] };
        if (first.bullet !== undefined) list.bullet = first.bullet;
        if (first.delimiter !== undefined) list.delimiter = first.delimiter;
        const same = (m: ReturnType<MarkdownDocument["listMarker"]>) => m !== undefined && m.bullet === first.bullet && m.delimiter === first.delimiter;
        let j = i;
        let itemBlank = false;
        while (j < lines.length) {
          if (this.isBlank(lines[j] as Line)) {
            let k = j;
            while (k < lines.length && this.isBlank(lines[k] as Line)) k++;
            if (!(k < lines.length && same(this.listMarker(lines[k] as Line)))) break;
            itemBlank = true;
            j = k;
            continue;
          }
          const m = this.listMarker(lines[j] as Line);
          if (!m || !same(m)) break;
          const content: Line[] = [{ start: m.contentStart, end: (lines[j] as Line).end }];
          let k = j + 1;
          while (k < lines.length) {
            if (this.isBlank(lines[k] as Line)) {
              let q = k;
              while (q < lines.length && this.isBlank(lines[q] as Line)) q++;
              if (!(q < lines.length && this.indent(lines[q] as Line).columns >= m.column)) break;
              for (let b = k; b < q; b++) content.push(this.dropIndent(lines[b] as Line, m.column));
              k = q;
              continue;
            }
            if (this.indent(lines[k] as Line).columns < m.column) break;
            content.push(this.dropIndent(lines[k] as Line, m.column));
            k++;
          }
          let task: boolean | undefined;
          const c0 = content[0] as Line;
          const mark = src[c0.start + 1];
          if (c0.end - c0.start >= 3 && src[c0.start] === 0x5b && src[c0.start + 2] === 0x5d
            && (mark === 0x20 || mark === 0x78 || mark === 0x58)
            && (c0.start + 3 === c0.end || isSpaceOrTab(src[c0.start + 3]))) {
            task = mark !== 0x20;
            c0.start = Math.min(c0.start + 4, c0.end);
          }
          const item: MDItem = { blocks: this.parseBlocks(content, depth + 1), blankBefore: itemBlank };
          if (task !== undefined) item.task = task;
          list.items.push(item);
          itemBlank = false;
          j = k;
        }
        out.push({ block: { t: "list", list }, blankBefore });
        i = j;
        continue;
      }
      const [b, next] = this.paragraph(lines, i, depth);
      out.push({ block: b, blankBefore });
      i = next;
    }
    return out;
  }

  private displayMath(lines: Line[], i: number, t: Line): [MDAtom, number] | undefined {
    const src = this.src;
    const open = t.start;
    let s = t.start + 2, e = t.end;
    while (e > s && isSpaceOrTab(src[e - 1])) e--;
    let chars: [number, number][] = [];
    const add = (a: number, b: number) => { for (let k = a; k < Math.max(a, b); k++) chars.push([k, src[k] ?? 0]); };
    let next = i + 1;
    if (e - s >= 2 && src[e - 1] === 0x24 && src[e - 2] === 0x24) {
      add(s, e - 2);
    } else {
      add(s, e);
      let j = i + 1;
      while (j < lines.length) {
        const l = lines[j] as Line;
        chars.push([l.start - 1, 0x0a]);
        s = l.start;
        e = l.end;
        while (e > s && isSpaceOrTab(src[e - 1])) e--;
        if (e - s >= 2 && src[e - 1] === 0x24 && src[e - 2] === 0x24) {
          add(s, e - 2);
          j++;
          break;
        }
        add(s, e);
        j++;
      }
      next = j;
    }
    const trim = (c: number) => c === 0x20 || c === 0x09 || c === 0x0a;
    let a = 0, b = chars.length;
    while (a < b && trim((chars[a] as [number, number])[1])) a++;
    while (b > a && trim((chars[b - 1] as [number, number])[1])) b--;
    chars = chars.slice(a, b);
    if (chars.length === 0) return undefined;
    return [{ kind: { k: "formula", latex: str(chars.map((x) => x[1])), display: true }, offset: open, style: 0,
      latexOffsets: chars.map((x) => x[0]) }, next];
  }

  private paragraph(lines: Line[], i: number, depth: number): [MDBlock, number] {
    const src = this.src;
    const chars: [number, number][] = [];
    let j = i;
    while (j < lines.length) {
      const l = lines[j] as Line;
      if (j > i && (this.isBlank(l) || this.startsBlock(l, depth))) break;
      let s = l.start, e = l.end;
      while (s < e && isSpaceOrTab(src[s])) s++;
      while (e > s && isSpaceOrTab(src[e - 1])) e--;
      if (e > s && src[e - 1] === 0x5c && !(e - 2 >= s && src[e - 2] === 0x5c)) e--;
      if (j > i) chars.push([(lines[j - 1] as Line).end, 0x0a]);
      for (let k = s; k < e; k++) chars.push([k, src[k] ?? 0]);
      j++;
    }
    return [{ t: "paragraph", atoms: this.inline(chars) }, j];
  }

  // MARK: Inline

  private inline(chars: [number, number][]): MDAtom[] {
    return new InlineParser(chars, this.links).parse();
  }
}

interface Tok {
  kind: "char" | "formula" | "break" | "delim";
  c: number;
  latex?: string;
  display?: boolean;
  latexOffsets?: number[];
  offset: number;
  style: number;
  link?: number;
  deleted?: boolean;
  lo: number;
  hi: number;
  canOpen: boolean;
  canClose: boolean;
}

class InlineParser {
  private toks: Tok[] = [];
  /** Emphasis matches: tokens [lo, hi) take `style`; applied once when flattening (linear, as in Swift). */
  private emphasis: { lo: number; hi: number; style: number }[] = [];

  constructor(private readonly chars: [number, number][], private readonly links: string[]) {}

  private c(i: number): number | undefined {
    return i >= 0 && i < this.chars.length ? (this.chars[i] as [number, number])[1] : undefined;
  }

  private tok(kind: Tok["kind"], c: number, offset: number, style = 0): Tok {
    return { kind, c, offset, style, lo: 0, hi: 0, canOpen: false, canClose: false };
  }

  parse(): MDAtom[] {
    const chars = this.chars;
    const n = chars.length;
    const ch = (i: number) => (chars[i] as [number, number])[1];
    const off = (i: number) => (chars[i] as [number, number])[0];
    const nextDollar = new Array<number>(n + 1).fill(n);
    for (let i = n - 1; i >= 0; i--) {
      nextDollar[i] = nextDollar[i + 1] ?? n;
      if (ch(i) === 0x24 && i > 0 && !white(ch(i - 1)) && ch(i - 1) !== 0x5c && !isDigit(this.c(i + 1))) nextDollar[i] = i;
    }
    const nextDouble = new Array<number>(n + 1).fill(n);
    for (let i = n - 1; i >= 0; i--) nextDouble[i] = ch(i) === 0x24 && this.c(i + 1) === 0x24 ? i : nextDouble[i + 1] ?? n;
    const runs = new Map<number, number[]>();
    for (let i = 0; i < n;) {
      if (ch(i) === 0x60) {
        let j = i;
        while (j < n && ch(j) === 0x60) j++;
        const list = runs.get(j - i) ?? [];
        list.push(i);
        runs.set(j - i, list);
        i = j;
      } else {
        i++;
      }
    }
    const runCursor = new Map<number, number>();
    const stack: number[] = [];
    const bottom = new Map<number, number>();
    const brackets: { tok: number; image: boolean; stack: number; active: boolean }[] = [];
    let i = 0;
    while (i < n) {
      const o = off(i), c = ch(i);
      if (c === 0x5c) {
        const next = this.c(i + 1);
        if (next !== undefined && isASCIIPunct(next)) {
          this.toks.push(this.tok("char", next, off(i + 1)));
          i += 2;
        } else {
          this.toks.push(this.tok("char", c, o));
          i++;
        }
      } else if (c === 0x0a) {
        this.toks.push(this.tok("break", c, o));
        i++;
      } else if (c === 0x60) {
        let j = i;
        while (j < n && ch(j) === 0x60) j++;
        const len = j - i;
        const list = runs.get(len) ?? [];
        let k = runCursor.get(len) ?? 0;
        while (k < list.length && (list[k] ?? 0) <= i) k++;
        runCursor.set(len, k);
        if (k < list.length) {
          const close = list[k] ?? n;
          let content = chars.slice(j, close).map(([a, b]) => [a, b === 0x0a ? 0x20 : b] as [number, number]);
          if (content.length >= 2 && content[0]?.[1] === 0x20 && content[content.length - 1]?.[1] === 0x20
            && !content.every((x) => x[1] === 0x20)) {
            content = content.slice(1, -1);
          }
          for (const [a, b] of content) this.toks.push(this.tok("char", b, a, Style.code));
          i = close + len;
        } else {
          for (let q = i; q < j; q++) this.toks.push(this.tok("char", 0x60, off(q)));
          i = j;
        }
      } else if (c === 0x24) {
        if (this.c(i + 1) === 0x24) {
          const close = nextDouble[Math.min(i + 2, n)] ?? n;
          if (close < n && close > i + 2) {
            const t = this.tok("formula", 0, o);
            t.latex = str(chars.slice(i + 2, close).map((x) => x[1]));
            t.display = true;
            t.latexOffsets = chars.slice(i + 2, close).map((x) => x[0]);
            this.toks.push(t);
            i = close + 2;
          } else {
            this.toks.push(this.tok("char", 0x24, o), this.tok("char", 0x24, off(i + 1)));
            i += 2;
          }
        } else {
          const next = this.c(i + 1);
          const close = next !== undefined && !white(next) ? nextDollar[Math.min(i + 2, n)] ?? n : n;
          if (close < n) {
            const t = this.tok("formula", 0, o);
            t.latex = str(chars.slice(i + 1, close).map((x) => x[1]));
            t.display = false;
            t.latexOffsets = chars.slice(i + 1, close).map((x) => x[0]);
            this.toks.push(t);
            i = close + 1;
          } else {
            this.toks.push(this.tok("char", 0x24, o));
            i++;
          }
        }
      } else if (c === 0x2a || c === 0x5f || c === 0x7e) {
        let j = i;
        while (j < n && ch(j) === c) j++;
        const count = j - i;
        if (c === 0x7e && count !== 2) {
          for (let q = i; q < j; q++) this.toks.push(this.tok("char", 0x7e, off(q)));
          i = j;
          continue;
        }
        const before = this.c(i - 1), after = this.c(j);
        const left = !white(after) && (!isPunct(after) || white(before) || isPunct(before));
        const right = !white(before) && (!isPunct(before) || white(after) || isPunct(after));
        const t = this.tok("delim", c, o);
        t.lo = i;
        t.hi = j;
        if (c === 0x5f) {
          t.canOpen = left && (!right || isPunct(before));
          t.canClose = right && (!left || isPunct(after));
        } else {
          t.canOpen = left;
          t.canClose = right;
        }
        this.toks.push(t);
        const index = this.toks.length - 1;
        if (t.canClose) this.matchCloser(index, stack, bottom);
        if (t.canOpen && t.hi > t.lo) stack.push(index);
        i = j;
      } else if (c === 0x21 && this.c(i + 1) === 0x5b) {
        this.toks.push(this.tok("char", 0x21, o), this.tok("char", 0x5b, off(i + 1)));
        brackets.push({ tok: this.toks.length - 1, image: true, stack: stack.length, active: true });
        i += 2;
      } else if (c === 0x5b) {
        this.toks.push(this.tok("char", 0x5b, o));
        brackets.push({ tok: this.toks.length - 1, image: false, stack: stack.length, active: true });
        i++;
      } else if (c === 0x5d) {
        const b = brackets.pop();
        const tail = b?.active ? this.linkTail(i) : undefined;
        if (b && tail) {
          (this.toks[b.tok] as Tok).deleted = true;
          if (b.image) {
            (this.toks[b.tok - 1] as Tok).deleted = true;
          } else {
            const index = this.links.length;
            this.links.push(tail[0]);
            for (let q = b.tok + 1; q < this.toks.length; q++) {
              const t = this.toks[q] as Tok;
              if (t.link === undefined) { t.style |= Style.link; t.link = index; }
            }
            for (const other of brackets) if (!other.image) other.active = false;
          }
          if (stack.length > b.stack) stack.length = b.stack;
          for (const [k, v] of bottom) if (v > stack.length) bottom.set(k, stack.length);
          i = tail[1];
        } else {
          this.toks.push(this.tok("char", 0x5d, o));
          i++;
        }
      } else if (c === 0x3c) {
        const auto = this.autolink(i);
        if (auto) {
          const index = this.links.length;
          this.links.push(auto[0]);
          for (let q = i + 1; q < auto[1] - 1; q++) {
            const t = this.tok("char", ch(q), off(q), Style.link);
            t.link = index;
            this.toks.push(t);
          }
          i = auto[1];
        } else {
          this.toks.push(this.tok("char", c, o));
          i++;
        }
      } else {
        this.toks.push(this.tok("char", c, o));
        i++;
      }
    }
    // Emphasis styles, from per-style coverage counts (a difference array each).
    for (const style of [Style.bold, Style.italic, Style.strike] as number[]) {
      const delta = new Int32Array(this.toks.length + 1);
      let any = false;
      for (const e of this.emphasis) {
        if (e.style !== style || e.lo >= e.hi) continue;
        delta[e.lo] = (delta[e.lo] ?? 0) + 1;
        delta[e.hi] = (delta[e.hi] ?? 0) - 1;
        any = true;
      }
      if (!any) continue;
      let depth = 0;
      for (let q = 0; q < this.toks.length; q++) {
        depth += delta[q] ?? 0;
        if (depth > 0) (this.toks[q] as Tok).style |= style;
      }
    }
    const out: MDAtom[] = [];
    for (const t of this.toks) {
      if (t.deleted) continue;
      const withLink = (a: MDAtom): MDAtom => { if (t.link !== undefined) a.link = t.link; return a; };
      switch (t.kind) {
        case "char": out.push(withLink({ kind: { k: "char", c: t.c }, offset: t.offset, style: t.style })); break;
        case "formula": out.push(withLink({ kind: { k: "formula", latex: t.latex ?? "", display: t.display ?? false }, offset: t.offset,
          style: t.style, latexOffsets: t.latexOffsets ?? [] })); break;
        case "break": out.push({ kind: { k: "break" }, offset: t.offset, style: t.style }); break;
        case "delim":
          for (let q = t.lo; q < t.hi; q++) out.push(withLink({ kind: { k: "char", c: ch(q) }, offset: off(q), style: t.style }));
          break;
      }
    }
    return out;
  }

  private matchCloser(k: number, stack: number[], bottom: Map<number, number>): void {
    const closer = this.toks[k] as Tok;
    const c = closer.c;
    while (closer.hi > closer.lo) {
      const floor = Math.min(bottom.get(c) ?? 0, stack.length);
      let found = -1;
      for (let p = stack.length - 1; p >= floor; p--) {
        const o = this.toks[stack[p] ?? 0] as Tok;
        if (o.kind === "delim" && o.c === c && o.hi > o.lo) { found = p; break; }
      }
      if (found < 0) {
        bottom.set(c, stack.length);
        return;
      }
      const oi = stack[found] ?? 0;
      const opener = this.toks[oi] as Tok;
      let use: number, style: number;
      if (c === 0x7e) { use = 2; style = Style.strike; }
      else if (opener.hi - opener.lo >= 2 && closer.hi - closer.lo >= 2) { use = 2; style = Style.bold; }
      else { use = 1; style = Style.italic; }
      opener.hi -= use;
      closer.lo += use;
      this.emphasis.push({ lo: oi + 1, hi: k, style });
      stack.length = found + 1;
      if (opener.hi === opener.lo) stack.length = found;
      for (const [key, v] of bottom) if (v > stack.length) bottom.set(key, stack.length);
    }
  }

  private linkTail(i: number): [string, number] | undefined {
    let j = i + 1;
    if (this.c(j) !== 0x28) return undefined;
    j++;
    const limit = Math.min(this.chars.length, j + 2 * maxLinkPart + 8);
    const skip = () => { while (j < limit) { const s = this.c(j); if (s === 0x20 || s === 0x09 || s === 0x0a) j++; else break; } };
    skip();
    const dest: number[] = [];
    if (this.c(j) === 0x3c) {
      j++;
      while (j < limit) {
        const s = this.c(j);
        if (s === undefined || s === 0x3e) break;
        if (s === 0x0a || s === 0x3c) return undefined;
        const e = this.c(j + 1);
        if (s === 0x5c && isASCIIPunct(e)) { dest.push(e as number); j += 2; continue; }
        dest.push(s);
        j++;
      }
      if (this.c(j) !== 0x3e) return undefined;
      j++;
    } else {
      let depth = 0;
      const start = j;
      while (j < limit) {
        const s = this.c(j);
        if (s === undefined || isSpaceOrTab(s) || s === 0x0a || control.test(String.fromCodePoint(s))) break;
        if (j - start > maxLinkPart) return undefined;
        const e = this.c(j + 1);
        if (s === 0x5c && isASCIIPunct(e)) { dest.push(e as number); j += 2; continue; }
        if (s === 0x28) { depth++; if (depth > 32) return undefined; }
        if (s === 0x29) { if (depth === 0) break; depth--; }
        dest.push(s);
        j++;
      }
      if (depth !== 0) return undefined;
    }
    const beforeTitle = j;
    skip();
    const q = this.c(j);
    if (j > beforeTitle && (q === 0x22 || q === 0x27 || q === 0x28)) {
      const close = q === 0x28 ? 0x29 : q;
      j++;
      const start = j;
      while (j < limit && this.c(j) !== close && this.c(j) !== undefined) {
        if (j - start > maxLinkPart) return undefined;
        if (this.c(j) === 0x5c) j++;
        j++;
      }
      if (this.c(j) !== close) return undefined;
      j++;
      skip();
    }
    if (this.c(j) !== 0x29) return undefined;
    return [str(dest), j + 1];
  }

  private autolink(i: number): [string, number] | undefined {
    let j = i + 1;
    const letter = (c: number | undefined) => c !== undefined && ((c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a));
    if (!letter(this.c(j))) return undefined;
    let schemeLength = 0;
    for (;;) {
      const s = this.c(j);
      if (!(letter(s) || isDigit(s) || s === 0x2b || s === 0x2e || s === 0x2d)) break;
      schemeLength++;
      j++;
      if (schemeLength > 32) return undefined;
    }
    if (schemeLength < 2 || this.c(j) !== 0x3a) return undefined;
    j++;
    const limit = Math.min(this.chars.length, j + 2048);
    while (j < limit) {
      const s = this.c(j);
      if (s === undefined || s === 0x3e) break;
      if (s === 0x3c || isWhite(s) || s < 0x20) return undefined;
      j++;
    }
    if (this.c(j) !== 0x3e) return undefined;
    return [str(this.chars.slice(i + 1, j).map((x) => x[1])), j + 1];
  }
}

// MARK: - Box fields

/** FNV-1a 32-bit of the UTF-8 bytes of `text`, 8 lowercase hex digits (format.md §8.2.4 `layout.of`). */
export function markdownHash(text: string): string {
  let h = 0x811c9dc5;
  for (const b of new TextEncoder().encode(text)) {
    h ^= b;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, "0");
}

export const linkColor = "#1F6FEBFF";

/** True for a Markdown text value (`markup` `markdown`). */
export function isMarkdown(text: JSONObject | undefined): boolean {
  return text !== undefined && text.markup === "markdown";
}

/** The text of a text value as search sees it: a Markdown box's plain text, any other's runs. */
export function textOf(text: JSONObject): string {
  const runs = Array.isArray(text.runs) ? text.runs as JSONObject[] : [];
  const s = runs.map((r) => typeof r.t === "string" ? r.t : "").join("");
  return isMarkdown(text) ? new MarkdownDocument(s).plainText : s;
}

// MARK: - Rendered paragraphs (MarkdownPlan.swift)

/** A run's attributes as stored (format.md §8.2.4), the box's where absent. */
export interface PlanRun {
  b: boolean;
  i: boolean;
  u: boolean;
  s: boolean;
  color?: string;
  size?: number;
  font?: "mono";
}

export interface Formula {
  latex: string;
  display: boolean;
  size: number;
  color: string;
}

/** A typeset formula of the box (`math` entry) as drawn: its value and metrics. */
export interface TypesetFormula {
  math: JSONObject;
  w: number;
  h: number;
  depth: number;
}

export type PlanAtomKind = { k: "char"; c: number } | { k: "box"; f: TypesetFormula } | { k: "break" };

export interface PlanAtom {
  kind: PlanAtomKind;
  offset: number;
  run: PlanRun;
}

export type Marker = { k: "bullet"; ring: boolean } | { k: "task"; checked: boolean } | { k: "ordered"; label: string };

export interface PlanParagraph {
  kind: "text" | "code" | "displayMath" | "rule";
  atoms: PlanAtom[];
  size: number;
  bold: boolean;
  indent: number;
  column: number;
  gapBefore: number;
  pad: number;
  marker?: Marker;
  align: string;
}

export interface QuoteBar { x: number; first: number; last: number }

/** The box style a plan needs (format.md §8.2.4), unknown values as renderers map them. */
export interface BoxStyle {
  font: "sans" | "serif" | "mono";
  size: number;
  color: string;
  align: string;
  dir: string;
  lang?: string;
}

export const metrics = {
  headingScale: [1.6, 1.4, 1.2, 1, 1, 1], gap: 0.5, quoteIndent: 1, quoteBarX: 0.25, quoteBarWidth: 0.15,
  listIndent: 1.6, codeInset: 0.5, codePad: 0.25,
};

export function round3(v: number): number {
  return Math.round(v * 1000) / 1000;
}

/** The typeset formulas of a text value that decode (format.md §8.2.4 `math`). */
export function typesetFormulas(text: JSONObject): TypesetFormula[] {
  const out: TypesetFormula[] = [];
  for (const m of Array.isArray(text.math) ? text.math as JSONObject[] : []) {
    const rs = m.renderSize;
    if (!m.render || !Array.isArray(rs) || typeof rs[0] !== "number" || typeof rs[1] !== "number" || typeof m.depth !== "number") continue;
    out.push({ math: m, w: rs[0], h: rs[1], depth: m.depth });
  }
  return out;
}

function findFormula(list: TypesetFormula[], f: Formula): TypesetFormula | undefined {
  return list.find((t) => t.math.latex === f.latex && t.math.display === f.display && typeof t.math.size === "number"
    && round3(t.math.size) === round3(f.size) && String(t.math.color).toUpperCase() === f.color.toUpperCase());
}

export class MarkdownPlan {
  readonly paragraphs: PlanParagraph[] = [];
  readonly bars: QuoteBar[] = [];
  readonly formulas: Formula[] = [];
  readonly links: string[];
  private pendingMarker: Marker | undefined;
  private readonly typeset: TypesetFormula[];

  constructor(readonly source: string, readonly box: BoxStyle, typeset: TypesetFormula[]) {
    this.typeset = typeset;
    const doc = new MarkdownDocument(source);
    this.links = doc.links;
    this.walk(doc.blocks, 0, 0, 0);
  }

  private run(style: number, size: number, bold: boolean): PlanRun {
    const r: PlanRun = { b: bold || (style & Style.bold) !== 0, i: (style & Style.italic) !== 0, u: (style & Style.link) !== 0,
      s: (style & Style.strike) !== 0 };
    if (style & Style.link) r.color = linkColor;
    if (size !== this.box.size) r.size = size;
    if (style & Style.code) r.font = "mono";
    return r;
  }

  private atoms(list: MDAtom[], size: number, bold: boolean): PlanAtom[] {
    const out: PlanAtom[] = [];
    for (const a of list) {
      const r = this.run(a.style, size, bold);
      if (a.kind.k === "char") out.push({ kind: { k: "char", c: a.kind.c }, offset: a.offset, run: r });
      else if (a.kind.k === "break") out.push({ kind: { k: "break" }, offset: a.offset, run: r });
      else {
        const f: Formula = { latex: a.kind.latex, display: a.kind.display, size, color: r.color ?? this.box.color };
        this.formulas.push(f);
        const t = findFormula(this.typeset, f);
        if (t) {
          out.push({ kind: { k: "box", f: t }, offset: a.offset, run: r });
        } else {
          const mono: PlanRun = { ...r, font: "mono" };
          let k = 0;
          for (const ch of a.kind.latex) {
            const c = ch.codePointAt(0) ?? 0;
            const o = a.latexOffsets?.[k] ?? a.offset;
            out.push({ kind: c === 0x0a ? { k: "break" } : { k: "char", c }, offset: o, run: mono });
            k++;
          }
        }
      }
    }
    return out;
  }

  private add(kind: PlanParagraph["kind"], atoms: PlanAtom[], size: number, indent: number, column: number, gap: number,
    opts: { bold?: boolean; pad?: number; align?: string } = {}): void {
    const p: PlanParagraph = { kind, atoms, size, bold: opts.bold ?? false, indent, column,
      gapBefore: this.paragraphs.length === 0 ? 0 : gap, pad: opts.pad ?? 0, align: opts.align ?? this.box.align };
    if (this.pendingMarker) p.marker = this.pendingMarker;
    this.pendingMarker = undefined;
    this.paragraphs.push(p);
  }

  private walk(entries: MDEntry[], indent: number, firstGap: number, bulletDepth: number): void {
    const s = this.box.size;
    entries.forEach((e, k) => {
      const gap = k === 0 ? firstGap : e.blankBefore ? metrics.gap * s : 0;
      const b = e.block;
      switch (b.t) {
        case "paragraph":
          this.add("text", this.atoms(b.atoms, s, false), s, indent, indent, gap);
          break;
        case "heading": {
          const size = round3(s * (metrics.headingScale[Math.max(0, Math.min(5, b.level - 1))] ?? 1));
          this.add("text", this.atoms(b.atoms, size, true), size, indent, indent, gap, { bold: true });
          break;
        }
        case "code": {
          const r: PlanRun = { ...this.run(Style.code, s, false), font: "mono" };
          const atoms = b.atoms.map((m): PlanAtom => m.kind.k === "char" ? { kind: { k: "char", c: m.kind.c }, offset: m.offset, run: r }
            : { kind: { k: "break" }, offset: m.offset, run: r });
          this.add("code", atoms, s, indent + metrics.codeInset * s, indent, gap, { pad: metrics.codePad * s, align: "start" });
          break;
        }
        case "math": {
          const a = this.atoms([b.atom], s, false);
          const boxed = a.length === 1 && a[0]?.kind.k === "box";
          this.add(boxed ? "displayMath" : "text", a, s, indent, indent, gap, { align: "center" });
          break;
        }
        case "rule":
          this.add("rule", [], s, indent, indent, gap);
          break;
        case "quote": {
          const first = this.paragraphs.length;
          this.walk(b.entries, indent + metrics.quoteIndent * s, gap, bulletDepth);
          if (this.paragraphs.length > first) this.bars.push({ x: indent + metrics.quoteBarX * s, first, last: this.paragraphs.length - 1 });
          break;
        }
        case "list": {
          const list = b.list;
          list.items.forEach((item, n) => {
            const itemGap = n === 0 ? gap : item.blankBefore ? metrics.gap * s : 0;
            if (item.task !== undefined) this.pendingMarker = { k: "task", checked: item.task };
            else if (list.bullet !== undefined) this.pendingMarker = { k: "bullet", ring: bulletDepth % 2 === 1 };
            else {
              const value = list.start + n;
              this.pendingMarker = { k: "ordered", label: `${value}${String.fromCodePoint(list.delimiter ?? 0x2e)}` };
            }
            const inner = indent + metrics.listIndent * s;
            const before = this.paragraphs.length;
            this.walk(item.blocks, inner, itemGap, bulletDepth + (list.bullet !== undefined ? 1 : 0));
            if (this.paragraphs.length === before) this.add("text", [], s, inner, inner, itemGap);
          });
          break;
        }
      }
    });
  }
}
