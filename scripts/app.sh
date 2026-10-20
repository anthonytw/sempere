#!/usr/bin/env bash
# Build and test the iPad/Mac app (Apps/Sempere). Needs Xcode; macOS only.
#
#   scripts/app.sh test       # xcodebuild test on an iPad simulator
#   scripts/app.sh test-phone # the iPhone suites (PhoneLayoutTests) on an iPhone simulator
#   scripts/app.sh test-phone-ui # the iPhone canvas UI tests (PhoneCanvasUITests: tap selects, hold menu, finger draws; PhoneParityUITests: stack, new note, Settings, import, search, unlock; PhoneReadingScrollUITests: one finger scrolls while reading; PhoneCanvasModeUITests: Reading, Hand and Annotate; SearchHighlightUITests: search highlights and stepping) on an iPhone simulator
#   scripts/app.sh build-ios  # compile only: the app, its unit tests and its UI tests for an iOS simulator (runs nothing)
#   scripts/app.sh catalyst   # Mac Catalyst build, unsigned
#   scripts/app.sh pseudo     # UI-test layout check in the double-length, right-to-left and Spanish languages, iPad
#                             # simulator (by hand; the gate runs the in-process PseudoLanguageLayoutTests in test-mac)
#   scripts/app.sh pseudo-mac # the same as the Mac Catalyst app, at a narrow and a wide window (takes over the screen)
#   scripts/app.sh test-mac   # every app suite on Mac Catalyst, ad-hoc signed and sandboxed
#   scripts/app.sh test-mac-ui # the Mac UI tests (MacWindowUITests, MacItemUITests, SidebarDropUITests, MacFocusUITests,
#                              # KeyShareMacUITests, QuitPurgeMacUITests, NewVaultSheetUITests, MacImportUITests, MacExportUITests, MacRealMouseUITests) on Mac Catalyst
#   scripts/app.sh test-mac-perf # the dense-note performance suite (DensePerformanceTests) on Mac Catalyst: open time, scroll and zoom
#                              # frame hitches, memory, against baselines (slow; test-mac leaves it out)
#   scripts/app.sh test-ui    # the iPad UI tests (SidebarDropUITests: real drags; the launch smoke tests) on an iPad simulator
#   scripts/app.sh test-mac-smoke # the launch smoke tests (LaunchSmokeUITests: fresh state, every layout and window) on Mac Catalyst
#   scripts/app.sh simulator [PREFIX [SUFFIX]] # print the simulator id `test` would use (or one named PREFIX…SUFFIX)
#
# The test subcommands pass any further arguments on to xcodebuild. An -only-testing among them
# replaces the subcommand's own suite list: `scripts/app.sh test -only-testing:SempereAppTests/FooTests`
# runs that one suite, `scripts/app.sh test-mac -only-testing:…` the same on Mac Catalyst.
#
# SEMPERE_SIM_ID overrides the simulator choice.
#
# The Mac UI tests (test-mac-ui, test-mac-smoke) are ad-hoc signed. Off CI they build without the
# hardened runtime: on a Mac with a developer identity the ad-hoc UI-test runner otherwise refuses
# its own test bundle ("mapping process and mapped file (non-platform) have different Team IDs").
# SEMPERE_MAC_UI_SIGNING=ci keeps CI's settings locally; CI (CI=true) is unchanged.
set -euo pipefail
cd "$(dirname "$0")/.."
project=Apps/Sempere/Sempere.xcodeproj
scheme=SempereApp
derived=${SEMPERE_DERIVED_DATA:-.build/xcode}
# Tests assert English strings: run them in English whatever the Mac's language (es catalog, #92).
lang=(-testLanguage en -testRegion US)
mac_ui_signing=(CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES)
# UI tests on CI run a failed test once more: the hosted runners are slow and a UI query
# times out now and then. A real bug fails both tries and still fails the job. Unit tests
# and local runs never retry.
ui_retry=()
if [[ "${CI:-}" == true ]]; then
  ui_retry=(-retry-tests-on-failure -test-iterations 2)
fi
if [[ "${CI:-}" != true && "${SEMPERE_MAC_UI_SIGNING:-}" != ci ]]; then
  mac_ui_signing+=(ENABLE_HARDENED_RUNTIME=NO)
fi

# The simulator for $1 (iPad or iPhone, default iPad), ending with $2 when given ("Pro Max"), on the
# newest iOS runtime: the family's preferred model (scripts/pick-simulator.py: iPad Pro 13-inch
# first, never the iPad mini while another iPad is there). SEMPERE_SIM_ID overrides it.
pick_simulator() {
  local family=${1:-iPad}
  if [[ -n "${SEMPERE_SIM_ID:-}" ]]; then echo "$SEMPERE_SIM_ID"; return; fi
  xcrun simctl list devices available --json | /usr/bin/python3 scripts/pick-simulator.py "$family" "${2:-}"
}

# CI only: boots simulator $1 and waits for it to finish booting, then (at most
# SEMPERE_SIM_SETTLE seconds, default 180) for the runner's load to drop below its CPU count.
# xcodebuild otherwise boots the simulator itself and starts the tests at once, while the
# freshly booted iOS 27 simulator is still busy: on the 3-core xcode-27 runner the first UI
# tests then took 12-27 s to set up their automation session (later ones 1-4 s) and the
# app's accessibility queries timed out ("Failed to get matching snapshots"). Locally a
# no-op, so a developer's own simulators are left alone.
settle_simulator() {
  [[ "${CI:-}" == true ]] || return 0
  local sim=$1 limit=${SEMPERE_SIM_SETTLE:-180} cpus load waited=0
  xcrun simctl bootstatus "$sim" -b >/dev/null || true
  cpus=$(sysctl -n hw.ncpu)
  while :; do
    load=$(sysctl -n vm.loadavg | awk '{print $2}')
    if awk -v l="$load" -v c="$cpus" 'BEGIN { exit !(l < c) }' || (( waited >= limit )); then break; fi
    sleep 10; waited=$((waited + 10))
  done
  echo "SIM-SETTLE $sim booted; load $load on $cpus CPUs after ${waited}s"
}

# `xcodebuild` for test runs. Locally it sometimes sits for minutes, idle, after the last test has
# reported (7 min after the full iPad suite on 2026-10-12; a short suite exits at once). Off CI,
# once the run has printed its summary and then nothing for SEMPERE_STALL_SECS (default 180), it is
# stopped and the summary decides: failed if any summary says so, else passed. CI runs it as is.
xcb() {
  if [[ "${CI:-}" == true ]]; then xcodebuild "$@"; return; fi
  local log stall=${SEMPERE_STALL_SECS:-180} pid status=0
  log=$(mktemp -t sempere-xcb)
  xcodebuild "$@" > >(tee "$log") 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    grep -qE "Test run with [0-9]+ tests|Test Suite 'All tests' (passed|failed)" "$log" || continue
    (( $(date +%s) - $(stat -f %m "$log") >= stall )) || continue
    echo "XCB-STALL xcodebuild silent for ${stall}s after its test summary: stopping it" >&2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    if grep -qE "✘ Test run with|Test Suite 'All tests' failed|\*\* TEST FAILED" "$log"; then status=65; fi
    rm -f "$log"
    return $status
  done
  wait "$pid" || status=$?
  rm -f "$log"
  return $status
}

# On CI, a simulator left booted keeps loading the 3-CPU runner through every later step (loads of
# several hundred, UI queries timing out): shut down what a step is done with.
shutdown_simulators() {
  [[ "${CI:-}" == true ]] || return 0
  xcrun simctl shutdown "${1:-all}" >/dev/null 2>&1 || true
}

# Arguments after the subcommand, for xcodebuild. `suites A B …` sets $only to the subcommand's
# default -only-testing list, or to nothing when the caller named their own.
extra=("${@:2}")
narrowed=false
for arg in ${extra[@]+"${extra[@]}"}; do [[ "$arg" == -only-testing:* ]] && narrowed=true; done
suites() { if $narrowed; then only=(); else only=("$@"); fi; }
# The slow performance suite (test-mac-perf): out of test-mac, which would otherwise run every app suite.
perf_suites=(-skip-testing:SempereAppTests/DensePerformanceTests)
only=()

# Temp-folder guard (docs/ci.md "Temp-folder guard"): a Mac Catalyst run must leave the sandboxed app
# container's tmp as it found it. Tests that leaked there piled up 195,000 folders and hit APFS's 65,535
# subfolder limit, which failed every later run with Cocoa error 512. Prints before/after counts; leaving
# more than SEMPERE_TMP_LEAK_MAX (default 20) entries behind warns, and fails the step when
# SEMPERE_TMP_GUARD_FAIL=1 (local-ci sets it). The iOS simulator runs are not covered: their tmp is
# inside a throwaway simulator clone.
container_tmp="${SEMPERE_CONTAINER_TMP:-$HOME/Library/Containers/io.github.anthonytw.sempere/Data/tmp}"
tmp_count() { ls -A "$container_tmp" 2>/dev/null | wc -l | tr -d ' '; }
tmp_guard_start() {
  tmp_before=$(tmp_count)
  trap 'tmp_guard_report $?' EXIT
}
tmp_guard_report() {
  local rc=$1 after delta max=${SEMPERE_TMP_LEAK_MAX:-20}
  trap - EXIT
  after=$(tmp_count)
  delta=$((after - tmp_before))
  echo "tmp-guard: app container tmp entries before=$tmp_before after=$after (delta $delta, limit $max)"
  if (( delta > max )); then
    echo "tmp-guard: WARNING: this run left $delta entries in $container_tmp; a test or code path is not cleaning up (use TestTemp, docs/ci.md)" >&2
    if [[ "${SEMPERE_TMP_GUARD_FAIL:-}" == 1 && $rc -eq 0 ]]; then rc=1; fi
  fi
  exit "$rc"
}

case "${1:-}" in
  simulator)
    pick_simulator "${2:-}" "${3:-}"
    ;;
  test)
    sim=$(pick_simulator)
    settle_simulator "$sim"
    skip=("${perf_suites[@]}"); $narrowed && skip=()   # the performance suite is the Mac's (test-mac-perf)
    xcb test "${lang[@]}" -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
      -destination "platform=iOS Simulator,id=$sim" CODE_SIGNING_ALLOWED=NO ${skip[@]+"${skip[@]}"} ${extra[@]+"${extra[@]}"}
    ;;
  test-phone)
    # Same build products as `test` (the simulator SDK is shared), so after it this only runs the suites.
    sim=$(pick_simulator iPhone)
    settle_simulator "$sim"
    suites -only-testing:SempereAppTests/CompactNavigationTests -only-testing:SempereAppTests/CompactBackTests \
      -only-testing:SempereAppTests/PhoneReadingTests \
      -only-testing:SempereAppTests/PhoneCanvasTests -only-testing:SempereAppTests/PhoneRootTests \
      -only-testing:SempereAppTests/ZoomStepsTests -only-testing:SempereAppTests/PhoneStackTests \
      -only-testing:SempereAppTests/PhoneInsertTests -only-testing:SempereAppTests/InsertOptionsTests \
      -only-testing:SempereAppTests/PhoneToolbarTests -only-testing:SempereAppTests/PhonePagelessTests \
      -only-testing:SempereAppTests/PhoneCanvasInteractionTests
    xcb test "${lang[@]}" -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
      -destination "platform=iOS Simulator,id=$sim" CODE_SIGNING_ALLOWED=NO \
      ${only[@]+"${only[@]}"} ${extra[@]+"${extra[@]}"} \
      || { status=$?; shutdown_simulators "$sim"; exit $status; }
    shutdown_simulators "$sim"
    ;;
  test-phone-ui)
    # The iPhone's canvas with a finger (SempereScreenshots scheme, which owns the UI tests): tap selects,
    # hold shows the item's menu, strokes draw, reading mode draws nothing. Needs the iOS Simulator's
    # automation (macOS Automation Mode); the iPad runs of these tests skip.
    sim=$(pick_simulator iPhone)
    settle_simulator "$sim"
    suites -only-testing:SempereAppUITests/PhoneCanvasUITests -only-testing:SempereAppUITests/PhoneParityUITests \
      -only-testing:SempereAppUITests/PhoneReadingScrollUITests -only-testing:SempereAppUITests/PhoneCanvasModeUITests \
      -only-testing:SempereAppUITests/NoteToolbarUITests -only-testing:SempereAppUITests/SearchHighlightUITests
    xcb test "${lang[@]}" -project "$project" -scheme SempereScreenshots -derivedDataPath "$derived" \
      -destination "platform=iOS Simulator,id=$sim" ${only[@]+"${only[@]}"} \
      -parallel-testing-enabled NO ${ui_retry[@]+"${ui_retry[@]}"} CODE_SIGNING_ALLOWED=NO ${extra[@]+"${extra[@]}"} \
      || { status=$?; shutdown_simulators "$sim"; exit $status; }
    shutdown_simulators "$sim"
    ;;
  build-ios)
    # Compile-only check for iOS (scripts/local-ci.sh's gate, the hosted app job on pull requests):
    # the app and its unit tests (SempereApp), then its UI tests (SempereScreenshots), built for the
    # simulator `test` uses so that a later `test` reuses the products. Nothing boots or runs.
    sim=$(pick_simulator)
    for scheme_name in "$scheme" SempereScreenshots; do
      xcodebuild build-for-testing -project "$project" -scheme "$scheme_name" -derivedDataPath "$derived" \
        -destination "platform=iOS Simulator,id=$sim" CODE_SIGNING_ALLOWED=NO ${extra[@]+"${extra[@]}"}
    done
    ;;
  pseudo|pseudo-mac)
    # docs/localization.md "Checking layouts": PseudoLanguageUITests once per language, on the
    # screenshots scheme (it owns the UI test target). Screenshots land in the result bundles.
    # `pseudo`: on an iPad simulator (SEMPERE_PSEUDO_DEVICE=iPhone runs it at phone width).
    # `pseudo-mac`: as the Mac Catalyst app, every screen at each window size in
    # SEMPERE_PSEUDO_MAC_WINDOWS (default: 700 points wide, narrower than an iPad mini in portrait,
    # and 1280 wide). A UI test on the Mac: it takes over the screen.
    if [[ $1 == pseudo-mac ]]; then
      shutdown_simulators
      destination=(-destination 'platform=macOS,variant=Mac Catalyst')
      signing=("${mac_ui_signing[@]}")
      prefix=mac-
      export TEST_RUNNER_SEMPERE_PSEUDO_MAC_WINDOWS=${SEMPERE_PSEUDO_MAC_WINDOWS:-700x800,1280x800}
    else
      sim=$(pick_simulator "${SEMPERE_PSEUDO_DEVICE:-}")
      settle_simulator "$sim"
      destination=(-destination "platform=iOS Simulator,id=$sim")
      signing=(CODE_SIGNING_ALLOWED=NO)
      prefix=
    fi
    status=0
    mkdir -p build/pseudo
    for mode in double rtl es; do
      echo "PSEUDO-TIME $prefix$mode start $(date -u +%H:%M:%S)"
      rm -rf "build/pseudo/$prefix$mode.xcresult"   # xcodebuild refuses to write over an earlier run's bundle
      TEST_RUNNER_SEMPERE_PSEUDO=$mode xcb test -project "$project" -scheme SempereScreenshots \
        -derivedDataPath "$derived" "${destination[@]}" \
        -only-testing:SempereAppUITests/PseudoLanguageUITests -parallel-testing-enabled NO ${ui_retry[@]+"${ui_retry[@]}"} \
        -resultBundlePath "build/pseudo/$prefix$mode.xcresult" "${signing[@]}" ${extra[@]+"${extra[@]}"} || status=$?
      echo "PSEUDO-TIME $prefix$mode end $(date -u +%H:%M:%S) status=$status"
    done
    exit $status
    ;;
  catalyst)
    xcodebuild build -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
      -destination 'platform=macOS,variant=Mac Catalyst' \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
    ;;
  test-mac)
    shutdown_simulators
    tmp_guard_start
    # Ad-hoc signed: a sandboxed Catalyst test host has to be signed to launch.
    suites -only-testing:SempereAppTests
    skip=("${perf_suites[@]}"); $narrowed && skip=()
    xcb test "${lang[@]}" -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
      -destination 'platform=macOS,variant=Mac Catalyst' ${only[@]+"${only[@]}"} ${skip[@]+"${skip[@]}"} \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES ${extra[@]+"${extra[@]}"}
    ;;
  test-mac-perf)
    # Dense-note performance (DensePerformanceTests, docs/ci.md "Performance tests"): open time, scroll and
    # zoom frame hitches and memory on generated notes, against checked-in baselines. Slow (minutes).
    # SEMPERE_PERF_RECORD=1 prints new baselines (pass it as TEST_RUNNER_SEMPERE_PERF_RECORD=1).
    shutdown_simulators
    suites -only-testing:SempereAppTests/DensePerformanceTests
    xcb test "${lang[@]}" -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
      -destination 'platform=macOS,variant=Mac Catalyst' ${only[@]+"${only[@]}"} \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES ${extra[@]+"${extra[@]}"}
    ;;
  test-mac-ui)
    shutdown_simulators
    tmp_guard_start
    # The UI tests live in the SempereScreenshots scheme (never built by `test`).
    suites -only-testing:SempereAppUITests/MacWindowUITests -only-testing:SempereAppUITests/MacItemUITests \
      -only-testing:SempereAppUITests/SidebarDropUITests -only-testing:SempereAppUITests/MacFocusUITests \
      -only-testing:SempereAppUITests/KeyShareMacUITests -only-testing:SempereAppUITests/QuitPurgeMacUITests \
      -only-testing:SempereAppUITests/NewVaultSheetUITests -only-testing:SempereAppUITests/MacImportUITests \
      -only-testing:SempereAppUITests/MacExportUITests -only-testing:SempereAppUITests/MacRealMouseUITests \
      -only-testing:SempereAppUITests/FolderPickerUITests \
      -only-testing:SempereAppUITests/MacNoteModeUITests -only-testing:SempereAppUITests/NoteToolbarUITests
    xcb test -project "$project" -scheme SempereScreenshots -derivedDataPath "$derived" \
      -destination 'platform=macOS,variant=Mac Catalyst' ${only[@]+"${only[@]}"} \
      "${mac_ui_signing[@]}" ${ui_retry[@]+"${ui_retry[@]}"} ${extra[@]+"${extra[@]}"}
    ;;
  test-mac-smoke)
    shutdown_simulators
    tmp_guard_start
    # Fresh-state launches, every column layout, every window and sheet (docs/ci.md).
    suites -only-testing:SempereAppUITests/LaunchSmokeUITests
    xcb test -project "$project" -scheme SempereScreenshots -derivedDataPath "$derived" \
      -destination 'platform=macOS,variant=Mac Catalyst' ${only[@]+"${only[@]}"} \
      "${mac_ui_signing[@]}" ${ui_retry[@]+"${ui_retry[@]}"} ${extra[@]+"${extra[@]}"}
    ;;
  test-ui)
    # The UI tests live in the SempereScreenshots scheme (never built by `test`). The launch smoke
    # tests run here for the iPad's sidebar and list layouts (detail only is the Mac's, `test-mac-smoke`)
    # and for the first-unlock notices (About Your Key, the quick tour).
    sim=$(pick_simulator)
    settle_simulator "$sim"
    suites -only-testing:SempereAppUITests/SidebarDropUITests -only-testing:SempereAppUITests/PadFocusUITests \
      -only-testing:SempereAppUITests/SearchHighlightUITests \
      -only-testing:SempereAppUITests/PaletteButtonUITests \
      -only-testing:SempereAppUITests/LaunchSmokeUITests/testFreshLaunchDefaultLayoutShowsSidebarListAndNote \
      -only-testing:SempereAppUITests/LaunchSmokeUITests/testFreshLaunchDoubleColumn \
      -only-testing:SempereAppUITests/LaunchSmokeUITests/testFirstUnlockShowsKeyNoticeThenTour \
      -only-testing:SempereAppUITests/NewVaultSheetUITests -only-testing:SempereAppUITests/MacImportUITests \
      -only-testing:SempereAppUITests/MacExportUITests -only-testing:SempereAppUITests/FolderPickerUITests \
      -only-testing:SempereAppUITests/PhoneCanvasModeUITests -only-testing:SempereAppUITests/NoteToolbarUITests
    xcb test -project "$project" -scheme SempereScreenshots -derivedDataPath "$derived" \
      -destination "platform=iOS Simulator,id=$sim" ${only[@]+"${only[@]}"} \
      -parallel-testing-enabled NO ${ui_retry[@]+"${ui_retry[@]}"} CODE_SIGNING_ALLOWED=NO ${extra[@]+"${extra[@]}"}
    ;;
  *)
    echo "usage: $0 test|test-phone|test-phone-ui|test-ui|build-ios|pseudo|pseudo-mac|catalyst|test-mac|test-mac-ui|test-mac-smoke|test-mac-perf|simulator" >&2
    exit 2
    ;;
esac
