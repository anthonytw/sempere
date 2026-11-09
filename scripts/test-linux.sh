#!/usr/bin/env bash
# Run the test suite the way Linux CI does: natively on Linux with Swift on
# PATH, otherwise in Docker with the CI image.
# --parallel is always passed: without it, a run with --skip or --filter hands the test runner every selected test as ONE
# comma-joined argument, and past ~128 KB (Linux's MAX_ARG_STRLEN; the suite is ~265 KB of names) the launch fails with
# `posix_spawn error: Argument list too long`. --parallel runs the tests through per-test launches instead.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${SWIFT_IMAGE:-swift:6.4-noble}"
if [[ "$(uname)" == "Linux" ]] && command -v swift >/dev/null; then
  exec swift test --parallel --skip 'Benchmarks\.' "$@"   # the benchmark targets are scripts/bench.sh
fi
if ! command -v docker >/dev/null; then
  echo "error: need Docker (or run on Linux with Swift installed)" >&2
  exit 1
fi
exec docker run --rm -v "$PWD":/src -w /src "$IMAGE" \
  bash -c 'apt-get update -q >/dev/null && apt-get install -y -q zlib1g-dev age >/dev/null && swift test "$@"' -- --parallel --skip 'Benchmarks\.' "$@"
