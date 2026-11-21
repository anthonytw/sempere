#!/usr/bin/env bash
# Rebuilds the share viewer template (docs/web-viewer.md "Share files"): builds web/ with `npm run build:share`
# and writes Sources/SempereShareViewer/ShareViewerTemplate.swift, the page the CLI and the app embed.
#
#   scripts/build-share-template.sh            rebuild the committed file
#   scripts/build-share-template.sh --check    rebuild into a scratch file and fail if it differs from the committed one
#                                              (the `web` CI job; needs `npm ci` done in web/)
set -euo pipefail
cd "$(dirname "$0")/.."
target="$PWD/Sources/SempereShareViewer/ShareViewerTemplate.swift"
mode=${1:-}
case "$mode" in
  ""|--check) ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac
out=$target
if [ "$mode" = "--check" ]; then
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/share-template.XXXXXX")
  trap 'rm -rf "$scratch"' EXIT
  out="$scratch/ShareViewerTemplate.swift"
fi
(cd web \
  && npm run --silent build:share >/dev/null \
  && node scripts/build-share.ts dist-share/share-viewer.html --swift "$out" | tail -1)
if [ "$mode" = "--check" ]; then
  if ! diff -q "$out" "$target" >/dev/null; then
    echo "error: ${target#$PWD/} is out of date; run scripts/build-share-template.sh and commit the result" >&2
    exit 1
  fi
  echo "share template is up to date"
fi
