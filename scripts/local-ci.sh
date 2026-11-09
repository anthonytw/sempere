#!/usr/bin/env bash
# The app suites, run on a developer's Mac and recorded on Gitea as commit statuses (docs/ci.md).
#
#   scripts/local-ci.sh               # the PR gate: iOS compile check, Mac Catalyst unit tests (the
#                                     # pseudo-language layout check among them), package tests, then in Docker the
#                                     # Linux package tests and the WebDAV tests; targets whose hash already passed
#                                     # are skipped (docs/design/ci-lean.md); posts `local/app-tests` (merging needs it)
#   scripts/local-ci.sh --testflight  # the gate, then the dense-note performance suite, the Mac unit tests with no network,
#                                     # the Mac launch smoke tests and every Mac UI test;
#                                     # posts `local/testflight-suite`
#   scripts/local-ci.sh --release     # all of --testflight, with the iPad and iPhone suites and the pseudo-language UI test on
#                                     # the iPad before the Mac UI tests, then the iPad UI tests and the iPhone canvas UI tests;
#                                     # posts `local/release-sweep`
#   scripts/local-ci.sh --cli         # a CLI-only release's checks, no app: the package tests on this Mac, then in
#                                     # Docker the Linux tests, the WebDAV integration tests and the static
#                                     # release build (scripts/ci-linux.sh); posts `local/cli-suite`
#   scripts/local-ci.sh --no-status   # with any mode: run, but post nothing to Gitea
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
# A status is posted only for a clean checkout of a commit Gitea has, after every step passed, so
# it names exactly what was tested. The script holds a caffeinate assertion (it re-runs itself
# under `caffeinate -dimsu`) so the Mac cannot sleep in the middle of a run.
#
# Logs: build/local-ci/<step>.log.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/forge.sh
gate_context=local/app-tests
mode=gate
post=true
list=false
usage="usage: $0 [--testflight | --release | --cli] [--no-status] [--list]"
for arg in "$@"; do
  case "$arg" in
    --testflight) mode=testflight ;;
    --release) mode=release ;;
    --cli) mode=cli ;;
    --no-status) post=false ;;
    --list) list=true ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done

# Cheapest first, so a failure shows early (each step stands alone; `iphone` reuses `ipad`'s build).
gate_steps=(help ios-build mac package linux webdav)
steps=("${gate_steps[@]}")
case "$mode" in
  gate)       context=$gate_context ;;
  testflight) context=local/testflight-suite; steps+=(mac-perf mac-offline mac-smoke mac-ui) ;;
  release)    context=local/release-sweep;    steps+=(mac-perf mac-offline mac-smoke ipad iphone pseudo mac-ui ipad-ui iphone-ui) ;;
  cli)        context=local/cli-suite; gate_steps=(); steps=(package linux webdav static) ;;
esac

# In the gate the Linux steps (Docker) run beside the Mac steps, in a lane of their own: they use Docker's VM, not the
# Catalyst app or the screen. Cold, measured 2026-11-09: serial 19.3 min (Mac steps 10.0 + linux 6.9 + webdav 2.4), beside the
# Mac steps 10 min, with the Mac steps no slower (mac 224 s vs 249 s, package 236 s vs 275 s). SEMPERE_CI_LINUX_LANE=serial
# runs them after the Mac steps; every other mode does.
lane=()
if [[ ${SEMPERE_CI_LINUX_LANE:-parallel} == parallel && $mode == gate ]]; then
  lane=(linux webdav); steps=(); for st in "${gate_steps[@]}"; do [[ $st == linux || $st == webdav ]] || steps+=("$st"); done; gate_steps=("${steps[@]}")
fi

# Only the gate skips targets that already passed with the same hash (docs/design/ci-lean.md); the release-bound
# modes run every package test again, here and in the Docker jobs (ci-linux.sh passes the variable into the container).
# The Linux jobs' records are in the same store as the Mac's (~/.cache/sempere-ci-pass, mounted into the container).
[[ $mode == gate ]] || export SEMPERE_CI_FORCE_ALL=1

describe() {   # step: what it runs
  case "$1" in
    help)       echo "scripts/check-help.py          (every toolbar and icon-only control has a .help tooltip; tests use TestDefaults; every UI test class is in one of app.sh's device lists)" ;;
    package)    echo "swift build --build-tests && swift test --parallel --skip Benchmarks (through scripts/test-runner.py; benchmarks are scripts/bench.sh); skips targets whose hash already passed (scripts/ci-hash.py)" ;;
    mac)        echo "scripts/app.sh test-mac        (Mac Catalyst unit tests, pseudo-language layouts included)" ;;
    ios-build)  echo "scripts/app.sh build-ios       (iOS simulator compile check, no tests)" ;;
    mac-offline) echo "scripts/app.sh test-mac-offline (Mac Catalyst unit tests with the network refused, OfflineModeTests)" ;;
    mac-ui)     echo "scripts/app.sh test-mac-ui     (Mac UI tests; screen)" ;;
    mac-smoke)  echo "scripts/app.sh test-mac-smoke  (Mac launch smoke tests; screen)" ;;
    mac-perf)   echo "scripts/app.sh test-mac-perf   (the benchmarks: dense-note open time, scroll and zoom hitches, memory, note-open timings)" ;;
    ipad)       echo "scripts/app.sh test            (iPad simulator unit tests)" ;;
    iphone)     echo "scripts/app.sh test-phone      (iPhone simulator suites)" ;;
    iphone-ui)  echo "scripts/app.sh test-phone-ui   (iPhone simulator canvas UI tests: tap, hold, draw)" ;;
    ipad-ui)    echo "scripts/app.sh test-ui         (iPad simulator UI tests)" ;;
    pseudo)     echo "scripts/app.sh pseudo          (pseudo-languages on the iPad simulator)" ;;
    linux)      echo "scripts/ci-linux.sh docker test   (Linux package tests offline, portability, removable importers)" ;;
    webdav)     echo "scripts/ci-linux.sh docker webdav (WebDAV integration tests against wsgidav)" ;;
    static)     echo "scripts/ci-linux.sh docker static (the fully static Linux release binary)" ;;
  esac
}

if [[ $list == true ]]; then
  echo "local-ci $mode: posts $context$([[ $context != "$gate_context" && ${#gate_steps[@]} -gt 0 ]] && echo " (and $gate_context after the gate)")"
  for step in "${steps[@]}"; do printf '  %-11s %s\n' "$step" "$(describe "$step")"; done
  for step in ${lane[@]+"${lane[@]}"}; do printf '  %-11s %s   [beside the steps above]\n' "$step" "$(describe "$step")"; done
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
if [[ $post == true ]] && ! forge_has_commit "$sha"; then
  echo "local-ci: Gitea does not have $sha yet; push it first" >&2
  exit 1
fi

status() {   # context, state, description
  [[ $post == true ]] || return 0
  forge_post_status "$sha" "$1" "$2" "$3"
}

# The package tests, skipping every target that already passed with the same hash (scripts/ci-hash.py,
# docs/design/ci-lean.md): the log names each skip's hash and the commit that passed it. SEMPERE_CI_FORCE_ALL=1 runs
# everything. SEMPERE_CI_MAC_PACKAGE=os-dependent also leaves the logic targets to the Linux job (scripts/ci-targets.json).
package_step() {
  export SEMPERE_CI_PASS_DIR=${SEMPERE_CI_PASS_DIR:-$HOME/.cache/sempere-ci-pass}
  local plan=build/local-ci/package.plan split=() skips=() t
  [[ ${SEMPERE_CI_MAC_PACKAGE:-all} == os-dependent ]] && split=(--os-dependent-only)
  /usr/bin/python3 -I scripts/ci-hash.py plan --job mac-package --out "$plan" ${split[@]+"${split[@]}"} || return 1
  while read -r t; do skips+=(--skip "^$t\\."); done < <(/usr/bin/python3 -I scripts/ci-hash.py skips "$plan")
  # The build always runs (incremental, cheap when warm): the benchmark targets are never tested but must still compile.
  swift build --build-tests || return 1
  if [[ $(/usr/bin/python3 -I scripts/ci-hash.py runs "$plan" | wc -l) -eq 0 ]]; then
    echo "package: every test target skipped (each passed with its current hash, or is left to Linux)"
    return 0
  fi
  /usr/bin/python3 -I scripts/test-runner.py --kind swiftpm -- swift test --parallel --skip 'Benchmarks\.' ${skips[@]+"${skips[@]}"} || return 1
  /usr/bin/python3 -I scripts/ci-hash.py record --plan "$plan"
}

run_step() {
  case "$1" in
    help)       scripts/check-help.py --self-test && /usr/bin/python3 -I scripts/ci-hash.py --self-test && scripts/test-ci-hash-guard.sh && /usr/bin/python3 -I scripts/ci-hash.py check-reads && scripts/check-help.py && scripts/check-test-defaults.sh && scripts/check-ui-tests.sh && /usr/bin/python3 -I scripts/test-runner.py --self-test ;;
    package)    package_step ;;
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
    linux)      scripts/ci-linux.sh docker test ;;
    webdav)     scripts/ci-linux.sh docker webdav ;;
    static)     scripts/ci-linux.sh docker static ;;
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
# The Docker lane's containers carry this run's label (ci-linux.sh docker: --label sempere-ci-run, --init), so a gate that
# ends early can remove exactly its own containers and nothing else's.
export SEMPERE_CI_RUN_ID="$$-$start" SEMPERE_CI_HOST=$host
lane_pid=""
step_pid=""
lane_stop() {   # stop the lane: remove its containers (the job inside dies with them), then the lane's own processes
  local c
  for c in $(docker ps -aq --filter "label=sempere-ci-run=$SEMPERE_CI_RUN_ID" 2>/dev/null); do docker rm -f "$c" >/dev/null 2>&1 || true; done
  if [[ -n $lane_pid ]]; then kill "$lane_pid" 2>/dev/null || true; wait "$lane_pid" 2>/dev/null || true; fi
  lane_pid=""
}
lane_passed() {   # the lane counts as passed only when every lane step has its own `passed` line in lane.result
  local st
  for st in "${lane[@]}"; do grep -q "^$st passed" build/local-ci/lane.result 2>/dev/null || return 1; done
}
lane_report_failure() {   # the first lane step without a `passed` line, as a failed step
  local bad="" st
  for st in "${lane[@]}"; do grep -q "^$st passed" build/local-ci/lane.result 2>/dev/null || { bad=$st; break; }; done
  echo "local-ci: $bad FAILED (or never finished): build/local-ci/$bad.log"
  grep -E "✘|error:|FAIL-FAST" "build/local-ci/$bad.log" 2>/dev/null | grep -v "^TEST-RESULT" | tail -20 || true
  grep -E "^TEST-RESULT " "build/local-ci/$bad.log" 2>/dev/null | sed "s/^TEST-RESULT /local-ci: $bad: /" || true
  status "$context" failure "$bad failed on $host"
  [[ $gate_done == true || $context == "$gate_context" ]] || status "$gate_context" failure "$bad failed on $host ($mode run)"
}
run_lane() {   # the lane's steps in order; the first failure stops it; build/local-ci/lane.result says how each ended
  local st t0 child=""
  trap '[[ -n $child ]] && kill $child 2>/dev/null; exit 143' TERM INT
  for st in "${lane[@]}"; do
    t0=$(date +%s)
    run_step "$st" > "build/local-ci/$st.log" 2>&1 & child=$!
    if wait "$child"; then echo "$st passed ($(( $(date +%s) - t0 ))s)" >> build/local-ci/lane.result
    else echo "$st FAILED ($(( $(date +%s) - t0 ))s)" >> build/local-ci/lane.result; return 1; fi
  done
}
kill_tree() {   # a process and everything below it, by PID
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done
  kill -TERM "$1" 2>/dev/null || true
}
on_signal() {   # SIGINT/SIGTERM: nothing passed; stop everything, post no success, end the run
  trap '' INT TERM
  [[ -n $step_pid ]] && kill_tree "$step_pid"
  lane_stop
  status "$context" error "interrupted on $host"
  exit 130
}
trap on_signal INT TERM
if [[ ${#lane[@]} -gt 0 ]]; then
  rm -f build/local-ci/lane.result
  echo "local-ci: ${lane[*]} run in Docker beside the Mac steps (logs build/local-ci/<step>.log, result at the end)"
  run_lane & lane_pid=$!
fi
for i in "${!steps[@]}"; do
  step=${steps[$i]}
  t0=$(date +%s)
  printf 'local-ci: %-11s ' "$step"
  # In the background and waited for, so a signal is handled at once instead of after the step.
  run_step "$step" > "build/local-ci/$step.log" 2>&1 & step_pid=$!
  if wait "$step_pid"; then
    step_pid=""
    echo "passed ($(( $(date +%s) - t0 ))s)"
    grep -E '^ci-hash: (SKIP|RUN|recorded|not recording)' "build/local-ci/$step.log" | sed 's/^/  /' || true
  else
    step_pid=""
    echo "FAILED ($(( $(date +%s) - t0 ))s): build/local-ci/$step.log"
    grep -E "✘|error:|\*\* TEST FAILED|\*\* BUILD FAILED|XCB-STALL|FAIL-FAST" "build/local-ci/$step.log" | grep -v "^TEST-RESULT" | tail -20 || true
    # One line per failed test: FAILING (failed its reruns too) or FLAKY (passed both reruns; still a failure).
    grep -E "^TEST-RESULT " "build/local-ci/$step.log" | sed "s/^TEST-RESULT /local-ci: $step: /" || true
    lane_stop
    status "$context" failure "$step failed on $host"
    if [[ $gate_done == false && $context != "$gate_context" && ${#gate_steps[@]} -gt 0 ]]; then
      status "$gate_context" failure "$step failed on $host ($mode run)"
    fi
    exit 1
  fi
  # A Linux failure fails the gate as soon as it is known.
  if [[ ${#lane[@]} -gt 0 ]] && grep -q ' FAILED' build/local-ci/lane.result 2>/dev/null; then
    wait "$lane_pid" 2>/dev/null || true; lane_pid=""; lane_stop
    lane_report_failure
    exit 1
  fi
  if [[ $gate_done == false && ${#gate_steps[@]} -gt 0 && $i -eq $(( ${#gate_steps[@]} - 1 )) ]]; then
    gate_done=true
    gate_minutes=$(( ($(date +%s) - start + 59) / 60 ))
    if [[ $context != "$gate_context" ]]; then
      status "$gate_context" success "gate: ${gate_steps[*]} passed on $host in $gate_minutes min ($mode run)"
    fi
  fi
done
if [[ ${#lane[@]} -gt 0 ]]; then
  # The verdict comes from the lane's own result lines, never from whether a process is still around.
  wait "$lane_pid" 2>/dev/null || true; lane_pid=""
  if ! lane_passed; then lane_stop; lane_report_failure; exit 1; fi
  sed 's/^/local-ci: /; s/^\(local-ci: [a-z]*\) /\1 (beside) /' build/local-ci/lane.result
  for st in "${lane[@]}"; do grep -E '^ci-hash: (SKIP|RUN|recorded|not recording)' "build/local-ci/$st.log" | sed 's/^/  /' || true; done
fi
minutes=$(( ($(date +%s) - start + 59) / 60 ))
status "$context" success "$mode: ${steps[*]} passed on $host in $minutes min"
if [[ $post == true ]]; then
  echo "local-ci: all passed in $minutes min; $context posted for ${sha:0:8}"
else
  echo "local-ci: all passed in $minutes min (nothing posted)"
fi
