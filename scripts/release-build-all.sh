#!/usr/bin/env bash
# The three release builds at once, from the checkout this script is in (scripts/release-build.sh runs it in the tag's worktree):
# the fully static Linux x86_64 and aarch64 binaries (scripts/ci-linux.sh docker static:ARCH, each in a container of its own) and
# the macOS universal binary (swift build --arch arm64 --arch x86_64). A serial build leaves a Mac mostly idle.
#
#   scripts/release-build-all.sh LOGDIR
#
# - One log per build in LOGDIR (linux-x86_64.log, linux-aarch64.log, macos-universal.log); the tail of a failed one is printed.
# - Exit 0 only when all three succeeded; every build is waited for, so none is left running behind a failure.
# - Each Linux build is its own ci-linux.sh process, so each has fresh .build and ~/.swiftpm Docker volumes (unique per process,
#   removed when it ends; the audit's F-01). SEMPERE_LINUX_BUILD_VOLUME is unset: nothing is shared between the two.
#   Only the SDK archive is shared, verified and read-only (scripts/static-sdk-cache.sh); it is fetched here first so the two
#   never race to fill the cache. Outputs are build/linux-static/sempere-<arch> (one file each) and SwiftPM's macOS .build.
# - The containers carry the label sempere-ci-run=$SEMPERE_BUILD_ID (default release-<pid>). On exit, TERM, HUP or INT the
#   macOS build is stopped and the containers with that label are killed; each wrapper then sees its container end, removes its
#   volumes and exits, and this script waits for all of them before it returns.
set -euo pipefail
cd "$(dirname "$0")/.."
logs=${1:?usage: $0 LOGDIR}
mkdir -p "$logs"
unset SEMPERE_LINUX_BUILD_VOLUME
id=${SEMPERE_BUILD_ID:-release-$$}
export SEMPERE_CI_RUN_ID=$id

scripts/static-sdk-cache.sh >/dev/null || { echo "error: cannot get a verified Static Linux SDK archive" >&2; exit 1; }

pids=() names=()
cleanup() {
  trap - EXIT TERM HUP INT
  [[ ${#pids[@]} -gt 0 ]] || return 0
  local i
  for i in "${!pids[@]}"; do [[ ${names[$i]} == macos-universal ]] && kill "${pids[$i]}" 2>/dev/null || true; done
  if command -v docker >/dev/null; then
    docker ps -q --filter "label=sempere-ci-run=$id" | xargs docker kill >/dev/null 2>&1 || true
  fi
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM HUP INT

start() {   # name command...
  local name=$1; shift
  "$@" >"$logs/$name.log" 2>&1 &
  pids+=($!); names+=("$name")
}
start linux-x86_64 scripts/ci-linux.sh docker static:x86_64
start linux-aarch64 scripts/ci-linux.sh docker static:aarch64
start macos-universal swift build -c release --product sempere --arch arm64 --arch x86_64

failed=()
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then
    echo "ok    ${names[$i]} built"
  else
    echo "FAIL  ${names[$i]}: $logs/${names[$i]}.log (end of it below)"
    tail -n 40 "$logs/${names[$i]}.log" | sed 's/^/      | /'
    failed+=("${names[$i]}")
  fi
done
pids=()
[[ ${#failed[@]} -eq 0 ]] || { echo "error: build failed: ${failed[*]}" >&2; exit 1; }
