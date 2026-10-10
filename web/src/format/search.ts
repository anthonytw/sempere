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
  interface Trie { children: Map<string, Trie> }
  const root: Trie = { children: new Map() };
  for (const name of names) {
    let at = root;
    for (const seg of notebookComponents(name).slice(0, maxNotebookDepth)) {
      let next = at.children.get(seg);
      if (!next) {
        next = { children: new Map() };
        at.children.set(seg, next);
      }
      at = next;
    }
  }
  const build = (t: Trie, prefix: string): NotebookNode[] =>
    [...t.children.keys()].sort((a, b) => collator.compare(a, b) || (a < b ? -1 : a > b ? 1 : 0)).map((name) => {
      const path = prefix === "" ? name : `${prefix}/${name}`;
      return { name, path, children: build(t.children.get(name) ?? { children: new Map() }, path) };
    });
  return build(root, "");
}

/**
 * How many of `names` are within each notebook of `notebookTree(names)`, by path: what
 * `isWithinNotebook` counts node by node, in one pass.
 */
export function notebookCounts(names: (string | undefined)[]): Map<string, number> {
  const counts = new Map<string, number>();
  for (const name of names) {
    let path = "";
    for (const seg of notebookComponents(name).slice(0, maxNotebookDepth)) {
      path = path === "" ? seg : `${path}/${seg}`;
      counts.set(path, (counts.get(path) ?? 0) + 1);
    }
  }
  return counts;
}

// MARK: - Search

/**
 * Folding for case-, diacritic- and width-insensitive matching (Foundation's
 * `.caseInsensitive, .diacriticInsensitive, .widthInsensitive`): each code
 * point is NFKD-decomposed, combining marks dropped, then lowercased.
 * Returns the folded text and, per folded code unit, the index of the
 * original code unit it came from (for highlighting). An ASCII code point is
 * its own decomposition, so it is only lowercased.
 */
export function fold(s: string): { text: string; map: number[] } {
  let text = "";
  const map: number[] = [];
  let i = 0;
  for (const ch of s) {
    const f = ch.length === 1 && ch.charCodeAt(0) < 0x80 ? ch.toLowerCase() : ch.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();
    text += f;
    for (let k = 0; k < f.length; k++) map.push(i);
    i += ch.length;
  }
  map.push(i);
  return { text, map };
}

const asciiOnly = /^[^\u0080-\u{10ffff}]*$/u;

/**
 * `fold(s).text` without the map: the same per-code-point folding, with ASCII text (whose
 * decomposition is itself and whose lowercasing never depends on context) lowercased in one call.
 */
export function foldText(s: string): string {
  if (asciiOnly.test(s)) return s.toLowerCase();
  let text = "";
  for (const ch of s) {
    text += ch.length === 1 && ch.charCodeAt(0) < 0x80 ? ch.toLowerCase() : ch.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();
  }
  return text;
}

/**
 * The folded form of a string a note holds, made once and kept with the object holding it (a page
 * entry or the note); `source` is the string it was made from, so a changed field is folded again.
 */
interface Folded {
  source: string;
  text: string;
}

function cachedFold(cache: WeakMap<object, Folded>, owner: object, s: string): string {
  const c = cache.get(owner);
  if (c && c.source === s) return c.text;
  const text = foldText(s);
  cache.set(owner, { source: s, text });
  return text;
}

const foldedPages = new WeakMap<object, Folded>();
const foldedTitles = new WeakMap<object, Folded>();

/** A note's canonical notebook with its folded form and its folded components. */
interface FoldedNotebook {
  source: string | undefined;
  canonical: string | undefined;
  text: string;
  components: string[];
}
const foldedNotebooks = new WeakMap<object, FoldedNotebook>();

function notebookOf(note: SearchableNote): FoldedNotebook {
  const c = foldedNotebooks.get(note);
  if (c && c.source === note.notebook) return c;
  const canonical = canonicalNotebook(note.notebook);
  const out: FoldedNotebook = canonical === undefined
    ? { source: note.notebook, canonical, text: "", components: [] }
    : { source: note.notebook, canonical, text: foldText(canonical), components: notebookComponents(canonical).map(foldText) };
  foldedNotebooks.set(note, out);
  return out;
}

/** Folded tags, kept per tags array (a note's tags are replaced, never edited in place). */
const foldedTags = new WeakMap<object, { source: string[]; texts: string[] }>();

function tagsOf(note: SearchableNote): string[] {
  const c = foldedTags.get(note);
  if (c && c.source.length === note.tags.length && c.source.every((t, i) => t === note.tags[i])) return c.texts;
  const texts = note.tags.map(foldText);
  foldedTags.set(note, { source: [...note.tags], texts });
  return texts;
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
  /** `text` folded, made once per query. */
  folded: string;
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
    out.push({ text: w, folded: foldText(w), tagOnly });
    if (out.length === maxWords) break;
  }
  return out;
}

const fieldOrder: SearchField[] = ["title", "tag", "notebook", "text"];

function hit(ws: Word[], note: SearchableNote): SearchHit | undefined {
  const fields = new Set<SearchField>();
  let score = 0;
  const pageWords = new Map<number, Set<number>>();
  const title = cachedFold(foldedTitles, note, note.title);
  const nb = notebookOf(note);
  const tags = tagsOf(note);
  const pages = note.pageTexts.map((p) => cachedFold(foldedPages, p, p.text));
  for (const [wi, word] of ws.entries()) {
    const w = word.folded;
    let best = 0;
    if (!word.tagOnly) {
      if (title.includes(w)) {
        fields.add("title");
        best = Math.max(best, title === w ? 150 : 100);
      }
      if (nb.canonical !== undefined && nb.text.includes(w)) {
        fields.add("notebook");
        best = Math.max(best, nb.components.some((c) => c === w) ? 50 : 30);
      }
    }
    for (const tag of tags) {
      if (!tag.includes(w)) continue;
      fields.add("tag");
      best = Math.max(best, tag === w ? 80 : 40);
    }
    if (!word.tagOnly) {
      pages.forEach((p, pi) => {
        if (!p.includes(w)) return;
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
  const f = fold(hay), n = foldText(needle);
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
  let f: { text: string; map: number[] } | undefined;
  let first: [number, number] | undefined;
  for (const w of ws) {
    const n = foldText(w);
    if (n.length === 0) continue;
    f ??= fold(text);
    const i = f.text.indexOf(n);
    if (i < 0) continue;
    const r: [number, number] = [f.map[i] ?? 0, f.map[i + n.length] ?? text.length];
    if (!first || r[0] < first[0]) first = r;
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

/**
 * True when every note matching `next` also matches `previous`: each word of `previous` is
 * inside (folded) a word of `next` that searches no more fields (a `#word` searches tags only).
 * A search for `next` may then look only at `previous`'s hits, as the box does while typing.
 */
export function refinesQuery(previous: string, next: string): boolean {
  const old = words(previous), now = words(next);
  if (old.length === 0 || now.length === 0) return false;
  return old.every((w) => now.some((n) => (n.tagOnly || !w.tagOnly) && n.folded.includes(w.folded)));
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
