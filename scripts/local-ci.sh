#!/usr/bin/env bash
# The app suites, run on a developer's Mac and recorded on GitHub (docs/ci.md).
#
#   scripts/local-ci.sh           # package, iPad, iPhone, iPad UI, pseudo-language, Mac Catalyst suites
#   scripts/local-ci.sh --quick   # package, iPad and iPhone suites only
#   scripts/local-ci.sh --mac-ui  # also the Mac UI and launch smoke tests (they take over the screen)
#   scripts/local-ci.sh --no-status   # run, but post nothing to GitHub
#
# The Mac UI tests need the app in front: on a Mac someone is using they fail with "Failed to
# activate application … Running Background". So they are not in the default run; `main` runs them.
#
# The hosted macOS runner needs over an hour for the app job (a 3-CPU VM: 21 min to build what a
# Mac builds in 3). PRs therefore run only the iPad and iPhone suites there, for feedback, and
# `main` runs the rest. What a PR needs to merge is this script's commit status `local/app-tests`
# on its head commit, which the `main` ruleset requires: it is posted only for a clean checkout
# of a commit GitHub has, after every step passed, so it names exactly what was tested.
#
# Logs: build/local-ci/<step>.log.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=anthonytw/sempere
context=local/app-tests
mode=full
post=true
mac_ui=false
for arg in "$@"; do
  case "$arg" in
    --quick) mode=quick ;;
    --no-status) post=false ;;
    --mac-ui) mac_ui=true ;;
    *) echo "usage: $0 [--quick] [--mac-ui] [--no-status]" >&2; exit 2 ;;
  esac
done

# A result belongs to a commit: nothing uncommitted (tracked or not) may be in the build.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "local-ci: the checkout has uncommitted changes; commit them (or run with --no-status)" >&2
  if [[ $post == true ]]; then exit 1; fi
fi
sha=$(git rev-parse HEAD)
if [[ $post == true ]] && ! gh api "repos/$repo/commits/$sha" --silent 2>/dev/null; then
  echo "local-ci: GitHub does not have $sha yet; push it first" >&2
  exit 1
fi

status() {   # state, description
  [[ $post == true ]] || return 0
  gh api -X POST "repos/$repo/statuses/$sha" -f state="$1" -f context="$context" \
    -f description="${2:0:140}" --silent
}

steps=(package ipad iphone)
[[ $mode == full ]] && steps+=(ipad-ui pseudo mac)
[[ $mac_ui == true ]] && steps+=(mac-ui mac-smoke)

run_step() {
  case "$1" in
    package)   swift build --build-tests && swift test --parallel ;;
    ipad)      scripts/app.sh test ;;
    iphone)    scripts/app.sh test-phone ;;
    ipad-ui)   scripts/app.sh test-ui ;;
    pseudo)    scripts/app.sh pseudo ;;
    mac)       scripts/app.sh test-mac ;;
    mac-ui)    scripts/app.sh test-mac-ui ;;
    mac-smoke) scripts/app.sh test-mac-smoke ;;
  esac
}

mkdir -p build/local-ci
host=$(scutil --get ComputerName 2>/dev/null || hostname -s)
start=$(date +%s)
status pending "$mode run started on $host"
trap 'status error "interrupted on $host"' INT TERM
for step in "${steps[@]}"; do
  t0=$(date +%s)
  printf 'local-ci: %-9s ' "$step"
  if run_step "$step" > "build/local-ci/$step.log" 2>&1; then
    echo "passed ($(( $(date +%s) - t0 ))s)"
  else
    echo "FAILED ($(( $(date +%s) - t0 ))s): build/local-ci/$step.log"
    grep -E "✘|error:|\*\* TEST FAILED|XCB-STALL" "build/local-ci/$step.log" | tail -20 || true
    status failure "$step failed on $host"
    exit 1
  fi
done
minutes=$(( ($(date +%s) - start + 59) / 60 ))
status success "$mode: ${steps[*]} passed on $host in $minutes min"
if [[ $post == true ]]; then
  echo "local-ci: all passed in $minutes min; $context posted for ${sha:0:8}"
else
  echo "local-ci: all passed in $minutes min (nothing posted)"
fi
