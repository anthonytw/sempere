// Search over titles, notebooks, tags and recognised text, and notebook paths:
// ports of Sources/Sempere/NoteSearch.swift and Notebooks.swift.

/** The display segments of a notebook name (format.md §5.4); empty for none. */
export function notebookComponents(name: string | undefined): string[] {
  if (name === undefined) return [];
  return name.split("/").map((s) => s.replace(/^[\p{White_Space}]+|[\p{White_Space}]+$/gu, "")).filter((s) => s.length > 0);
}

export function canonicalNotebook(name: string | undefined): string | undefined {
  const parts = notebookComponents(name);
  return parts.length === 0 ? undefined : parts.join("/");
}

/** True when `name` is the notebook `path` or below it (whole segments). */
export function isWithinNotebook(name: string | undefined, path: string): boolean {
  const parts = notebookComponents(name), prefix = notebookComponents(path);
  return prefix.length > 0 && parts.length >= prefix.length && prefix.every((p, i) => parts[i] === p);
}

export interface NotebookNode {
  name: string;
  path: string;
  children: NotebookNode[];
}

const maxNotebookDepth = 64;
const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

/** The forest of notebooks named by `names`; intermediate levels exist implicitly. */
export function notebookTree(names: (string | undefined)[]): NotebookNode[] {
  const paths = names.map((n) => notebookComponents(n).slice(0, maxNotebookDepth)).filter((p) => p.length > 0);
  const build = (below: string[][], depth: number, prefix: string[]): NotebookNode[] => {
    const here = below.filter((p) => p.length > depth);
    const segs = [...new Set(here.map((p) => p[depth] ?? ""))]
      .sort((a, b) => collator.compare(a, b) || (a < b ? -1 : a > b ? 1 : 0));
    return segs.map((name) => {
      const path = [...prefix, name];
      return { name, path: path.join("/"), children: build(here.filter((p) => p[depth] === name), depth + 1, path) };
    });
  };
  return build(paths, 0, []);
}

// MARK: - Search

/**
 * Folding for case-, diacritic- and width-insensitive matching (Foundation's
 * `.caseInsensitive, .diacriticInsensitive, .widthInsensitive`): each code
 * point is NFKD-decomposed, combining marks dropped, then lowercased.
 * Returns the folded text and, per folded code unit, the index of the
 * original code unit it came from (for highlighting).
 */
export function fold(s: string): { text: string; map: number[] } {
  let text = "";
  const map: number[] = [];
  let i = 0;
  for (const ch of s) {
    const f = ch.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();
    text += f;
    for (let k = 0; k < f.length; k++) map.push(i);
    i += ch.length;
  }
  map.push(i);
  return { text, map };
}

function contains(hay: string, needle: string): boolean {
  return fold(hay).text.includes(fold(needle).text);
}

function equal(a: string, b: string): boolean {
  return fold(a).text === fold(b).text;
}

/** A part of a page's text from one source (Swift `PageText.Span`): `[start, end)` in UTF-16 code units. */
export interface TextSpan {
  start: number;
  end: number;
  /** An equation's LaTeX source: searchable, never quoted in a snippet. */
  isMath: boolean;
}

export interface PageTextEntry {
  number: number;
  text: string;
  /** The parts `text` is made of; absent or empty: one prose part (published summaries carry none). */
  spans?: TextSpan[];
}

export interface SearchableNote {
  id: string;
  title: string;
  notebook?: string;
  tags: string[];
  modified?: number;
  pageTexts: PageTextEntry[];
}

export type SearchField = "title" | "tag" | "notebook" | "text";

export interface Snippet {
  text: string;
  /** `[start, end)` code-unit ranges of matches in `text`. */
  matches: [number, number][];
  /** The match is only inside an equation: `text` is `equationMarker` (the interface shows its own). */
  isEquation?: boolean;
}

/** What a snippet says when the match is inside an equation (Swift `NoteSearch.equationMarker`). */
export const equationMarker = "[equation]";

export interface SearchHit {
  id: string;
  fields: SearchField[];
  page?: { number: number; text: string };
  snippet?: Snippet;
  matchedPages: number;
  score: number;
}

export const maxWords = 12;
const snippetBefore = 50, snippetAfter = 90;

interface Word {
  text: string;
  tagOnly: boolean;
}

function words(query: string): Word[] {
  const seen = new Set<string>();
  const out: Word[] = [];
  for (const raw of query.split(/\p{White_Space}+/u)) {
    let w = raw;
    const tagOnly = w.startsWith("#");
    if (tagOnly) w = w.slice(1);
    if (w.length === 0) continue;
    const k = `${tagOnly ? "#" : " "}${w}`;
    if (seen.has(k)) continue;
    seen.add(k);
    out.push({ text: w, tagOnly });
    if (out.length === maxWords) break;
  }
  return out;
}

const fieldOrder: SearchField[] = ["title", "tag", "notebook", "text"];

function hit(ws: Word[], note: SearchableNote): SearchHit | undefined {
  const fields = new Set<SearchField>();
  let score = 0;
  const pageWords = new Map<number, Set<number>>();
  const nb = canonicalNotebook(note.notebook);
  for (const [wi, word] of ws.entries()) {
    let best = 0;
    if (!word.tagOnly) {
      if (contains(note.title, word.text)) {
        fields.add("title");
        best = Math.max(best, equal(note.title, word.text) ? 150 : 100);
      }
      if (nb !== undefined && contains(nb, word.text)) {
        fields.add("notebook");
        best = Math.max(best, notebookComponents(nb).some((c) => equal(c, word.text)) ? 50 : 30);
      }
    }
    for (const tag of note.tags) {
      if (!contains(tag, word.text)) continue;
      fields.add("tag");
      best = Math.max(best, equal(tag, word.text) ? 80 : 40);
    }
    if (!word.tagOnly) {
      note.pageTexts.forEach((p, pi) => {
        if (!contains(p.text, word.text)) return;
        fields.add("text");
        const s = pageWords.get(pi) ?? new Set<number>();
        s.add(wi);
        pageWords.set(pi, s);
        best = Math.max(best, 10);
      });
    }
    if (best === 0) return undefined;
    score += best;
  }
  const out: SearchHit = { id: note.id, fields: fieldOrder.filter((f) => fields.has(f)), matchedPages: pageWords.size, score };
  let bestIndex: number | undefined;
  for (const [pi, s] of pageWords) {
    const cur = bestIndex === undefined ? undefined : pageWords.get(bestIndex);
    if (bestIndex === undefined || !cur || s.size > cur.size || (s.size === cur.size && pi < bestIndex)) bestIndex = pi;
  }
  if (bestIndex !== undefined) {
    const page = note.pageTexts[bestIndex];
    if (page) {
      out.page = page;
      const sn = pageSnippet(page, ws.map((w) => w.text));
      if (sn) out.snippet = sn;
      out.score += 5 * (pageWords.get(bestIndex)?.size ?? 0) + Math.min(pageWords.size, 5);
    }
  }
  return out;
}

/** Finds `needle` in `hay` (folded), returning original code-unit ranges. */
function findAll(hay: string, needle: string): [number, number][] {
  const f = fold(hay), n = fold(needle).text;
  if (n.length === 0) return [];
  const out: [number, number][] = [];
  let from = 0;
  for (;;) {
    const i = f.text.indexOf(n, from);
    if (i < 0) break;
    out.push([f.map[i] ?? 0, f.map[i + n.length] ?? hay.length]);
    from = i + n.length;
  }
  return out;
}

function firstMatch(text: string, ws: string[]): [number, number] | undefined {
  let first: [number, number] | undefined;
  for (const w of ws) {
    const r = findAll(text, w)[0];
    if (r && (!first || r[0] < first[0])) first = r;
  }
  return first;
}

// Swift's Character.isWhitespace, as far as a line-flattened text needs it.
const isSpace = (c: string | undefined) => c !== undefined && /^[\s\u0085]$/u.test(c);

/** A line-flattened excerpt of `text` (one part) around its first match of any of `ws`, cut at word
 * boundaries (Swift `NoteSearch.excerpt`). */
function excerpt(text: string, ws: string[]): Snippet | undefined {
  // Swift's Character.isNewline: LF, VT, FF, CR, NEL, LS, PS.
  const flat = text.replace(/[\n\r\u2028\u2029\u0085]|\v|\f/g, " ");
  const first = firstMatch(flat, ws);
  if (!first) return undefined;
  const chars = Array.from(flat);
  // Offsets in code points, as Swift's String indices count characters.
  const cpIndex = (unit: number) => Array.from(flat.slice(0, unit)).length;
  const start = cpIndex(first[0]), end = cpIndex(first[1]);
  let lo = Math.max(start - snippetBefore, 0);
  let hi = Math.min(end + snippetAfter, chars.length);
  // A cut inside a word moves to the word's edge nearer the match (never past the match).
  if (lo > 0) while (lo < start && !isSpace(chars[lo]) && !isSpace(chars[lo - 1])) lo++;
  if (hi < chars.length) while (hi > end && !isSpace(chars[hi - 1]) && !isSpace(chars[hi])) hi--;
  const body = chars.slice(lo, hi).join("").replace(/^[\t\p{Zs}]+|[\t\p{Zs}]+$/gu, "");
  const shown = (lo > 0 ? "…" : "") + body + (hi < chars.length ? "…" : "");
  const matches = ws.flatMap((w) => findAll(shown, w)).sort((a, b) => a[0] - b[0]);
  return { text: shown, matches };
}

/** An excerpt of `page` around the first match of any of `ws` in its prose, never crossing into a
 * neighbouring part; `equationMarker` when the words are only in equations (Swift `NoteSearch.snippet`). */
export function pageSnippet(page: PageTextEntry, ws: string[]): Snippet | undefined {
  const spans = page.spans && page.spans.length > 0 ? page.spans : [{ start: 0, end: page.text.length, isMath: false }];
  let inEquation = false;
  for (const span of spans) {
    if (span.start < 0 || span.end < span.start || span.end > page.text.length) continue;
    const part = page.text.slice(span.start, span.end);
    if (part.length === 0) continue;
    const hit = firstMatch(part, ws);
    if (span.isMath) {
      if (hit) inEquation = true;
      continue;
    }
    if (hit) return excerpt(part, ws);
  }
  return inEquation ? { text: equationMarker, matches: [], isEquation: true } : undefined;
}

/** `pageSnippet` for plain text (one prose part). */
export function snippet(text: string, ws: string[]): Snippet | undefined {
  return pageSnippet({ number: 1, text }, ws);
}

/** Notes matching every word of `query`, best first (score, newest, title). */
export function search(query: string, notes: SearchableNote[]): SearchHit[] {
  const ws = words(query);
  if (ws.length === 0) return [];
  const byId = new Map(notes.map((n) => [n.id, n]));
  const hits = notes.map((n) => hit(ws, n)).filter((h): h is SearchHit => h !== undefined);
  return hits.sort((a, b) => {
    if (a.score !== b.score) return b.score - a.score;
    const ma = byId.get(a.id)?.modified ?? -Infinity, mb = byId.get(b.id)?.modified ?? -Infinity;
    if (ma !== mb) return mb - ma;
    const ta = (byId.get(a.id)?.title ?? "").toLowerCase(), tb = (byId.get(b.id)?.title ?? "").toLowerCase();
    return ta < tb ? -1 : ta > tb ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
}
