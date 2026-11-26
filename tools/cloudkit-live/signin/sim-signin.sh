#!/bin/bash
# Signs the `sempere-cloudkit` simulator in to the CloudKit test Apple ID again (its sign-in expires about daily: cloudd logs
# AuthTokenError 2011). Runs the UI test CloudKitSimSignInUITests (Apps/Sempere/SempereAppUITests), which drives Settings.
# Called by tools/cloudkit-live/run.sh (`sim-signin`, and by itself before the simulator leg when the account fails);
# `scripts/app.sh cloudkit-sim-signin` is the entry point (run it through xc-lock). docs/io.md "Testing it against the real database".
#
# The Apple ID and its password come from the login keychain (never a file, a command line or the repository):
#   security find-generic-password -a sempere-test -s sempere-test-apple-id-email -w
#   security find-generic-password -a sempere-test -s sempere-test-apple-id -w      (SEMPERE_CKL_PW_SERVICE overrides the service)
# and reach the test through a 0600 file in the run's own TMPDIR (line 1 the Apple ID, the rest the password; made with shell builtins,
# never an argument). Only its path is in the environment (TEST_RUNNER_CKL_SIGNIN_FILE; xcodebuild forwards TEST_RUNNER_* to the
# test runner, which, as a simulator process, reads the host path). The test deletes the file as soon as it has read it, and the
# trap deletes it again, so `ps eww`, the xcodebuild log, the derived data and the simulator's log carry a path, no secret.
# The simulator's log files are removed afterwards (see below). One wrong password is never repeated: the test stops at the first refusal and this script writes a marker (~/.cache/sempere/,
# keyed to the keychain item's modification date); later runs refuse (exit 4) until the item is changed.
# Exit codes: 0 signed in; 3 two-factor code requested (never answered; needs a code from the account's trusted device);
# 4 the password was tried and did not end in a sign-in (now or in an earlier run; until the keychain item changes); 1 other failure; 77 no keychain items (skipped).
set +x
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$repo"
here=$(cd "$(dirname "$0")" && pwd)
# A TMPDIR of this run's own, always: never the caller's (an outer SEMPERE_RUN_TMP_KEEP must not keep what xcodebuild stages in it).
unset SEMPERE_RUN_TMP SEMPERE_RUN_TMP_OWNER SEMPERE_RUN_TMP_KEEP
# shellcheck disable=SC1091
source scripts/run-tmp.sh
# shellcheck disable=SC1091
source "$here/lock.sh"

pw_service=${SEMPERE_CKL_PW_SERVICE:-sempere-test-apple-id}
sim=${SEMPERE_CLOUDKIT_SIM:-$(xcrun simctl list devices | sed -n 's/^ *sempere-cloudkit (\([0-9A-F-]\{36\}\)).*/\1/p' | head -1)}
[[ -n $sim ]] || { echo "SKIPPED sim-signin: no simulator named sempere-cloudkit" >&2; exit 77; }
[[ $sim =~ ^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$ ]] || { echo "error: sim-signin: $sim is not a simulator UUID" >&2; exit 1; }
email=$(security find-generic-password -a sempere-test -s sempere-test-apple-id-email -w 2>/dev/null || true)
[[ -n $email ]] || { echo "SKIPPED sim-signin: no keychain item sempere-test-apple-id-email (account sempere-test)" >&2; exit 77; }
item=$(security find-generic-password -a sempere-test -s "$pw_service" 2>/dev/null) \
  || { echo "SKIPPED sim-signin: no keychain item $pw_service (account sempere-test)" >&2; exit 77; }
mdat=$(sed -n 's/^ *"mdat"<timedate>=[^"]*"\(.*\)\\000".*/\1/p' <<<"$item" | head -1)
[[ -n $mdat ]] || { echo "error: sim-signin: could not read the modification date of keychain item $pw_service (the lockout marker is keyed to it)" >&2; exit 1; }
marker=$HOME/.cache/sempere/sim-signin-attempted-$pw_service
if [[ -f $marker && $(<"$marker") == "$mdat" ]]; then
  echo "sim-signin: this password was already tried in an earlier run that did not end in a sign-in; not trying it again. Change the keychain item $pw_service (account sempere-test) to clear this (marker $marker)." >&2
  exit 4
fi

diag="$HOME/Library/Developer/CoreSimulator/Devices/$sim/data/var/db/diagnostics"
test_started=""
sim_scrub() {
  # The UI-test runner stays installed in the base simulator (clones would copy it): remove it. Then, with the simulator verified
  # Shutdown, drop its unified-log files: they keep the test runner's launch environment and every clone would copy them
  # (`log erase` is refused inside a simulator). Only *.tracev3 in the diagnostics store's four log folders; logd makes new ones.
  xcrun simctl boot "$sim" >/dev/null 2>&1 || true
  local app
  for app in $(xcrun simctl listapps "$sim" 2>/dev/null | grep -o '"[^"]*\.xctrunner"' | tr -d '"'); do xcrun simctl uninstall "$sim" "$app" >/dev/null 2>&1 || true; done
  xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true
  local i
  for ((i = 0; i < 60; i++)); do
    xcrun simctl list devices | grep -F "($sim)" | grep -q "(Shutdown)" && break
    sleep 1
  done
  if xcrun simctl list devices | grep -F "($sim)" | grep -q "(Shutdown)"; then
    local d
    for d in Persist Special Signpost HighVolume; do
      [[ -d $diag/$d ]] && find "$diag/$d" -maxdepth 1 -name '*.tracev3' -delete 2>/dev/null || true
    done
  else
    echo "warning: sim-signin: the simulator did not shut down; its log files were not removed" >&2
  fi
}
cleanup() {
  rm -f "${credfile:-}"
  [[ -z $test_started ]] || sim_scrub
  rm -rf "${rb_dir:-}"
  run_tmp_end
  sim_unlock
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
sim_lock || exit 1
rb_dir=$(mktemp -d "${TMPDIR:-/tmp}/signin-rb.XXXXXX")   # the result bundle: this run's own, never the shared Logs/Test
log=$rb_dir/xcodebuild.log
rc=0
test_started=1
# Two steps: xcodebuild saves its whole environment in the derived data (XCBuildData/…/attachments), so the build gets none of the
# variables; the test run (test-without-building, one attempt: no rerun of a refused password) gets the credentials file's path.
derived=${SEMPERE_DERIVED_DATA:-.build/xcode.noindex}
xb=(-project Apps/Sempere/Sempere.xcodeproj -scheme SempereScreenshots -derivedDataPath "$derived" -destination "platform=iOS Simulator,id=$sim")
(
  unset TEST_RUNNER_CKL_SIGNIN_FILE SEMPERE_RESULT_BUNDLE
  xcodebuild build-for-testing "${xb[@]}" CODE_SIGNING_ALLOWED=NO
) >"$log" 2>&1 || rc=$?
if [[ $rc -ne 0 ]]; then
  grep -E "error:|\*\* BUILD" "$log" | tail -10 || true
  echo "sim-signin: the build failed (nothing was typed)" >&2
  exit 1
fi
# From here a password may be typed: the marker first, the credentials file only now (after a successful build).
mkdir -p "$(dirname "$marker")"; printf '%s' "$mdat" > "$marker"
pw=$(security find-generic-password -a sempere-test -s "$pw_service" -w)   # a shell variable, not exported
credfile=$rb_dir/credentials
( umask 077; printf '%s\n%s\n' "$email" "$pw" > "$credfile" )   # builtins only: no argv
(
  export TEST_RUNNER_CKL_SIGNIN_FILE=$credfile
  unset SEMPERE_RESULT_BUNDLE
  xcodebuild test-without-building "${xb[@]}" -testLanguage en -testRegion US -parallel-testing-enabled NO \
    -only-testing:SempereAppUITests/CloudKitSimSignInUITests -resultBundlePath "$rb_dir/signin.xcresult" CODE_SIGNING_ALLOWED=NO
) >>"$log" 2>&1 || rc=$?
rm -f "$credfile"
# Scrub: nothing of the log may hold the password (bash's own match: the password is never an argument of a process).
if [[ $(<"$log") == *"$pw"* ]]; then echo "error: the password appears in the xcodebuild log; log withheld (the attempt marker stays)" >&2; pw=""; exit 4; fi
pw=""
grep -E "SIGNIN-|Test Case .*CloudKitSimSignIn|error:|\*\* TEST|needs a code|Executed" "$log" | tail -25 | while IFS= read -r line; do echo "${line//"$email"/<apple-id>}"; done || true
if grep -q "SIGNIN-OK" "$log" && [[ $rc -eq 0 ]]; then rm -f "$marker"; exit 0; fi
if grep -q "two-factor" "$log"; then
  rm -f "$marker"   # a verification-code screen: the password was accepted (Apple asks for the code after it)
  echo "sim-signin: needs a code sent to the account's trusted device (two-factor); the simulator is left signed out" >&2; exit 3
fi
# The marker goes only on positive evidence: SIGNIN-OK above, or the test's final line saying it ended having typed nothing (both are
# written unbuffered). A missing line (a crash, a kill, a launch failure) keeps it, as does any typing.
if grep -q "SIGNIN-NOTHING-TYPED" "$log" && ! grep -q "SIGNIN-PASSWORD-TYPING" "$log"; then
  rm -f "$marker"
  echo "sim-signin: no sign-in happened (nothing was typed)" >&2; exit 1
fi
echo "sim-signin: the run did not end in a sign-in and did not show that nothing was typed; not retried (marker $marker). Change the keychain item $pw_service to try again." >&2
exit 4
