#!/usr/bin/env bash
# Tests the cross-read guard of scripts/ci-hash.py (docs/design/ci-lean.md "Target hashes"): with the manifest's
# extra_inputs ignored, `check-reads` must itself find every read a test makes outside its own folder that is known
# (the 2026-11-08 review's list), and with the manifest it must find none. Needs `swift` (it reads Package.swift).
# Runs on Linux and macOS; scripts/local-ci.sh's `help` step and ci-linux.sh's `test` job run it.
set -euo pipefail
cd "$(dirname "$0")/.."
py=python3; [[ -x /usr/bin/python3 ]] && py=/usr/bin/python3
out=$($py -I scripts/ci-hash.py check-reads --without-extras 2>&1 || true)
fail=0
expect() {   # target, path the guard must report for it
  if ! grep -qF "reads $2, which is not in the hash of $1" <<<"$out" && ! grep -qE "reads $2[^ ]*, which is not in the hash of $1" <<<"$out"; then
    echo "FAIL the guard did not find: $1 reads $2"; fail=1
  fi
}
for doc in docs/settings-sync.md docs/settings.schema.json docs/format.md docs/design/key-hierarchy.md web/test/fixtures web/test/golden Apps/Sempere/SempereApp Sources; do
  expect SempereTests "$doc"
done
for t in CLITests SempereAppCoreTests SempereNotabilityTests SempereRenderTests SempereWebDAVTests; do expect "$t" Tests/SempereTests/Fixtures; done
for t in CLITests SempereRenderTests; do expect "$t" Tests/SemperePDFTests/Fixtures; done
expect CLITests Tests/SempereRenderTests/Fixtures
for f in SECURITY.md LICENSE LICENSE-EXCEPTION docs/security.md; do expect SempereTests "$f"; done   # AboutTests, through LocalizationCatalogTests.repo
# VideoExportTests reads ../SempereTests/Fixtures/video from its own #filePath: only an appended "../" can find it
if ! grep -qF "Tests/SempereRenderTests/VideoExportTests.swift:161: reads Tests/SempereTests/Fixtures/video" <<<"$out"; then
  echo "FAIL the guard did not find VideoExportTests.swift:161 (the ../ read)"; fail=1
fi
if [[ $fail -ne 0 ]]; then echo "$out" | head -80; exit 1; fi
$py -I scripts/ci-hash.py check-reads 2>&1 | tail -1
echo "ci-hash guard test: all known cross-folder reads found, none left undeclared"
