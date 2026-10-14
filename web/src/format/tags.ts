// Tag normalisation and keys (format.md §5.4.1), as `NoteOps` in
// Sources/Sempere/Edit.swift.

const whitespace = /^\p{White_Space}/u;
const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/**
 * The tag as stored: trimmed, inner runs of whitespace collapsed to one space.
 * Like Swift's `split(whereSeparator: \.isWhitespace)` this splits on whole
 * characters (grapheme clusters): a space carrying a combining mark is
 * whitespace, and the mark goes with it.
 */
export function normalizedTag(tag: string): string {
  const words: string[] = [];
  let cur = "";
  for (const { segment } of graphemes.segment(tag)) {
    if (whitespace.test(segment)) {
      if (cur) words.push(cur);
      cur = "";
    } else {
      cur += segment;
    }
  }
  if (cur) words.push(cur);
  return words.join(" ");
}

/**
 * Unicode default lowercase without context, as Swift's `lowercased()`:
 * JavaScript maps a word-final Σ to ς, Swift always to σ.
 */
export function lowercased(s: string): string {
  return s.replaceAll("Σ", "σ").toLowerCase();
}

/** The case-insensitive key tags are matched by: "Math" and "math" are one tag. */
export function tagKey(tag: string): string {
  return lowercased(normalizedTag(tag));
}
