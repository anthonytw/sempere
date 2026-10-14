#!/usr/bin/env bash
# App Store screenshots from a synthetic demo vault (docs/appstore/screenshots.md).
# Needs Xcode on a Mac. Nothing is uploaded anywhere.
#
#   scripts/screenshots.sh ipad    # iPad Pro 13-inch simulator, 2064x2752 portrait
#   scripts/screenshots.sh iphone  # iPhone Pro Max simulator (6.9"), 1320x2868 portrait
#   scripts/screenshots.sh mac     # Mac Catalyst, composed onto 2880x1800 (best effort)
#   scripts/screenshots.sh         # all three
#
# Output: build/screenshots/ipad/*.png, iphone/*.png and mac/*.png
# (SEMPERE_SHOTS_OUT changes the folder). SEMPERE_SIM_ID picks the simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
project=Apps/Sempere/Sempere.xcodeproj
scheme=SempereScreenshots
derived=${SEMPERE_DERIVED_DATA:-.build/xcode}
out=${SEMPERE_SHOTS_OUT:-build/screenshots}
mkdir -p "$out"
out=$(cd "$out" && pwd)   # the test runner needs an absolute path

pixels() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}'; }

# One simulator family: $1 name (ipad|iphone), $2 simulator name prefix, $3 accepted sizes
# ("2064x2752" or "1320x2868 1290x2796"), $4 status bar flags for the connectivity icons.
simulator_shots() {
  local name=$1 prefix=$2 sizes=$3 sim dir="$out/$1"
  # The newest simulator on iOS 27 or newer: "iPad Pro 13-inch" (2064x2752 pixels) or the newest
  # "iPhone … Pro Max" (6.9": 1320x2868 or 1290x2796 pixels).
  local suffix=
  if [[ $prefix == iPhone* ]]; then suffix="Pro Max"; fi
  sim=$(scripts/app.sh simulator "$prefix" "$suffix")
  rm -rf "$dir"; mkdir -p "$dir"
  xcrun simctl bootstatus "$sim" -b >/dev/null
  # No clutter: 9:41, full battery, full bars, light mode. (The iPad status bar also shows
  # the date, which this does not fix: simctl on Xcode 26.6 refused an ISO date with an offset.)
  if [[ $name == iphone ]]; then
    xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100
  else
    xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode notSupported --batteryState charged --batteryLevel 100
  fi
  xcrun simctl ui "$sim" appearance light
  trap 'xcrun simctl status_bar "$sim" clear || true' RETURN
  local status=0 f bad=0 size ok s
  # A shot that never showed its screen fails the test but still leaves a PNG: keep going to check them all.
  TEST_RUNNER_SEMPERE_SHOTS_DIR="$dir" xcodebuild test -project "$project" -scheme "$scheme" \
    -derivedDataPath "$derived" -destination "platform=iOS Simulator,id=$sim" \
    -only-testing:SempereAppUITests/ScreenshotTests -parallel-testing-enabled NO -resultBundlePath "$out/$name.xcresult" \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$out/$name.log" || status=${PIPESTATUS[0]}
  grep -E "error: |SHOTDEBUG" "$out/$name.log" > "$out/$name-summary.txt" || true
  ls "$dir"/*.png >/dev/null 2>&1 || { echo "error: no screenshots were written" >&2; exit 1; }
  for f in "$dir"/*.png; do
    size=$(pixels "$f"); ok=0
    for s in $sizes; do [[ "$size" == "$s" ]] && ok=1; done
    if [[ $ok == 0 ]]; then echo "error: $f is $size, want one of: $sizes" >&2; bad=1; fi
  done
  [[ $bad == 0 ]] || exit 1
  echo "$name screenshots: $dir"
  return $status
}

ipad() { simulator_shots ipad "iPad Pro 13-inch" "2064x2752"; }
# 6.9" is the iPhone size App Store Connect scales the other iPhone sizes from.
iphone() { simulator_shots iphone "iPhone" "1320x2868 1290x2796"; }

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
# and centre it on a plain 2880x1800 canvas (App Store Connect takes only exact sizes).
mac() {
  local dir="$out/mac" raw="$out/mac-raw" status=0
  rm -rf "$dir" "$raw"; mkdir -p "$dir" "$raw"
  TEST_RUNNER_SEMPERE_SHOTS_DIR="$raw" xcodebuild test -project "$project" -scheme "$scheme" \
    -derivedDataPath "$derived" -destination 'platform=macOS,variant=Mac Catalyst' \
    -only-testing:SempereAppUITests/ScreenshotTests -resultBundlePath "$out/mac.xcresult" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES 2>&1 | tee "$out/mac.log" || status=${PIPESTATUS[0]}
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

case "${1:-all}" in
  ipad) ipad ;;
  iphone) iphone ;;
  mac) mac ;;
  all) ipad; iphone; mac ;;
  *) echo "usage: $0 [ipad|iphone|mac|all]" >&2; exit 2 ;;
esac
