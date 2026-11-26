#!/bin/bash
# Signs the `sempere-cloudkit` simulator in to the CloudKit test Apple ID again (its sign-in expires about daily: cloudd logs
# AuthTokenError 2011). Runs the UI test CloudKitSimSignInUITests (Apps/Sempere/SempereAppUITests), which drives Settings.
# Called by tools/cloudkit-live/run.sh (`sim-signin`, and by itself before the simulator leg when the account fails);
# `scripts/app.sh cloudkit-sim-signin` is the entry point (run it through xc-lock).
#
# The Apple ID and its password come from the login keychain (never a file, a command line or the repository):
#   security find-generic-password -a sempere-test -s sempere-test-apple-id-email -w
#   security find-generic-password -a sempere-test -s sempere-test-apple-id -w
# and reach the test only through the environment (xcodebuild forwards TEST_RUNNER_* variables to the test runner).
# Exit codes: 0 signed in; 3 two-factor code requested (never answered; needs a code from the account's trusted device); 1 other failure;
# 77 no keychain items (skipped).
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$repo"
sim=${SEMPERE_CLOUDKIT_SIM:-$(xcrun simctl list devices | sed -n 's/^ *sempere-cloudkit (\([0-9A-F-]\{36\}\)).*/\1/p' | head -1)}
[[ -n $sim ]] || { echo "SKIPPED sim-signin: no simulator named sempere-cloudkit" >&2; exit 77; }
email=$(security find-generic-password -a sempere-test -s sempere-test-apple-id-email -w 2>/dev/null || true)
[[ -n $email ]] || { echo "SKIPPED sim-signin: no keychain item sempere-test-apple-id-email (account sempere-test)" >&2; exit 77; }
security find-generic-password -a sempere-test -s sempere-test-apple-id >/dev/null 2>&1 \
  || { echo "SKIPPED sim-signin: no keychain item sempere-test-apple-id (account sempere-test)" >&2; exit 77; }
log=$(mktemp "${TMPDIR:-/tmp}/sim-signin.XXXXXX")
rc=0
# The run's result bundles are removed at exit: xcodebuild may record the test runner's environment and failure screenshots in them,
# and nothing here may keep the password anywhere.
trap 'find "${SEMPERE_DERIVED_DATA:-.build/xcode.noindex}/Logs/Test" -maxdepth 1 -name "*.xcresult" -newer "$log" -exec rm -rf {} + 2>/dev/null || true; rm -f "$log"' EXIT
# No reruns (SEMPERE_RERUNS=0): a refused password must not be tried again and again. The password is read inside the subshell's environment only (never an argument).
TEST_RUNNER_CKL_SIGNIN_EMAIL=$email \
TEST_RUNNER_CKL_SIGNIN_PASSWORD=$(security find-generic-password -a sempere-test -s sempere-test-apple-id -w) \
SEMPERE_SIM_ID=$sim SEMPERE_FAIL_FAST=0 SEMPERE_RERUNS=0 \
  scripts/app.sh test-phone-ui -only-testing:SempereAppUITests/CloudKitSimSignInUITests >"$log" 2>&1 || rc=$?
# Scrub: nothing of the log may hold the password (verify, then print the useful lines only).
pw=$(security find-generic-password -a sempere-test -s sempere-test-apple-id -w)
if grep -qF -- "$pw" "$log"; then echo "error: the password appears in the xcodebuild log; log withheld" >&2; exit 1; fi
unset pw
grep -E "SIGNIN-|Test Case .*CloudKitSimSignIn|error:|\*\* TEST|needs a code|Executed" "$log" | sed "s/$email/<apple-id>/g" | tail -25
if [[ $rc -ne 0 ]]; then
  grep -q "two-factor" "$log" && { echo "sim-signin: needs a code sent to the account's trusted device (two-factor); the simulator is left signed out" >&2; exit 3; }
  exit 1
fi
grep -q "SIGNIN-\(OK\|NOT-NEEDED\)" "$log" || { echo "sim-signin: the test passed but did not report a sign-in" >&2; exit 1; }
