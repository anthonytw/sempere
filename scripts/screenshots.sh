#!/usr/bin/env bash
# App Store screenshots from a synthetic demo vault (docs/appstore/screenshots.md).
# Needs Xcode on a Mac. Nothing is uploaded anywhere.
#
#   scripts/screenshots.sh ipad    # iPad Pro 13-inch simulator, 2064x2752 portrait
#   scripts/screenshots.sh iphone  # iPhone Pro Max simulator (6.9"), 1320x2868 portrait
#   scripts/screenshots.sh mac     # Mac Catalyst, composed onto 2880x1800 (best effort)
#   scripts/screenshots.sh         # all three
#   scripts/screenshots.sh docs-ipad|docs-iphone   # the website's user-guide shots (DocsScreenshotTests)
#   scripts/screenshots.sh docs-watch              # the Watch page's shots (WatchScreenshotTests, a watchOS simulator)
#
# Output: build/screenshots/ipad/*.png, iphone/*.png and mac/*.png
# (SEMPERE_SHOTS_OUT changes the folder). SEMPERE_SIM_ID picks the simulator.
# SEMPERE_SHOTS_APPEARANCE=dark (default light) takes the website's guide shots in dark mode: the simulator is set to
# dark, the demo's windows are forced dark (SEMPERE_DEMO_APPEARANCE) and the PNGs go to <name>-dark/ (docs-ipad-dark/).
# Only the docs-* targets have a dark twin (the store takes one set per size).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/run-tmp.sh   # a TMPDIR of this run's own, removed at exit
project=Apps/Sempere/Sempere.xcodeproj
scheme=SempereScreenshots
derived=${SEMPERE_DERIVED_DATA:-.build/xcode.noindex}
out=${SEMPERE_SHOTS_OUT:-build/screenshots}
mkdir -p "$out"
out=$(cd "$out" && pwd)   # the test runner needs an absolute path
appearance=${SEMPERE_SHOTS_APPEARANCE:-light}
case "$appearance" in
  light|dark) ;;
  *) echo "error: SEMPERE_SHOTS_APPEARANCE is '$appearance', want light or dark" >&2; exit 2 ;;
esac
# A dark run's files and folders carry the suffix, so a light run's are kept.
suffix_dark=; [[ $appearance == dark ]] && suffix_dark=-dark

pixels() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}'; }

# One simulator family: $1 name (ipad|iphone|docs-ipad|docs-iphone|docs-watch), $2 simulator name prefix, $3 accepted
# sizes ("2064x2752" or "1320x2868 1290x2796"; "first": whatever the first PNG is, for a watch, whose size is the
# chosen watch's), $4 the UI test class (default ScreenshotTests), $5 the scheme, $6 the test bundle, $7 the platform.
simulator_shots() {
  local name=$1 prefix=$2 sizes=$3 tests=${4:-ScreenshotTests} scheme=${5:-$scheme} bundle=${6:-SempereAppUITests}
  local platform=${7:-iOS} sim
  local shots_name="$1$suffix_dark" dir="$out/$1$suffix_dark"
  # The newest simulator on iOS 27 or newer: "iPad Pro 13-inch" (2064x2752 pixels) or the newest
  # "iPhone … Pro Max" (6.9": 1320x2868 or 1290x2796 pixels); "Watch": the newest watchOS runtime's biggest watch.
  local suffix=
  if [[ $prefix == iPhone* ]]; then suffix="Pro Max"; fi
  sim=$(scripts/app.sh simulator "$prefix" "$suffix")
  # xcodebuild refuses an existing result bundle: a second run into the same folder failed at once.
  rm -rf "$dir" "$out/$shots_name.xcresult"; mkdir -p "$dir"
  xcrun simctl bootstatus "$sim" -b >/dev/null
  # English, whatever the simulator was made with: the status bar's date follows the simulator's language, not the
  # app's (a Spanish simulator showed "Sáb nov 14"). A changed language needs a reboot of the simulator.
  if [[ $(xcrun simctl spawn "$sim" defaults read -g AppleLanguages 2>/dev/null | tr -d ' \n()"') != en* ]]; then
    xcrun simctl spawn "$sim" defaults write -g AppleLanguages -array en
    xcrun simctl spawn "$sim" defaults write -g AppleLocale en_US
    xcrun simctl shutdown "$sim"
    xcrun simctl boot "$sim"
    xcrun simctl bootstatus "$sim" -b >/dev/null
  fi
  # No clutter: 9:41, full battery, full bars, and the appearance asked for (light by default). (The iPad status bar
  # also shows the date, which this does not fix: simctl on Xcode 26.6 refused an ISO date with an offset. A watch has
  # no status bar to set.)
  if [[ $platform == watchOS ]]; then
    :
  elif [[ $name == *iphone ]]; then
    xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100
  else
    xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode notSupported --batteryState charged --batteryLevel 100
  fi
  # (A watchOS runtime has no appearance to set: the watch is dark either way.)
  if [[ $platform != watchOS ]]; then xcrun simctl ui "$sim" appearance "$appearance"; fi
  # The trap removes itself: left set, it fired again when the caller (ipad, iphone) returned, where `sim`
  # is unset, and `set -u` made the script exit 1 after a successful run.
  trap 'xcrun simctl status_bar "$sim" clear || true; trap - RETURN' RETURN
  local status=0 f bad=0 size ok s
  # A shot that never showed its screen fails the test but still leaves a PNG: keep going to check them all.
  TEST_RUNNER_SEMPERE_SHOTS_DIR="$dir" TEST_RUNNER_SEMPERE_SHOTS_APPEARANCE="$appearance" \
    xcodebuild test -project "$project" -scheme "$scheme" \
    -derivedDataPath "$derived" -destination "platform=$platform Simulator,id=$sim" \
    -only-testing:"$bundle/$tests" -parallel-testing-enabled NO -resultBundlePath "$out/$shots_name.xcresult" \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$out/$shots_name.log" || status=${PIPESTATUS[0]}
  grep -E "error: |SHOTDEBUG" "$out/$shots_name.log" > "$out/$shots_name-summary.txt" || true
  # A watch test runner may not be able to write into the checkout: take the shots from the result bundle then.
  if [[ $platform == watchOS ]] && ! ls "$dir"/*.png >/dev/null 2>&1; then
    export_attachments "$out/$shots_name.xcresult" "$dir"
  fi
  ls "$dir"/*.png >/dev/null 2>&1 || { echo "error: no screenshots were written" >&2; exit 1; }
  if [[ $sizes == first ]]; then sizes=$(pixels "$(ls "$dir"/*.png | head -1)"); fi
  for f in "$dir"/*.png; do
    size=$(pixels "$f"); ok=0
    for s in $sizes; do [[ "$size" == "$s" ]] && ok=1; done
    if [[ $ok == 0 ]]; then echo "error: $f is $size, want one of: $sizes" >&2; bad=1; fi
  done
  [[ $bad == 0 ]] || exit 1
  echo "$shots_name screenshots: $dir"
  return $status
}

ipad() { simulator_shots ipad "iPad Pro 13-inch" "2064x2752"; }
# 6.9" is the iPhone size App Store Connect scales the other iPhone sizes from.
iphone() { simulator_shots iphone "iPhone" "1320x2868 1290x2796"; }
# The website's user-guide shots (DocsScreenshotTests), portrait.
docs_ipad() { simulator_shots docs-ipad "iPad Pro 13-inch" "2064x2752" DocsScreenshotTests; }
docs_iphone() { simulator_shots docs-iphone "iPhone" "1320x2868 1290x2796" DocsScreenshotTests; }
# The Watch page's shots (WatchScreenshotTests in SempereWatchUITests), at the chosen watch's native size.
docs_watch() { simulator_shots docs-watch "Watch" first WatchScreenshotTests SempereWatch SempereWatchUITests watchOS; }

# Copies the screenshot attachments of a result bundle to DIR as <shot name>.png.
export_attachments() {
  local bundle=$1 dest=$2 tmp
  tmp=$(mktemp -d)
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$tmp"
  /usr/bin/python3 - "$tmp" "$dest" <<'PY'
import json, os, shutil, subprocess, sys
src, dest = sys.argv[1:3]
for test in json.load(open(os.path.join(src, "manifest.json"))):
    for a in test.get("attachments", []):
        name = a["suggestedHumanReadableName"].split("_")[0]
        if not name[:2].isdigit():
            continue
        path = os.path.join(src, a["exportedFileName"])
        out = os.path.join(dest, name + ".png")
        if path.lower().endswith(".png"):
            shutil.copy(path, out)
        else:
            subprocess.check_call(["sips", "-s", "format", "png", path, "--out", out], stdout=subprocess.DEVNULL)
PY
  rm -rf "$tmp"
}

# A Mac window shot has whatever size the window and the display give; scale it to fit
# and center it on a plain 2880x1800 canvas (App Store Connect takes only exact sizes).
mac() {
  local dir="$out/mac" raw="$out/mac-raw" status=0 hardened=()
  # As scripts/app.sh's Mac UI runs: off CI the ad-hoc UI-test runner refuses its own test bundle on a Mac with a
  # developer identity ("different Team IDs") unless the hardened runtime is off. SEMPERE_MAC_UI_SIGNING=ci keeps CI's.
  if [[ "${CI:-}" != true && "${SEMPERE_MAC_UI_SIGNING:-}" != ci ]]; then hardened=(ENABLE_HARDENED_RUNTIME=NO); fi
  # xcodebuild refuses an existing result bundle (as in simulator_shots): a second run failed at once.
  rm -rf "$dir" "$raw" "$out/mac.xcresult"
  mkdir -p "$dir" "$raw"
  TEST_RUNNER_SEMPERE_SHOTS_DIR="$raw" xcodebuild test -project "$project" -scheme "$scheme" \
    -derivedDataPath "$derived" -destination 'platform=macOS,variant=Mac Catalyst' \
    -only-testing:SempereAppUITests/ScreenshotTests -resultBundlePath "$out/mac.xcresult" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGN_ENTITLEMENTS="$PWD/Apps/Sempere/SempereAdHoc.entitlements" ${hardened[@]+"${hardened[@]}"} 2>&1 | tee "$out/mac.log" || status=${PIPESTATUS[0]}
  grep -E "error: |SHOTDEBUG" "$out/mac.log" > "$out/mac-summary.txt" || true
  # The Mac test runner is sandboxed and cannot write into the checkout: take the shots
  # from the result bundle's attachments instead.
  if ! ls "$raw"/*.png >/dev/null 2>&1; then
    export_attachments "$out/mac.xcresult" "$raw"
  fi
  ls "$raw"/*.png >/dev/null 2>&1 || { echo "error: no screenshots were found" >&2; exit 1; }
  local f size w h scaled
  for f in "$raw"/*.png; do
    size=$(pixels "$f"); w=${size%x*}; h=${size#*x}
    scaled=$(/usr/bin/python3 -c "
w, h = $w, $h
f = min(2560 / w, 1600 / h)
print(round(h * f), round(w * f))")
    cp "$f" "$dir/$(basename "$f")"
    sips -z $scaled "$dir/$(basename "$f")" >/dev/null
    sips --padToHeightWidth 1800 2880 --padColor E9E6DF "$dir/$(basename "$f")" >/dev/null
    [[ "$(pixels "$dir/$(basename "$f")")" == 2880x1800 ]] || { echo "error: $f did not end up 2880x1800" >&2; exit 1; }
  done
  echo "Mac screenshots: $dir"
  return $status
}

target=${1:-all}
if [[ $appearance == dark && $target != docs-* ]]; then
  echo "error: SEMPERE_SHOTS_APPEARANCE=dark is for the docs-* targets (the store takes one set per size)" >&2
  exit 2
fi
case "$target" in
  ipad) ipad ;;
  iphone) iphone ;;
  mac) mac ;;
  all) ipad; iphone; mac ;;
  docs-ipad) docs_ipad ;;
  docs-iphone) docs_iphone ;;
  docs-watch) docs_watch ;;
  *) echo "usage: $0 [ipad|iphone|mac|all|docs-ipad|docs-iphone|docs-watch]" >&2; exit 2 ;;
esac
