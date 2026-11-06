#!/usr/bin/env bash
# Runs the benchmarks (docs/ci.md "Benchmarks"): the print-only timing tests, one test target per module measured.
#   scripts/bench.sh                 every module
#   scripts/bench.sh render webdav   the named modules
#   scripts/bench.sh --list          the modules and what they hold
# Modules: sempere (SempereBenchmarks), render (SempereRenderBenchmarks), webdav (SempereWebDAVBenchmarks),
# pdf (SemperePDFBenchmarks), age (AgeBenchmarks). Each module runs in a process of its own, so a run's peak memory
# is its own, and in an optimized build (`-c release -Xswiftc -enable-testing`; the tests reach into the modules with
# `@testable`): numbers from a debug build say little. SEMPERE_BENCH_DEBUG=1 builds and runs unoptimized anyway.
# Extra arguments after `--` go to `swift test` (e.g. `-- --filter SummaryBenchmarks`).
#
# Benchmarks never gate anything: the PR gate, the Linux CI jobs and a plain `just test` skip every target whose name
# ends in `Benchmarks` (`--skip 'Benchmarks\.'`). Run them on a schedule and before a release.
#
# Sizes: most tests have a modest default and environment variables for a realistic one (`SEMPERE_BENCH_NOTES=600`,
# `SEMPERE_BENCH_STROKES`, `SEMPERE_BENCH_REVISIONS`, ... each named in its test's doc comment). Tools that only
# generate data for a manual measurement (`ExportBenchVault`: `SEMPERE_BENCH_VAULT=DIR`) skip unless asked.
# The sync stress and timing runs against wsgidav are `scripts/sync-stress.sh`.
set -euo pipefail
cd "$(dirname "$0")/.."

target_of() {
  case "$1" in
    sempere) echo SempereBenchmarks ;;
    render) echo SempereRenderBenchmarks ;;
    webdav) echo SempereWebDAVBenchmarks ;;
    pdf) echo SemperePDFBenchmarks ;;
    age) echo AgeBenchmarks ;;
    *) echo "error: unknown module '$1' (sempere, render, webdav, pdf, age)" >&2; exit 2 ;;
  esac
}

modules=()
extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list) grep -rhoE "^final class [A-Za-z]+Benchmarks?[A-Za-z]*" Tests/*Benchmarks/*.swift | sed 's/final class //' | sort; exit 0 ;;
    --) shift; extra=("$@"); break ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) modules+=("$1") ;;
  esac
  shift
done
[ ${#modules[@]} -gt 0 ] || modules=(sempere render webdav pdf age)

flags=()
[ "${SEMPERE_BENCH_DEBUG:-}" = 1 ] || flags=(-c release -Xswiftc -enable-testing)

status=0
for m in "${modules[@]}"; do
  target="$(target_of "$m")"
  echo "== bench: $m ($target)"
  swift test ${flags[@]+"${flags[@]}"} --filter "^$target\." ${extra[@]+"${extra[@]}"} || status=$?
done
exit "$status"
