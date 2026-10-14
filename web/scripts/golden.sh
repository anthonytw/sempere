#!/usr/bin/env bash
# Regenerates web/test/golden from the Swift CLI: for every note of every
# fixture vault, `sempere export --format json` and `--format svg`, the
# vault's published summaries (`sempere vault summaries --plaintext`), and
# `sempere search TERM --transcripts --json` for the terms below. The web
# tests compare the TypeScript reducer and renderer with these files; CI runs
# this script and fails on any difference (docs/web-viewer.md "Tests").
#
# Usage: web/scripts/golden.sh [OUT_DIR] (default web/test/golden)
#        SEMPERE=path/to/sempere to use a built CLI (default: swift build).
set -euo pipefail
web="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$web/.." && pwd)"
out="${1:-$web/test/golden}"
if [ -z "${SEMPERE:-}" ]; then
  (cd "$repo" && swift build --product sempere >&2)
  SEMPERE="$repo/.build/debug/sempere"
fi
key="$repo/Tests/SempereTests/Fixtures/sample.key"

export_vault() {   # name vault-dir
  local name="$1" vault="$2" dest="$out/$1" tmp
  rm -rf "$dest"
  mkdir -p "$dest"
  for dir in "$vault"/notes/*/; do
    id="$(basename "$dir")"
    "$SEMPERE" export "$id" --vault "$vault" --identity "$key" --format json --out "$dest/$id.json" -q >/dev/null
    tmp="$(mktemp -d)"
    "$SEMPERE" export "$id" --vault "$vault" --identity "$key" --format svg --pdf-renderer none --out "$tmp" -q >/dev/null
    mkdir -p "$dest/$id"
    # <name>-p001.svg -> p001.svg (the name depends on the title)
    for f in "$tmp"/*.svg; do mv "$f" "$dest/$id/${f##*-}"; done
    rm -rf "$tmp"
  done
  # The published summaries' content (format.md §12), as JSON (the sealed file has a random nonce).
  "$SEMPERE" vault summaries --vault "$vault" --identity "$key" --plaintext --out "$out/$name.summaries.json" -q >/dev/null
}

export_vault sample "$repo/Tests/SempereTests/Fixtures/sample.sempere"
# A vault of a later format version (format.md §7): what this version shows of it.
export_vault newer "$repo/Tests/SempereTests/Fixtures/newer.sempere"
if [ -d "$web/test/fixtures/render.sempere" ]; then
  export_vault render "$web/test/fixtures/render.sempere"
fi

# Every occurrence of each term (`sempere search --transcripts`), the rules the
# viewer's transcript search follows (src/format/phrasesearch.ts). One file per
# vault and term, named by the term's UTF-8 bytes in hex. Exit status 1 means some
# transcript could not be read (search.sempere has two on purpose), and is kept.
search_terms=("café" "CAFE" "  cafe  " "ss" "STRASSE" "straße" "fi" "e" "the café" "resume" "über" "lait the" "frac" "nothing at all")
search_vault() {   # name vault-dir
  local dest="$out/search/$1" term hex status
  rm -rf "$dest"
  mkdir -p "$dest"
  for term in "${search_terms[@]}"; do
    hex="$(printf '%s' "$term" | od -An -tx1 | tr -d ' \n')"
    status=0
    "$SEMPERE" search "$term" --transcripts --json --vault "$2" --identity "$key" >"$dest/$hex.json" 2>/dev/null || status=$?
    if [ "$status" -gt 1 ]; then echo "sempere search failed ($status) on $1 for '$term'" >&2; exit 1; fi
    printf '{"term": "%s", "exit": %d}\n' "$term" "$status" >"$dest/$hex.meta.json"
  done
}
search_vault sample "$repo/Tests/SempereTests/Fixtures/sample.sempere"
search_vault render "$web/test/fixtures/render.sempere"
search_vault search "$web/test/fixtures/search.sempere"
# Foundation's matching itself (case, accents, folding) on test/fixtures/occurrence-cases.json.
bin="$(mktemp -d)"
swiftc -O "$web/scripts/occurrence-vectors.swift" -o "$bin/occurrence-vectors" >&2
"$bin/occurrence-vectors" <"$web/test/fixtures/occurrence-cases.json" >"$out/occurrence-vectors.json"
rm -rf "$bin"
echo "golden files in $out" >&2
