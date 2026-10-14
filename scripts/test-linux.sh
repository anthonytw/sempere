#!/usr/bin/env bash
# Run the test suite the way Linux CI does: natively on Linux with Swift on
# PATH, otherwise in Docker with the CI image.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${SWIFT_IMAGE:-swift:6.4-noble}"
if [[ "$(uname)" == "Linux" ]] && command -v swift >/dev/null; then
  exec swift test "$@"
fi
if ! command -v docker >/dev/null; then
  echo "error: need Docker (or run on Linux with Swift installed)" >&2
  exit 1
fi
exec docker run --rm -v "$PWD":/src -w /src "$IMAGE" \
  bash -c 'apt-get update -q >/dev/null && apt-get install -y -q zlib1g-dev age >/dev/null && swift test "$@"' -- "$@"
