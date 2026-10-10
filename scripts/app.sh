#!/usr/bin/env bash
# Build and test the iPad/Mac app (Apps/Sempere). Needs Xcode; macOS only.
#
#   scripts/app.sh test       # xcodebuild test on an iPad simulator
#   scripts/app.sh test-phone # the iPhone suites (PhoneLayoutTests) on an iPhone simulator
#   scripts/app.sh catalyst   # Mac Catalyst build, unsigned
#   scripts/app.sh pseudo     # layout check in the double-length, right-to-left and Spanish languages
#   scripts/app.sh test-mac   # every app suite on Mac Catalyst, ad-hoc signed and sandboxed
#   scripts/app.sh test-mac-ui # the Mac UI tests (MacWindowUITests, SidebarDropUITests) on Mac Catalyst
#   scripts/app.sh test-ui    # the iPad UI tests (SidebarDropUITests: real drags; the launch smoke tests) on an iPad simulator
#   scripts/app.sh test-mac-smoke # the launch smoke tests (LaunchSmokeUITests: fresh state, every layout and window) on Mac Catalyst
#   scripts/app.sh simulator [PREFIX [SUFFIX]] # print the simulator id `test` would use (or one named PREFIX…SUFFIX)
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
if [[ "${CI:-}" != true && "${SEMPERE_MAC_UI_SIGNING:-}" != ci ]]; then
  mac_ui_signing+=(ENABLE_HARDENED_RUNTIME=NO)
fi

# The newest available simulator whose name starts with $1 (iPad or iPhone, default iPad) and, when
# $2 is given, ends with it ("Pro Max"), on the newest iOS runtime. SEMPERE_SIM_ID overrides it.
pick_simulator() {
  local family=${1:-iPad}
  if [[ -n "${SEMPERE_SIM_ID:-}" ]]; then echo "$SEMPERE_SIM_ID"; return; fi
  xcrun simctl list devices available --json | /usr/bin/python3 -c '
import json, re, sys
family, suffix = sys.argv[1], sys.argv[2]
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, devs in devices.items():
    m = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    if version < (27, 0):  # the app targets iPadOS 27 and iOS 27
        continue
    for d in devs:
        if d.get("isAvailable") and d["name"].startswith(family) and d["name"].endswith(suffix):
            key = (version, d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"], d["name"], version)
if best is None:
    sys.exit("no available " + family + " simulator on iOS 27 or newer (xcrun simctl list runtimes; xcodebuild -downloadPlatform iOS)")
print(f"using {best[2]} (iOS {best[3][0]}.{best[3][1]})", file=sys.stderr)
print(best[1])
' "$family" "${2:-}"
}

case "${1:-}" in
  simulator)
    pick_simulator "${2:-}" "${3:-}"
    ;;
  test)
    sim=$(pick_simulator)
    xcodebuild test "${lang[@]}" -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
      -destination "platform=iOS Simulator,id=$sim" CODE_SIGNING_ALLOWED=NO
    ;;
  test-phone)
    # Same build products as `test` (the simulator SDK is shared), so after it this only runs the suites.
    sim=$(pick_simulator iPhone)
    xcodebuild test "${lang[@]}" -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
      -destination "platform=iOS Simulator,id=$sim" CODE_SIGNING_ALLOWED=NO \
      -only-testing:SempereAppTests/CompactNavigationTests -only-testing:SempereAppTests/CompactBackTests \
      -only-testing:SempereAppTests/PhoneReadingTests \
      -only-testing:SempereAppTests/PhoneCanvasTests -only-testing:SempereAppTests/PhoneRootTests \
      -only-testing:SempereAppTests/ZoomStepsTests -only-testing:SempereAppTests/PhoneStackTests \
      -only-testing:SempereAppTests/PhoneInsertTests -only-testing:SempereAppTests/InsertOptionsTests \
      -only-testing:SempereAppTests/PhoneToolbarTests -only-testing:SempereAppTests/PhonePagelessTests
    ;;
  pseudo)
    # docs/localization.md "Checking layouts": PseudoLanguageUITests once per language, on the
    # screenshots scheme (it owns the UI test target). Screenshots land in the result bundles.
    # SEMPERE_PSEUDO_DEVICE=iPhone runs it at phone width (default: an iPad).
    sim=$(pick_simulator ${SEMPERE_PSEUDO_DEVICE:-})
    status=0
    mkdir -p build/pseudo
    for mode in double rtl es; do
      echo "PSEUDO-TIME $mode start $(date -u +%H:%M:%S)"
      TEST_RUNNER_SEMPERE_PSEUDO=$mode xcodebuild test -project "$project" -scheme SempereScreenshots \
        -derivedDataPath "$derived" -destination "platform=iOS Simulator,id=$sim" \
        -only-testing:SempereAppUITests/PseudoLanguageUITests -parallel-testing-enabled NO \
        -resultBundlePath "build/pseudo/$mode.xcresult" CODE_SIGNING_ALLOWED=NO || status=$?
      echo "PSEUDO-TIME $mode end $(date -u +%H:%M:%S) status=$status"
    done
    exit $status
    ;;
  catalyst)
    xcodebuild build -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
      -destination 'platform=macOS,variant=Mac Catalyst' \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
    ;;
  test-mac)
    # Ad-hoc signed: a sandboxed Catalyst test host has to be signed to launch.
    xcodebuild test "${lang[@]}" -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
      -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:SempereAppTests \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
    ;;
  test-mac-ui)
    # The UI tests live in the SempereScreenshots scheme (never built by `test`).
    xcodebuild test -project "$project" -scheme SempereScreenshots -derivedDataPath "$derived" \
      -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:SempereAppUITests/MacWindowUITests \
      -only-testing:SempereAppUITests/SidebarDropUITests "${mac_ui_signing[@]}"
    ;;
  test-mac-smoke)
    # Fresh-state launches, every column layout, every window and sheet (docs/HANDOFF.md "CI").
    xcodebuild test -project "$project" -scheme SempereScreenshots -derivedDataPath "$derived" \
      -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:SempereAppUITests/LaunchSmokeUITests \
      "${mac_ui_signing[@]}"
    ;;
  test-ui)
    # The UI tests live in the SempereScreenshots scheme (never built by `test`). The launch smoke
    # tests run here for the iPad's sidebar and list layouts (detail only is the Mac's, `test-mac-smoke`)
    # and for the first-unlock notices (About Your Key, the quick tour).
    sim=$(pick_simulator)
    xcodebuild test -project "$project" -scheme SempereScreenshots -derivedDataPath "$derived" \
      -destination "platform=iOS Simulator,id=$sim" -only-testing:SempereAppUITests/SidebarDropUITests \
      -only-testing:SempereAppUITests/LaunchSmokeUITests/testFreshLaunchDefaultLayoutShowsSidebarListAndNote \
      -only-testing:SempereAppUITests/LaunchSmokeUITests/testFreshLaunchDoubleColumn \
      -only-testing:SempereAppUITests/LaunchSmokeUITests/testFirstUnlockShowsKeyNoticeThenTour \
      -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
    ;;
  *)
    echo "usage: $0 test|test-phone|test-ui|pseudo|catalyst|test-mac|test-mac-ui|test-mac-smoke|simulator" >&2
    exit 2
    ;;
esac
