#!/usr/bin/env bash
# The app suites, run on a developer's Mac and recorded on GitHub as commit statuses (docs/ci.md).
#
#   scripts/local-ci.sh               # the PR gate: iOS compile check, Mac Catalyst unit tests (the
#                                     # pseudo-language layout check among them), package tests;
#                                     # posts `local/app-tests` (the `main` ruleset requires it)
#   scripts/local-ci.sh --testflight  # the gate, then the dense-note performance suite, the Mac unit tests with no network,
#                                     # the Mac launch smoke tests and every Mac UI test;
#                                     # posts `local/testflight-suite`
#   scripts/local-ci.sh --release     # all of --testflight, with the iPad and iPhone suites and the pseudo-language UI test on
#                                     # the iPad before the Mac UI tests, then the iPad UI tests and the iPhone canvas UI tests;
#                                     # posts `local/release-sweep`
#   scripts/local-ci.sh --no-status   # with any mode: run, but post nothing to GitHub
#   scripts/local-ci.sh --list        # with any mode: print its steps and status, run nothing
#
# The gate never needs the screen and runs no simulator: a Mac someone is using can run it. The
# --testflight and --release steps after the gate are UI tests that take over the screen (the Mac
# UI tests fail with "Running Background" when the app cannot come to the front): leave the Mac
# alone while they run. Every mode posts `local/app-tests` too once its gate steps have passed.
#
# Steps run cheapest first and the run stops at the first failed step. Inside a step the tests stop at the
# first failed test, which then runs twice more on its own: `TEST-RESULT FAILING|FLAKY <test>` lines say which
# (scripts/test-runner.py, docs/ci.md "Fail fast"); a flaky test fails the step too. SEMPERE_FAIL_FAST=0 runs every
# test of a step.
#
# A status is posted only for a clean checkout of a commit GitHub has, after every step passed, so
# it names exactly what was tested. The script holds a caffeinate assertion (it re-runs itself
# under `caffeinate -dimsu`) so the Mac cannot sleep in the middle of a run.
#
# Logs: build/local-ci/<step>.log.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=anthonytw/sempere
gate_context=local/app-tests
mode=gate
post=true
list=false
usage="usage: $0 [--testflight | --release] [--no-status] [--list]"
for arg in "$@"; do
  case "$arg" in
    --testflight) mode=testflight ;;
    --release) mode=release ;;
    --no-status) post=false ;;
    --list) list=true ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done

# Cheapest first, so a failure shows early (each step stands alone; `iphone` reuses `ipad`'s build).
gate_steps=(help ios-build mac package)
steps=("${gate_steps[@]}")
case "$mode" in
  gate)       context=$gate_context ;;
  testflight) context=local/testflight-suite; steps+=(mac-perf mac-offline mac-smoke mac-ui) ;;
  release)    context=local/release-sweep;    steps+=(mac-perf mac-offline mac-smoke ipad iphone pseudo mac-ui ipad-ui iphone-ui) ;;
esac

describe() {   # step: what it runs
  case "$1" in
    help)       echo "scripts/check-help.py          (every toolbar and icon-only control has a .help tooltip; tests use TestDefaults)" ;;
    package)    echo "swift build --build-tests && swift test --parallel (through scripts/test-runner.py)" ;;
    mac)        echo "scripts/app.sh test-mac        (Mac Catalyst unit tests, pseudo-language layouts included)" ;;
    ios-build)  echo "scripts/app.sh build-ios       (iOS simulator compile check, no tests)" ;;
    mac-offline) echo "scripts/app.sh test-mac-offline (Mac Catalyst unit tests with the network refused, OfflineModeTests)" ;;
    mac-ui)     echo "scripts/app.sh test-mac-ui     (Mac UI tests; screen)" ;;
    mac-smoke)  echo "scripts/app.sh test-mac-smoke  (Mac launch smoke tests; screen)" ;;
    mac-perf)   echo "scripts/app.sh test-mac-perf   (dense-note open time, scroll and zoom hitches, memory, against baselines)" ;;
    ipad)       echo "scripts/app.sh test            (iPad simulator unit tests)" ;;
    iphone)     echo "scripts/app.sh test-phone      (iPhone simulator suites)" ;;
    iphone-ui)  echo "scripts/app.sh test-phone-ui   (iPhone simulator canvas UI tests: tap, hold, draw)" ;;
    ipad-ui)    echo "scripts/app.sh test-ui         (iPad simulator UI tests)" ;;
    pseudo)     echo "scripts/app.sh pseudo          (pseudo-languages on the iPad simulator)" ;;
  esac
}

if [[ $list == true ]]; then
  echo "local-ci $mode: posts $context$([[ $context != "$gate_context" ]] && echo " (and $gate_context after the gate)")"
  for step in "${steps[@]}"; do printf '  %-11s %s\n' "$step" "$(describe "$step")"; done
  exit 0
fi

# Keep the Mac awake for the whole run (display, idle, disk and system sleep; user active).
if [[ -z "${SEMPERE_LOCAL_CI_CAFFEINATED:-}" ]] && command -v caffeinate >/dev/null; then
  export SEMPERE_LOCAL_CI_CAFFEINATED=1
  exec caffeinate -dimsu "$PWD/scripts/local-ci.sh" "$@"
fi

# A TMPDIR of this run's own, removed at exit: swift build/xcodebuild leave empty folders in the shared one.
# After the caffeinate re-exec, so the process that removes it is the one that runs the steps.
source scripts/run-tmp.sh

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

status() {   # context, state, description
  [[ $post == true ]] || return 0
  gh api -X POST "repos/$repo/statuses/$sha" -f state="$2" -f context="$1" \
    -f description="${3:0:140}" --silent
}

run_step() {
  case "$1" in
    help)       scripts/check-help.py --self-test && scripts/check-help.py && scripts/check-test-defaults.sh && /usr/bin/python3 -I scripts/test-runner.py --self-test ;;
    package)    swift build --build-tests && /usr/bin/python3 -I scripts/test-runner.py --kind swiftpm -- swift test --parallel ;;
    mac)        scripts/app.sh test-mac ;;
    ios-build)  scripts/app.sh build-ios ;;
    mac-offline) scripts/app.sh test-mac-offline ;;
    mac-ui)     scripts/app.sh test-mac-ui ;;
    mac-smoke)  scripts/app.sh test-mac-smoke ;;
    mac-perf)   scripts/app.sh test-mac-perf ;;
    ipad)       scripts/app.sh test ;;
    iphone)     scripts/app.sh test-phone ;;
    iphone-ui)  scripts/app.sh test-phone-ui ;;
    ipad-ui)    scripts/app.sh test-ui ;;
    pseudo)     scripts/app.sh pseudo ;;
  esac
}

# The Mac Catalyst steps fail when they leave temp folders in the app container (scripts/app.sh tmp-guard).
export SEMPERE_TMP_GUARD_FAIL=1
mkdir -p build/local-ci
host=$(scutil --get ComputerName 2>/dev/null || hostname -s)
start=$(date +%s)
gate_done=false
# Outside the gate mode, `local/app-tests` is left alone until the gate steps have a result, so an
# interrupted UI run never replaces an earlier gate success.
status "$context" pending "$mode run started on $host"
trap 'status "$context" error "interrupted on $host"' INT TERM
for i in "${!steps[@]}"; do
  step=${steps[$i]}
  t0=$(date +%s)
  printf 'local-ci: %-11s ' "$step"
  if run_step "$step" > "build/local-ci/$step.log" 2>&1; then
    echo "passed ($(( $(date +%s) - t0 ))s)"
  else
    echo "FAILED ($(( $(date +%s) - t0 ))s): build/local-ci/$step.log"
    grep -E "✘|error:|\*\* TEST FAILED|\*\* BUILD FAILED|XCB-STALL|FAIL-FAST" "build/local-ci/$step.log" | grep -v "^TEST-RESULT" | tail -20 || true
    # One line per failed test: FAILING (failed its reruns too) or FLAKY (passed both reruns; still a failure).
    grep -E "^TEST-RESULT " "build/local-ci/$step.log" | sed "s/^TEST-RESULT /local-ci: $step: /" || true
    status "$context" failure "$step failed on $host"
    if [[ $gate_done == false && $context != "$gate_context" ]]; then
      status "$gate_context" failure "$step failed on $host ($mode run)"
    fi
    exit 1
  fi
  if [[ $gate_done == false && $i -eq $(( ${#gate_steps[@]} - 1 )) ]]; then
    gate_done=true
    gate_minutes=$(( ($(date +%s) - start + 59) / 60 ))
    if [[ $context != "$gate_context" ]]; then
      status "$gate_context" success "gate: ${gate_steps[*]} passed on $host in $gate_minutes min ($mode run)"
    fi
  fi
done
minutes=$(( ($(date +%s) - start + 59) / 60 ))
status "$context" success "$mode: ${steps[*]} passed on $host in $minutes min"
if [[ $post == true ]]; then
  echo "local-ci: all passed in $minutes min; $context posted for ${sha:0:8}"
else
  echo "local-ci: all passed in $minutes min (nothing posted)"
fi
