#!/usr/bin/env bash
# Runs every browser smoke script (docs/web-viewer.md), the way CI's `web-smoke` job does.
# Needs: `npm ci && npm run build` done in web/, Playwright's Chromium (WebKit too for BROWSER=webkit), and the
# sempere CLI (SEMPERE=path, default .build/debug/sempere) to give a copy of the sample
# vault the sealed summaries and the index that smoke.mjs and smoke-cache.mjs need.
#   web/scripts/smoke-all.sh            (from anywhere; fails on the first broken script)
#   BROWSER=webkit web/scripts/smoke-all.sh   the same in Playwright's WebKit, the desktop Safari
#                                       approximation (docs/web-viewer.md "Stress tests"): the scripts that
#                                       need Chromium's DevTools protocol (touch pan, passkey, passphrase
#                                       keys) are skipped
#   STRESS_HEAVY=1 web/scripts/smoke-all.sh   the large-note stress vault and its goldens from the CLI
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(cd .. && pwd)"
sempere="${SEMPERE:-$root/.build/debug/sempere}"
fixtures="$root/Tests/SempereTests/Fixtures"
key="$fixtures/sample.key"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
[ -x "$sempere" ] || { echo "no sempere CLI at $sempere (swift build --product sempere)" >&2; exit 1; }
[ -d dist ] || { echo "no dist/ (npm run build)" >&2; exit 1; }

# A copy of the sample vault with what a synced vault has: sealed summaries and the index.
# `vault summaries` and `vault index` write into the vault, so never into the committed fixture.
# This machine never joined the fixture vault: its root (the kit's, design §4.3) confirms the copy, with
# trust records kept in the scratch folder.
cp -R "$fixtures/sample.sempere" "$work/sample.sempere"
export XDG_STATE_HOME="$work/state"
sample_root="$("$sempere" vault info --vault "$work/sample.sempere" --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).root))')"
SEMPERE_IDENTITY="$key" "$sempere" vault summaries --vault "$work/sample.sempere" --root "$sample_root"
SEMPERE_IDENTITY="$key" "$sempere" vault index --vault "$work/sample.sempere" --root "$sample_root"
test -f "$work/sample.sempere/sempere-summaries.sealed" || { echo "no summaries written" >&2; exit 1; }
test -f "$work/sample.sempere/sempere-index.json" || { echo "no index written" >&2; exit 1; }
shots="$work/shots"; mkdir -p "$shots"

run() { echo "::group::$*"; node "scripts/$@"; echo "::endgroup::"; }
# Scripts that drive Chromium's DevTools protocol (CDP): not in WebKit.
run_chromium() { if [ "${BROWSER:-chromium}" = webkit ]; then echo "skipped in WebKit (CDP): $1"; else run "$@"; fi; }

# The stress vault (scripts/make-stress-fixture.ts) and the CLI's SVG export of its notes, which the
# pixel diff compares the viewer with. Fast sizes by default; STRESS_HEAVY=1 for the large ones.
stress="$work/stress.sempere"
if [ "${STRESS_HEAVY:-0}" = 1 ]; then sizes=(--pages 400 --strokes 20000 --dense 12000 --deep 300); else sizes=(--pages 110 --strokes 2500 --dense 2000 --deep 100); fi
node scripts/make-stress-fixture.ts "$stress" "${sizes[@]}"
stress_golden="$work/stress-golden"; mkdir -p "$stress_golden"
for dir in "$stress"/notes/*/; do
  id="$(basename "$dir")"
  SEMPERE_IDENTITY="$key" "$sempere" export "$id" --vault "$stress" --format json --out "$stress_golden/$id.json" -q >/dev/null
  tmp="$(mktemp -d)"
  SEMPERE_IDENTITY="$key" "$sempere" export "$id" --vault "$stress" --format svg --pdf-renderer none --out "$tmp" -q >/dev/null
  mkdir -p "$stress_golden/$id"
  for f in "$tmp"/*.svg; do mv "$f" "$stress_golden/$id/${f##*-}"; done
  rm -rf "$tmp"
done

run smoke.mjs "$work/sample.sempere" "$key" "$shots"
run smoke-cache.mjs "$work/sample.sempere" "$key"
run_chromium smoke-pan.mjs "$fixtures/sample.sempere" "$key"
run smoke-attachments.mjs test/fixtures/render.sempere "$key" "$shots"
run smoke-video.mjs test/fixtures/render.sempere "$key" "$shots"
run smoke-release.mjs test/fixtures/render.sempere "$key"
run_chromium smoke-passkey.mjs "$fixtures/sample.sempere" "$key"
run smoke-language.mjs test/fixtures/render.sempere "$key"
run_chromium smoke-search-keys.mjs
# Large notes: open time, frame pacing, heap and DOM, scroll anchoring (heavy: STRESS_HEAVY=1).
run smoke-stress.mjs "$stress" "$key"
# The viewer's pages against the CLI's SVG export, rasterized in the browser.
run smoke-pixels.mjs test/fixtures/render.sempere "$key" test/golden/render
run smoke-pixels.mjs "$fixtures/sample.sempere" "$key" test/golden/sample
# The heavy dense note's own export is a 63 MB SVG, more than a browser decodes as an image: not compared there.
if [ "${STRESS_HEAVY:-0}" = 1 ]; then pixel_notes='pageless [0-9]+$|deep'; else pixel_notes='pageless|deep'; fi
run smoke-pixels.mjs "$stress" "$key" "$stress_golden" "$pixel_notes"
echo "all browser smoke scripts passed"
