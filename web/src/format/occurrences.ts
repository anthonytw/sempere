// Every occurrence of a phrase: the matching rules of the CLI's `sempere search`
// (Sources/SempereCLI/Search.swift, `RecognitionSearch`), which calls
// Foundation's `range(of:options: [.caseInsensitive, .diacriticInsensitive])`.
// Unlike the note search (`search.ts`, the app's `NoteSearch`), the term is one
// phrase (not words), and full-width forms are not folded.
//
// What Foundation does there (measured on Linux, where `swift-corelibs-foundation`
// runs CFString's search; `test/golden/occurrence-vectors.json` holds Swift's
// answers and CI regenerates it):
// - grapheme extenders (accents, Hebrew and Arabic points, Indic vowel signs,
//   variation selectors, ZWNJ) are ignored, inside the text and the term;
// - a precomposed letter whose canonical decomposition starts below U+0510
//   matches its base letter (é → e, ǖ → u; が stays が);
// - case is fully folded (ß matches ss, ﬁ matches fi, İ matches i), but a
//   match never ends or starts inside one character's folding (ß does not
//   match s);
// - BMP extenders that follow the last matched character belong to the match
//   when the searched range starts with a character below U+0510 (a quirk of
//   CFString's search, kept so the ranges and snippets are the CLI's).
// The viewer applies the same rules to code points with the browser's Unicode
// tables; Foundation's differ in corner cases (a term that starts with a mark,
// matches beginning inside a grapheme cluster), see docs/web-viewer.md.

const graphemeExtend = /^\p{Grapheme_Extend}$/u;

function isExtend(cp: number): boolean {
  // Foundation also ignores the emoji skin-tone modifiers.
  return (cp >= 0x1f3fb && cp <= 0x1f3ff) || graphemeExtend.test(String.fromCodePoint(cp));
}

const foldCache = new Map<number, number[]>();

/** The code points one code point compares as; empty for an ignored extender. */
export function foldCodePoint(cp: number): number[] {
  const cached = foldCache.get(cp);
  if (cached) return cached;
  let out: number[];
  if (cp < 0x80) {
    out = [cp >= 0x41 && cp <= 0x5a ? cp + 0x20 : cp];
  } else if (isExtend(cp)) {
    out = [];
  } else {
    let base = cp;
    const decomposed = String.fromCodePoint(cp).normalize("NFD");
    const first = decomposed.codePointAt(0) ?? cp;
    if (decomposed !== String.fromCodePoint(cp) && first < 0x0510) base = first;
    // Full case folding: lower, upper, lower maps every case variant (ẞ, ß, SS;
    // ς, σ, Σ; K and the Kelvin sign) to one spelling.
    const folded = String.fromCodePoint(base).toLowerCase().toUpperCase().toLowerCase();
    out = [...folded].map((c) => c.codePointAt(0) ?? 0);
  }
  if (foldCache.size < 65_536) foldCache.set(cp, out);
  return out;
}

/** A text prepared for repeated searches: code points, their UTF-16 offsets, and the folded form. */
export interface FoldedText {
  readonly text: string;
  /** UTF-16 offset of each code point, plus the length at the end. */
  readonly offsets: number[];
  readonly cps: number[];
  /** Folded code points as a string, for `indexOf`. */
  readonly folded: string;
  /** For each folded UTF-16 unit: the code point index it came from. */
  readonly origin: number[];
  /** For each code point: where its folding starts in `folded` (UTF-16). */
  readonly start: number[];
}

export function prepare(text: string): FoldedText {
  const offsets: number[] = [], cps: number[] = [], origin: number[] = [], start: number[] = [];
  let folded = "", at = 0;
  for (const ch of text) {
    const cp = ch.codePointAt(0) ?? 0;
    offsets.push(at);
    at += ch.length;
    start.push(folded.length);
    const f = String.fromCodePoint(...foldCodePoint(cp));
    for (let k = 0; k < f.length; k++) origin.push(cps.length);
    folded += f;
    cps.push(cp);
  }
  offsets.push(at);
  start.push(folded.length);
  return { text, offsets, cps, folded, origin, start };
}

/** The folded form of a text alone (`prepare(text).folded`), for a cheap first check of many texts. */
export function foldedText(text: string): string {
  let out = "";
  for (const ch of text) out += String.fromCodePoint(...foldCodePoint(ch.codePointAt(0) ?? 0));
  return out;
}

/** False when `folded` (from `foldedText`) cannot contain the term, so the full search can be skipped. */
export function mayContain(folded: string, term: FoldedTerm): boolean {
  return term.folded.length === 0 || folded.includes(term.folded);
}

/**
 * A search term: the extenders it starts with, which must be in the text as
 * they are (Foundation compares the first character of a match without
 * ignoring marks), and the folded rest.
 */
export interface FoldedTerm {
  readonly lead: number[];
  readonly folded: string;
}

export function foldTerm(term: string): FoldedTerm {
  const cps = [...term].map((c) => c.codePointAt(0) ?? 0);
  let n = 0;
  while (n < cps.length && isExtend(cps[n] ?? 0)) n++;
  let folded = "";
  for (const cp of cps.slice(n)) folded += String.fromCodePoint(...foldCodePoint(cp));
  return { lead: cps.slice(0, n), folded };
}

function leadAt(t: FoldedText, lead: number[], end: number): boolean {
  const s = end - lead.length;
  return s >= 0 && lead.every((cp, k) => t.cps[s + k] === cp);
}

/**
 * The first occurrence of the term at or after code point `from`, as
 * `[start, end)` code point indices of the text (Swift `range(of:options:range:)`).
 */
export function rangeOf(t: FoldedText, term: FoldedTerm, from = 0): [number, number] | undefined {
  const { lead, folded } = term;
  if (from >= t.cps.length || (folded.length === 0 && lead.length === 0)) return undefined;
  if (folded.length === 0) {
    // Only marks: they match as they are.
    for (let s = from; s + lead.length <= t.cps.length; s++) {
      if (leadAt(t, lead, s + lead.length)) return [s, absorbMarks(t, from, s + lead.length)];
    }
    return undefined;
  }
  let at = t.start[Math.min(t.cps.length, from + lead.length)] ?? t.folded.length;
  for (;;) {
    const i = t.folded.indexOf(folded, at);
    if (i < 0) return undefined;
    const first = t.origin[i] ?? 0;
    const endUnit = i + folded.length;
    const lastCp = t.origin[endUnit - 1] ?? 0;
    if (t.start[first] === i && first - lead.length >= from && (lead.length === 0 || leadAt(t, lead, first))
      && endsFolding(t, lastCp, endUnit)) {
      return [first - lead.length, absorbMarks(t, from, lastCp + 1)];
    }
    at = i + 1;
  }
}

/**
 * True when a match ending at folded unit `endUnit`, inside code point `cp`'s
 * folding, takes the whole folding: it ends where the folding does, or what is
 * left of it is marks after a base below U+0510 (İ folds to i + U+0307).
 */
function endsFolding(t: FoldedText, cp: number, endUnit: number): boolean {
  const foldEnd = t.start[cp + 1] ?? t.folded.length;
  if (endUnit === foldEnd) return true;
  if ((t.folded.codePointAt(t.start[cp] ?? 0) ?? 0x10ffff) >= 0x0510) return false;
  return [...t.folded.slice(endUnit, foldEnd)].every((c) => isExtend(c.codePointAt(0) ?? 0));
}

/**
 * Where a match ending before code point `end` really ends: CFString takes the
 * BMP marks that follow into the match, but only when the first UTF-16 unit of
 * the searched range (from code point `from`) is below U+0510 (it looks there,
 * not at the matched letter).
 */
function absorbMarks(t: FoldedText, from: number, end: number): number {
  if (t.text.charCodeAt(t.offsets[from] ?? 0) >= 0x0510) return end;
  let e = end;
  while (e < t.cps.length && (t.cps[e] ?? 0) < 0x10000 && isExtend(t.cps[e] ?? 0)) e++;
  return e;
}

/** Every non-overlapping occurrence (`RecognitionSearch.ranges`), as code point ranges. */
export function occurrences(t: FoldedText, term: FoldedTerm): [number, number][] {
  const out: [number, number][] = [];
  let from = 0;
  while (from < t.cps.length) {
    const r = rangeOf(t, term, from);
    if (!r) break;
    out.push(r);
    from = r[1] > r[0] ? r[1] : r[0] + 1;
  }
  return out;
}

/** True when `term` occurs in `text` (with `search`'s rules). */
export function containsPhrase(text: string, term: string): boolean {
  return rangeOf(prepare(text), foldTerm(term)) !== undefined;
}

// MARK: - Snippets

const segmenter = typeof Intl !== "undefined" && "Segmenter" in Intl
  ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : undefined;

/** UTF-16 offsets where grapheme clusters start, plus the length. */
function clusterStarts(text: string): number[] {
  if (!segmenter) {
    const out: number[] = [];
    let at = 0;
    for (const ch of text) {
      out.push(at);
      at += ch.length;
    }
    out.push(text.length);
    return out;
  }
  const out = [...segmenter.segment(text)].map((s) => s.index);
  out.push(text.length);
  return out;
}

/** Index in `starts` of the cluster holding UTF-16 offset `u` (Swift rounds an index down to a Character). */
function clusterAt(starts: number[], u: number): number {
  let lo = 0, hi = starts.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if ((starts[mid] ?? 0) <= u) lo = mid;
    else hi = mid - 1;
  }
  return lo;
}

/** Swift `Character.isNewline`. */
const newlines = new Set(["\r\n", ...[0x0a, 0x0b, 0x0c, 0x0d, 0x85, 0x2028, 0x2029].map((c) => String.fromCharCode(c))]);

function isNewlineCluster(c: string): boolean {
  return newlines.has(c);
}

/** `CharacterSet.whitespaces`: Zs and tab. */
const whitespace = /^[\t\p{Zs}]$/u;

/**
 * A one-line excerpt around a match (`RecognitionSearch.snippet`): `context`
 * characters on each side, lines joined by spaces, `…` where it was cut.
 */
export function snippet(t: FoldedText, range: [number, number], context = 30): string {
  const text = t.text;
  const starts = clusterStarts(text);
  const last = starts.length - 1;
  const lo = clusterAt(starts, t.offsets[range[0]] ?? 0);
  const hiRaw = t.offsets[range[1]] ?? text.length;
  // An end inside a cluster rounds down too, as Swift's index arithmetic does.
  const hi = hiRaw >= text.length ? last : clusterAt(starts, hiRaw);
  const a = Math.max(0, lo - context), b = Math.min(last, hi + context);
  const clusters: string[] = [];
  for (let i = a; i < b; i++) clusters.push(text.slice(starts[i], starts[i + 1]));
  const lines: string[][] = [[]];
  for (const c of clusters) {
    if (isNewlineCluster(c)) lines.push([]);
    else lines[lines.length - 1]?.push(c);
  }
  let body = [...lines.filter((l) => l.length > 0).map((l) => l.join(""))].join(" ");
  const scalars = [...body];
  let s = 0, e = scalars.length;
  while (s < e && whitespace.test(scalars[s] ?? "")) s++;
  while (e > s && whitespace.test(scalars[e - 1] ?? "")) e--;
  body = scalars.slice(s, e).join("");
  return (a > 0 ? "…" : "") + body + (b < last ? "…" : "");
}

/** Swift `String <`: code points of the canonical (NFC) forms. */
export function swiftCompare(a: string, b: string): number {
  const x = [...a.normalize("NFC")], y = [...b.normalize("NFC")];
  for (let i = 0; i < Math.min(x.length, y.length); i++) {
    const d = (x[i]?.codePointAt(0) ?? 0) - (y[i]?.codePointAt(0) ?? 0);
    if (d !== 0) return d;
  }
  return x.length - y.length;
}

/** `CharacterSet.whitespacesAndNewlines`: Z*, tab, line breaks and NEL. */
const whitespaceOrNewline = /^[\p{Z}\t\n\v\f\r\u0085]$/u;

/** The term as `sempere search` uses it: trimmed of white space and line breaks. */
export function trimTerm(term: string): string {
  const cps = [...term];
  let s = 0, e = cps.length;
  while (s < e && whitespaceOrNewline.test(cps[s] ?? "")) s++;
  while (e > s && whitespaceOrNewline.test(cps[e - 1] ?? "")) e--;
  return cps.slice(s, e).join("");
}
