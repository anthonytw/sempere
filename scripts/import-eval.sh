#!/usr/bin/env bash
# Notability import fidelity evaluation (docs/import-notability.md,
# "Fidelity evaluation"). macOS with Xcode, an iPadOS 27+ simulator and uv.
#
#   scripts/import-eval.sh [--out OUT_DIR] BACKUP.zip [BACKUP-2.zip ...]
#   scripts/import-eval.sh BACKUP.zip OUT_DIR        (older form: one input)
#
# Pass every part of a backup Drive split into several zips. OUT_DIR (default
# data/eval) must be git-ignored: everything written there is
# derived from personal notes. Writes OUT_DIR/report.html, OUT_DIR/summary.json
# and OUT_DIR/img/; the scratch vault, its key and the per-band images live in
# OUT_DIR/work and are deleted at the end unless SEMPERE_EVAL_KEEP=1.
#
#   SEMPERE_SIM_ID=<udid>        simulator for the canvas stage (default: as scripts/app.sh)
#   SEMPERE_EVAL_SKIP_CANVAS=1   oracle only (no simulator)
#   SEMPERE_EVAL_ONLY=<id8>      canvas stage: only notes whose id starts with this
#   SEMPERE_EVAL_SETTLE_MS=1200  canvas stage: wait for PencilKit's tiles per band
#   SEMPERE_EVAL_KEEP=1          keep OUT_DIR/work
set -euo pipefail
cd "$(dirname "$0")/.."

out="data/eval"
inputs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    *) inputs+=("$1"); shift ;;
  esac
done
# Older form: BACKUP OUT_DIR, where OUT_DIR is not an input.
if [[ ${#inputs[@]} -eq 2 && ! -f "${inputs[1]}" && "${inputs[1]}" != *.zip && "${inputs[1]}" != *.note ]]; then
  out="${inputs[1]}"
  inputs=("${inputs[0]}")
fi
if [[ ${#inputs[@]} -lt 1 ]]; then
  echo "usage: $0 [--out OUT_DIR] BACKUP.zip|NOTES_DIR ..." >&2
  exit 2
fi
samples=""
for f in "${inputs[@]}"; do
  if [[ ! -e "$f" ]]; then echo "error: no such input: $f" >&2; exit 2; fi
  samples="${samples:+$samples:}$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
done
mkdir -p "$out"
out="$(cd "$out" && pwd)"
# Inside any git work tree (this one, or the main checkout's data/ from a
# worktree) the directory must be ignored there.
if git -C "$out" rev-parse --show-toplevel > /dev/null 2>&1 && ! git -C "$out" check-ignore -q "$out"; then
  echo "error: $out is not git-ignored; the evaluation writes data derived from personal notes" >&2
  exit 2
fi
work="$out/work"

echo "== stage 1: import into a scratch vault, render page 1 at every thumbnail size and every page" >&2
# Release build (with testability): rendering every page in a debug build is ~10x slower.
SEMPERE_NOTABILITY_SAMPLES="$samples" SEMPERE_EVAL_DIR="$work" \
  swift test -c release -Xswiftc -enable-testing --filter ImportFidelityEvalTests/testExportEvaluationInputs
if [[ ! -f "$work/import.json" ]]; then
  echo "error: stage 1 wrote nothing (was the test skipped?)" >&2
  exit 1
fi

if [[ -z "${SEMPERE_EVAL_SKIP_CANVAS:-}" ]]; then
  echo "== stage 2: every band on the canvas (simulator) and in the export" >&2
  sim=$(scripts/app.sh simulator)
  rm -rf "$work/canvas"
  TEST_RUNNER_SEMPERE_EVAL_VAULT="$work/vault.sempere" \
  TEST_RUNNER_SEMPERE_EVAL_IDENTITY="$work/identity.key" \
  TEST_RUNNER_SEMPERE_EVAL_OUT="$work/canvas" \
  TEST_RUNNER_SEMPERE_EVAL_ONLY="${SEMPERE_EVAL_ONLY:-}" \
  TEST_RUNNER_SEMPERE_EVAL_SETTLE_MS="${SEMPERE_EVAL_SETTLE_MS:-1200}" \
    xcodebuild test -project Apps/Sempere/Sempere.xcodeproj -scheme SempereApp \
      -derivedDataPath "${SEMPERE_DERIVED_DATA:-.build/xcode}" \
      -destination "platform=iOS Simulator,id=$sim" CODE_SIGNING_ALLOWED=NO \
      -only-testing:SempereAppTests/CanvasExportEvalTests > "$work/xcodebuild.log" 2>&1 || {
        echo "error: canvas stage failed; see $work/xcodebuild.log" >&2
        exit 1
      }
fi

echo "== stage 3: metrics and report" >&2
uv run scripts/import_eval.py --work "$work" --out "$out"

if [[ -z "${SEMPERE_EVAL_KEEP:-}" ]]; then
  rm -rf "$work"
fi
echo "report: $out/report.html" >&2
