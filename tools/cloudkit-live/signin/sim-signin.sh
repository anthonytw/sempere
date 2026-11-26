#!/bin/bash
# Signs the `sempere-cloudkit` simulator in to the CloudKit test Apple ID again (its sign-in expires about daily: cloudd logs
# AuthTokenError 2011). Runs the UI test CloudKitSimSignInUITests (Apps/Sempere/SempereAppUITests), which drives Settings.
# Called by tools/cloudkit-live/run.sh (`sim-signin`, and by itself before the simulator leg when the account fails);
# `scripts/app.sh cloudkit-sim-signin` is the entry point (run it through xc-lock). docs/io.md "Testing it against the real database".
#
# The Apple ID and its password come from the login keychain (never a file, a command line or the repository):
#   security find-generic-password -a sempere-test -s sempere-test-apple-id-email -w
#   security find-generic-password -a sempere-test -s sempere-test-apple-id -w      (SEMPERE_CKL_PW_SERVICE overrides the service)
# and reach the test only through the environment (xcodebuild forwards TEST_RUNNER_* variables to the test runner). The variable
# is exported in a subshell only, but it does spread to that subshell's children (app.sh, xcodebuild, the test runner): a process
# of this user can read it with `ps eww` while the run lasts. Nothing is written to a file or kept.
# The simulator's log files are removed afterwards (see below). One wrong password is never repeated: the test stops at the first refusal and this script writes a marker (~/.cache/sempere/,
# keyed to the keychain item's modification date); later runs refuse (exit 4) until the item is changed.
# Exit codes: 0 signed in; 3 two-factor code requested (never answered; needs a code from the account's trusted device);
# 4 the password was refused (now or in an earlier run, until the keychain item changes); 1 other failure; 77 no keychain items (skipped).
set +x
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$repo"
here=$(cd "$(dirname "$0")" && pwd)
# A TMPDIR of this run's own (scripts/run-tmp.sh), removed at exit; never kept.
unset SEMPERE_RUN_TMP_KEEP
# shellcheck disable=SC1091
source scripts/run-tmp.sh
# shellcheck disable=SC1091
source "$here/lock.sh"

pw_service=${SEMPERE_CKL_PW_SERVICE:-sempere-test-apple-id}
sim=${SEMPERE_CLOUDKIT_SIM:-$(xcrun simctl list devices | sed -n 's/^ *sempere-cloudkit (\([0-9A-F-]\{36\}\)).*/\1/p' | head -1)}
[[ -n $sim ]] || { echo "SKIPPED sim-signin: no simulator named sempere-cloudkit" >&2; exit 77; }
email=$(security find-generic-password -a sempere-test -s sempere-test-apple-id-email -w 2>/dev/null || true)
[[ -n $email ]] || { echo "SKIPPED sim-signin: no keychain item sempere-test-apple-id-email (account sempere-test)" >&2; exit 77; }
item=$(security find-generic-password -a sempere-test -s "$pw_service" 2>/dev/null) \
  || { echo "SKIPPED sim-signin: no keychain item $pw_service (account sempere-test)" >&2; exit 77; }
mdat=$(sed -n 's/^ *"mdat"<timedate>=[^"]*"\(.*\)\\000".*/\1/p' <<<"$item" | head -1)
marker=$HOME/.cache/sempere/sim-signin-refused-$pw_service
if [[ -f $marker && $(<"$marker") == "$mdat" ]]; then
  echo "sim-signin: Apple refused this password in an earlier run; not trying again. Fix the keychain item $pw_service (account sempere-test), which clears this." >&2
  exit 4
fi

cleanup() { rm -rf "${rb_dir:-}"; rm -f "${log:-}"; run_tmp_end; }
trap cleanup EXIT
sim_lock || exit 1
rb_dir=$(mktemp -d "${TMPDIR:-/tmp}/signin-rb.XXXXXX")   # the result bundle: this run's own, removed above, never the shared Logs/Test
log=$rb_dir/xcodebuild.log
rc=0
pw=$(security find-generic-password -a sempere-test -s "$pw_service" -w)   # a shell variable, not exported
# Two steps, so the password is in the environment only for the second: xcodebuild saves its whole environment in the derived data
# (XCBuildData/…/attachments), which a build with the variable set would keep for good. The build gets none of it; the test run
# (test-without-building, one attempt: no rerun of a refused password) gets it.
derived=${SEMPERE_DERIVED_DATA:-.build/xcode.noindex}
xb=(-project Apps/Sempere/Sempere.xcodeproj -scheme SempereScreenshots -derivedDataPath "$derived" -destination "platform=iOS Simulator,id=$sim")
(
  unset TEST_RUNNER_CKL_SIGNIN_PASSWORD TEST_RUNNER_CKL_SIGNIN_EMAIL SEMPERE_RESULT_BUNDLE
  xcodebuild build-for-testing "${xb[@]}" CODE_SIGNING_ALLOWED=NO
) >"$log" 2>&1 || rc=$?
if [[ $rc -eq 0 ]]; then
  (
    export TEST_RUNNER_CKL_SIGNIN_EMAIL=$email TEST_RUNNER_CKL_SIGNIN_PASSWORD=$pw
    unset SEMPERE_RESULT_BUNDLE
    xcodebuild test-without-building "${xb[@]}" -testLanguage en -testRegion US -parallel-testing-enabled NO \
      -only-testing:SempereAppUITests/CloudKitSimSignInUITests -resultBundlePath "$rb_dir/signin.xcresult" CODE_SIGNING_ALLOWED=NO
  ) >>"$log" 2>&1 || rc=$?
fi
# Scrub: nothing of the log may hold the password (bash's own match: the password is never an argument of a process).
if [[ $(<"$log") == *"$pw"* ]]; then echo "error: the password appears in the xcodebuild log; log withheld" >&2; pw=""; exit 1; fi
pw=""
grep -E "SIGNIN-|Test Case .*CloudKitSimSignIn|error:|\*\* TEST|needs a code|Executed" "$log" | tail -25 | while IFS= read -r line; do echo "${line//"$email"/<apple-id>}"; done || true
# The UI-test runner stays installed in the base simulator (clones would copy it): remove it.
xcrun simctl boot "$sim" >/dev/null 2>&1 || true
for app in $(xcrun simctl listapps "$sim" 2>/dev/null | grep -o '"[^"]*\.xctrunner"' | tr -d '"'); do xcrun simctl uninstall "$sim" "$app" >/dev/null 2>&1 || true; done
xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true
# The simulator's own unified log keeps the test runner's launch environment (the password included) and every clone would copy it:
# with the simulator shut down, drop its log files (only the *.tracev3 of its diagnostics store; logd makes new ones; `log erase`
# is refused inside a simulator). Verified with a canary password: nothing else on this Mac held it.
find "$HOME/Library/Developer/CoreSimulator/Devices/$sim/data/var/db/diagnostics" -name '*.tracev3' -delete 2>/dev/null || true
sim_unlock
if grep -q "SIGNIN-REFUSED" "$log"; then
  mkdir -p "$(dirname "$marker")"; printf '%s' "$mdat" > "$marker"
  echo "sim-signin: Apple refused the password; no retry (marker $marker). Fix the keychain item $pw_service." >&2
  exit 4
fi
if [[ $rc -ne 0 ]]; then
  grep -q "two-factor" "$log" && { echo "sim-signin: needs a code sent to the account's trusted device (two-factor); the simulator is left signed out" >&2; exit 3; }
  exit 1
fi
grep -q "SIGNIN-OK" "$log" || { echo "sim-signin: the test passed but did not report a sign-in" >&2; exit 1; }
