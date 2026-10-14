#!/usr/bin/env bash
# Runs every browser smoke script (docs/web-viewer.md), the way CI's `web-smoke` job does.
# Needs: `npm ci && npm run build` done in web/, Playwright's Chromium, and the
# sempere CLI (SEMPERE=path, default .build/debug/sempere) to give a copy of the sample
# vault the sealed summaries and the index that smoke.mjs and smoke-cache.mjs need.
#   web/scripts/smoke-all.sh            (from anywhere; fails on the first broken script)
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
cp -R "$fixtures/sample.sempere" "$work/sample.sempere"
SEMPERE_IDENTITY="$key" "$sempere" vault summaries --vault "$work/sample.sempere"
SEMPERE_IDENTITY="$key" "$sempere" vault index --vault "$work/sample.sempere"
test -f "$work/sample.sempere/sempere-summaries.sealed" || { echo "no summaries written" >&2; exit 1; }
test -f "$work/sample.sempere/sempere-index.json" || { echo "no index written" >&2; exit 1; }
shots="$work/shots"; mkdir -p "$shots"

run() { echo "::group::$*"; node "scripts/$@"; echo "::endgroup::"; }
run smoke.mjs "$work/sample.sempere" "$key" "$shots"
run smoke-cache.mjs "$work/sample.sempere" "$key"
run smoke-pan.mjs "$fixtures/sample.sempere" "$key"
run smoke-attachments.mjs test/fixtures/render.sempere "$key" "$shots"
run smoke-video.mjs test/fixtures/render.sempere "$key" "$shots"
run smoke-release.mjs test/fixtures/render.sempere "$key"
run smoke-passkey.mjs "$fixtures/sample.sempere" "$key"
run smoke-language.mjs test/fixtures/render.sempere "$key"
run smoke-search-keys.mjs
echo "all browser smoke scripts passed"
