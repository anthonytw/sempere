#!/usr/bin/env bash
# Test of scripts/screenshots.sh's own logic (docs/design/1.2-screenshots.md §4) with a fake xcrun, xcodebuild and sips on
# PATH: no simulator, no Xcode, nothing is built. A dark run sets the dark appearance, names its folder and exports the
# variables; a light run is the default; a size that is not the target's fails; a watch run takes the first shot's size.
set -euo pipefail
cd "$(dirname "$0")/.."
script=$PWD/scripts/screenshots.sh
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir "$t/bin"
# xcrun: logs its arguments ("simctl ui SIM appearance dark"); bootstatus and status_bar do nothing.
cat > "$t/bin/xcrun" <<'FAKE'
#!/usr/bin/env bash
echo "xcrun $*" >> "$FAKE_LOG"
FAKE
# xcodebuild: logs the destination, scheme, test selection and the variables the script exports; writes the PNGs
# (a "WxH" text file each, which the fake sips reads) into the folder the script named.
cat > "$t/bin/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
echo "xcodebuild $*" >> "$FAKE_LOG"
echo "env dir=$TEST_RUNNER_SEMPERE_SHOTS_DIR appearance=$TEST_RUNNER_SEMPERE_SHOTS_APPEARANCE" >> "$FAKE_LOG"
mkdir -p "$TEST_RUNNER_SEMPERE_SHOTS_DIR"
n=0
for size in ${FAKE_SIZES:-2064x2752}; do
  n=$((n + 1)); echo "$size" > "$TEST_RUNNER_SEMPERE_SHOTS_DIR/0$n-shot.png"
done
FAKE
cat > "$t/bin/sips" <<'FAKE'
#!/usr/bin/env bash
# sips -g pixelWidth -g pixelHeight FILE
f=${@: -1}; size=$(cat "$f"); w=${size%x*}; h=${size#*x}
echo "$f"; echo "  pixelWidth: $w"; echo "  pixelHeight: $h"
FAKE
chmod +x "$t/bin/xcrun" "$t/bin/xcodebuild" "$t/bin/sips"
export PATH="$t/bin:$PATH" FAKE_LOG="$t/log" SEMPERE_SIM_ID=FAKE-SIM SEMPERE_SHOTS_OUT="$t/out"
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
run() { : > "$FAKE_LOG"; rm -rf "$t/out"; set +e; out=$("$script" "$@" 2>&1); status=$?; set -e; }

run docs-ipad
check "a light run passes" '[[ $status -eq 0 ]]'
check "light is the default appearance" 'grep -q "simctl ui FAKE-SIM appearance light" "$FAKE_LOG"'
check "a light run writes docs-ipad/" '[[ -f "$t/out/docs-ipad/01-shot.png" && ! -d "$t/out/docs-ipad-dark" ]]'
check "a light run exports appearance=light" 'grep -q "appearance=light" "$FAKE_LOG"'
check "it runs the guide's tests" 'grep -q "only-testing:SempereAppUITests/DocsScreenshotTests" "$FAKE_LOG"'

check "a simulator not in English is set to English and rebooted" \
  'grep -q "defaults write -g AppleLanguages -array en" "$FAKE_LOG" && grep -q "simctl shutdown FAKE-SIM" "$FAKE_LOG" && grep -q "simctl boot FAKE-SIM" "$FAKE_LOG"'

SEMPERE_SHOTS_APPEARANCE=dark run docs-ipad
check "a dark run passes" '[[ $status -eq 0 ]]'
check "a dark run sets the simulator dark" 'grep -q "simctl ui FAKE-SIM appearance dark" "$FAKE_LOG" && ! grep -q "appearance light" "$FAKE_LOG"'
check "a dark run writes docs-ipad-dark/ and keeps nothing in docs-ipad/" '[[ -f "$t/out/docs-ipad-dark/01-shot.png" && ! -d "$t/out/docs-ipad" ]]'
check "a dark run exports appearance=dark and the dark folder" 'grep -q "appearance=dark" "$FAKE_LOG" && grep -q "dir=$t/out/docs-ipad-dark " "$FAKE_LOG"'
check "a dark run names its own result bundle and log" 'grep -q "resultBundlePath $t/out/docs-ipad-dark.xcresult" "$FAKE_LOG" && [[ -f "$t/out/docs-ipad-dark.log" ]]'
check "the status bar override is the same in dark" 'grep -q "status_bar FAKE-SIM override --time 9:41" "$FAKE_LOG"'

SEMPERE_SHOTS_APPEARANCE=dark run docs-iphone
check "a dark iPhone run checks the iPhone sizes" '[[ $status -ne 0 && $out == *"is 2064x2752, want one of: 1320x2868 1290x2796"* ]]'

SEMPERE_SHOTS_APPEARANCE=dark FAKE_SIZES="1320x2868" run docs-iphone
check "a dark iPhone run with the right size passes" '[[ $status -eq 0 && -f "$t/out/docs-iphone-dark/01-shot.png" ]]'

FAKE_SIZES="2064x2752 2048x2732" run ipad
check "a size mismatch fails the run" '[[ $status -ne 0 && $out == *"02-shot.png is 2048x2732, want one of: 2064x2752"* ]]'

SEMPERE_SHOTS_APPEARANCE=dark run ipad
check "dark is refused for a store target" '[[ $status -eq 2 && $out == *"docs-* targets"* ]] && ! grep -q xcodebuild "$FAKE_LOG"'

SEMPERE_SHOTS_APPEARANCE=sepia run docs-ipad
check "an unknown appearance is refused" '[[ $status -eq 2 && $out == *"want light or dark"* ]]'

FAKE_SIZES="410x502 410x502" run docs-watch
check "a watch run uses the watch scheme, bundle and platform" \
  'grep -q "scheme SempereWatch " "$FAKE_LOG" && grep -q "only-testing:SempereWatchUITests/WatchScreenshotTests" "$FAKE_LOG" && grep -q "platform=watchOS Simulator,id=FAKE-SIM" "$FAKE_LOG"'
check "a watch run sets no appearance (a watchOS runtime has none)" '! grep -q "simctl ui" "$FAKE_LOG"'
check "a watch run takes the first shot's size" '[[ $status -eq 0 && -f "$t/out/docs-watch/02-shot.png" ]]'
FAKE_SIZES="410x502 396x484" run docs-watch
check "a watch shot of another size than the first fails" '[[ $status -ne 0 && $out == *"02-shot.png is 396x484, want one of: 410x502"* ]]'

run bogus
check "an unknown target prints the usage" '[[ $status -eq 2 && $out == *"docs-watch"* ]]'
exit $fail
