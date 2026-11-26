#!/bin/bash
# The real-CloudKit suite of docs/design/1.4-cloudkit.md §10.2, against the DEVELOPMENT environment of the container only
# (docs/io.md "The CloudKit target", "Testing it against the real database"). scripts/app.sh test-cloudkit calls it through the build lock:
#
#   tools/cloudkit-live/run.sh [all]                schema import and check, the adapter suite, the two-store CLI scenarios, cleanup
#   tools/cloudkit-live/run.sh schema               import schema.ckdb into development and check the export against it
#   tools/cloudkit-live/run.sh suite [NAME...]      the adapter and transport scenarios (tools/cloudkit-live/Sources)
#   tools/cloudkit-live/run.sh cli                  the two-store CLI scenarios (cli-scenarios.sh)
#   tools/cloudkit-live/run.sh catalyst|simulator   the adapter scenarios as a Mac Catalyst process / in a clone of the sempere-cloudkit simulator
#   tools/cloudkit-live/run.sh sim-account          is the sempere-cloudkit simulator's iCloud account usable? (exit 0 yes)
#   tools/cloudkit-live/run.sh sim-signin           sign it in again (an XCUITest drives Settings; docs/io.md); the simulator leg does it by itself when the account fails
#   tools/cloudkit-live/run.sh cross                Mac Catalyst and the simulator, one zone: each writes, the other reads
#   tools/cloudkit-live/run.sh cleanup [PREFIX...]  delete the test zones (default: test-) and the vault zones of the suite's own test vaults
#                                                   (their vault.json label starts with `cloudkit-live-test`; no other `sempere-` zone is ever deleted:
#                                                   they may be your development builds' vaults)
#
# What it needs (it says which is missing and exits 77, "skipped", when the test account is not set up on this Mac):
#   * ~/.config/sempere/release.env with SEMPERE_TEAM_ID (never committed; the team id appears nowhere in this repository);
#   * a development provisioning profile of the CLI's App ID that lists this Mac: SEMPERE_CLI_DEV_PROFILE in release.env or the
#     environment, else the newest "Sempere CLI Dev*" profile in ~/.config/sempere/profiles/ or ~/Library/MobileDevice/Provisioning Profiles/;
#   * a development Apple ID signed in on this Mac (iCloud), and the management token saved with `xcrun cktool save-token`;
#   * an "Apple Development" identity in the keychain.
# Nothing is launched sandboxed (an unsandboxed signed process is accepted by CloudKit, design §13.2), and the process is never
# an app that a consent dialog could stall.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
cd "$repo"
container=iCloud.io.github.anthonytw.sempere
env_file=${SEMPERE_RELEASE_ENV:-$HOME/.config/sempere/release.env}
source "$here/signin/lock.sh"
skip() { echo "SKIPPED test-cloudkit: $*" >&2; exit 77; }
die() { echo "error: $*" >&2; exit 1; }

sub=${1:-all}; [[ $# -gt 0 ]] && shift || true
work=${SEMPERE_CKL_WORK:-}   # a folder to keep the built bundles in between runs (default: a new one, removed at the end of `all`)

[[ $(uname) == Darwin ]] || skip "needs a Mac"
[[ -f $env_file ]] || skip "no $env_file (SEMPERE_TEAM_ID, docs/releasing.md)"
# shellcheck disable=SC1090
team=$(sed -n 's/^SEMPERE_TEAM_ID=//p' "$env_file" | tr -d '"' | head -1)
[[ -n $team ]] || skip "SEMPERE_TEAM_ID is not in $env_file"
profile=${SEMPERE_CLI_DEV_PROFILE:-$(sed -n 's/^SEMPERE_CLI_DEV_PROFILE=//p' "$env_file" | tr -d '"' | head -1)}
profile=${profile/#\~/$HOME}

provisioning_udid=$(system_profiler SPHardwareDataType | awk '/Provisioning UDID/ {print $3}')
profile_ok() { # $1 = file, $2 = App ID suffix: a development profile of that App ID, with the container, this Mac, not expired
  local p=$1 t; t=$(mktemp); security cms -D -i "$p" > "$t" 2>/dev/null || { rm -f "$t"; return 1; }
  local ok=1
  plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - "$t" 2>/dev/null | grep -q "\\.$2\$" \
    && plutil -extract 'Entitlements.com\.apple\.developer\.icloud-container-identifiers' json -o - "$t" 2>/dev/null | grep -q "\"$container\"" \
    && plutil -extract ProvisionedDevices json -o - "$t" 2>/dev/null | grep -q "$provisioning_udid" \
    && [[ $(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$(plutil -extract ExpirationDate raw -o - "$t")" +%s 2>/dev/null || echo 0) -gt $(date +%s) ]] && ok=0
  rm -f "$t"; return $ok
}
find_profile() { # $1 = App ID suffix (a regular expression): the newest profile on this Mac that passes profile_ok, or nothing
  local f
  while IFS= read -r f; do
    if profile_ok "$f" "$1"; then echo "$f"; return 0; fi
  done < <(ls -t "$HOME"/.config/sempere/profiles/*.provisionprofile "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision 2>/dev/null || true)
  return 0
}
[[ -n $profile ]] || profile=$(find_profile 'io\.github\.anthonytw\.sempere\.cli')
[[ -n $profile && -f $profile ]] || skip "no development profile of io.github.anthonytw.sempere.cli for this Mac (SEMPERE_CLI_DEV_PROFILE, docs/design/1.4-cloudkit.md §11)"
profile_ok "$profile" 'io\.github\.anthonytw\.sempere\.cli' || skip "$profile is not a current development profile of the CLI App ID that lists this Mac"
security find-identity -v -p codesigning | grep -q 'Apple Development' || skip "no Apple Development identity in the keychain"

ck() { local c=$1; shift; xcrun cktool "$c" --team-id "$team" --container-id "$container" --environment development "$@"; }
xcrun cktool get-teams >/dev/null 2>&1 || skip "no CloudKit management token (xcrun cktool save-token)"

[[ -n $work ]] || work=$(mktemp -d "${TMPDIR:-/tmp}/cloudkit-live.XXXXXX")
mkdir -p "$work"; work=$(cd "$work" && pwd)
drv=$work/driver/cloudkit-live.app/Contents/MacOS/cloudkit-live
cli=$work/x/bin/sempere

# --- schema -----------------------------------------------------------------------------------------------------------------
# Imports the checked-in schema into DEVELOPMENT (never production: cktool refuses a write there), then exports it and checks that
# the record types and fields are the checked-in ones (the development container also holds the system type `Users`).
normalize() { # a .ckdb file -> one "TYPE field TYPE" line per field, user types only, sorted
  awk '/RECORD TYPE/ {t=$3; skip = (t == "Users")} !skip && t != "" && $1 !~ /^"___|^GRANT|^\)|^RECORD|^DEFINE/ && NF >= 2 {gsub(",", "", $2); gsub(",", "", $3); print t, $1, $2, $3}' "$1" | sort
}
do_schema() {
  echo "== schema: import into development, export, compare"
  ck import-schema --validate --file tools/cloudkit-spike/schema.ckdb >/dev/null
  ck export-schema --output-file "$work/exported.ckdb" >/dev/null
  if ! diff <(normalize tools/cloudkit-spike/schema.ckdb) <(normalize "$work/exported.ckdb") >"$work/schema.diff"; then
    cat "$work/schema.diff"; die "the development schema differs from tools/cloudkit-spike/schema.ckdb after the import"
  fi
  echo "ok  schema: development matches tools/cloudkit-spike/schema.ckdb"
}

# --- build ------------------------------------------------------------------------------------------------------------------
# Signs a bundle `$2` (executable `$3`) with the development profile: entitlements from packaging/cli/entitlements.plist, the team and
# App ID taken from the profile, container environment Development (what scripts/release-sign-macos.sh --dev does for the CLI).
sign_dev() {
  local app=$1 t; t=$(mktemp)
  security cms -D -i "$profile" > "$t.plist" 2>/dev/null
  local app_id; app_id=$(plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - "$t.plist")
  cp "$profile" "$app/Contents/embedded.provisionprofile"
  sed "s/@APPLICATION_IDENTIFIER@/$app_id/; s/@TEAM_IDENTIFIER@/$team/; s/@CONTAINER_ENVIRONMENT@/Development/" packaging/cli/entitlements.plist > "$t.ent"
  codesign --force --sign "Apple Development" --entitlements "$t.ent" "$app" >/dev/null 2>&1 || die "codesign failed for $app"
  rm -f "$t" "$t.plist" "$t.ent"
}

build_driver() {
  build_driver_built
  [[ -n ${account_checked:-} ]] && return 0
  account_checked=1
  # Only a Mac with no account, or a restricted one, skips: the driver failing (not signed, no entitlement, CloudKit
  # erroring) or iCloud not answering is a failure, so a broken seat does not pass as "skipped".
  local who; who=$("$drv" account 2>&1) || die "cloudkit-live could not read the iCloud account: $who"
  case $who in
    available*) ;;
    noAccount*|restricted*|managedAccountRestricted*)
      skip "no usable iCloud account on this Mac (cloudkit-live account: $who); sign in to iCloud in System Settings" ;;
    *) die "iCloud did not answer usably (cloudkit-live account: ${who:-no answer})" ;;
  esac
}

build_driver_built() {
  [[ -x $drv && $drv -nt tools/cloudkit-live/Sources/cloudkit-live/main.swift && -z ${SEMPERE_CKL_REBUILD:-} ]] && return 0
  echo "== build: the test driver"
  (cd tools/cloudkit-live && swift build -c release 2>&1 | tail -3) || die "the driver did not build"
  local bin; bin=$(cd tools/cloudkit-live && swift build -c release --show-bin-path)/cloudkit-live
  local app=$work/driver/cloudkit-live.app
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
  cp "$bin" "$app/Contents/MacOS/cloudkit-live"
  sed 's|<string>sempere</string>|<string>cloudkit-live</string>|' packaging/cli/Info.plist | sed 's/@VERSION@/1.0.0/g' > "$app/Contents/Info.plist"
  plutil -lint "$app/Contents/Info.plist" >/dev/null
  sign_dev "$app"
}

build_cli() {
  [[ -x $cli && -z ${SEMPERE_CKL_REBUILD:-} ]] && return 0
  echo "== build: the sempere CLI bundle, development-signed"
  swift build -c release --product sempere 2>&1 | tail -2
  local bin version
  bin=$(swift build -c release --product sempere --show-bin-path)/sempere
  version=$("$bin" --version | head -1 | cut -d' ' -f2)
  scripts/cli-bundle.sh "$bin" "$version" "$work/bundle" Sources/SempereFonts/Fonts >/dev/null
  SEMPERE_CLI_BUNDLE="$work/bundle" scripts/package-cli.sh "$bin" "$version" macos-universal "$work/dist" >/dev/null
  SEMPERE_RELEASE_ENV=/dev/null SEMPERE_CLI_PROFILE=$profile scripts/release-sign-macos.sh --dev --version "$version" \
    "$work/dist/sempere-$version-macos-universal.tar.gz" "$work/signed.tar.gz" >/dev/null
  mkdir -p "$work/x/bin" && tar -xzf "$work/signed.tar.gz" -C "$work/x"
  ln -sf "../sempere-$version-macos-universal/sempere.app/Contents/MacOS/sempere" "$cli"
}

# --- run --------------------------------------------------------------------------------------------------------------------
# --- Mac Catalyst and the iOS simulator --------------------------------------------------------------------------------------
# The same driver built for the platforms the app runs on (Mac Catalyst, signed with the Catalyst development profile of the app's
# App ID: plain `codesign`, design §13.2; the simulator, entitlements in a `-sectcreate` section and an ad-hoc signature, no
# profile), so the adapter is exercised under UIKit's CloudKit too. Then a two-platform test on one zone: files written by the Mac
# Catalyst process are read by the simulator's and the other way round (only the account is shared). Unsandboxed, background-only
# (LSUIElement): no window, no screen, no consent dialog. Output reaches the script through a file (CKL_OUT).
platform_scenarios=(account zones records convergence conflict delete "parts: a file" "zone deleted" "change tokens")
catalyst_profile=""
build_catalyst() {
  catalyst_profile=${SEMPERE_CATALYST_DEV_PROFILE:-$(find_profile 'io\.github\.anthonytw\.sempere')}
  [[ -n $catalyst_profile && -f $catalyst_profile ]] || skip "no development profile of the app (io.github.anthonytw.sempere, Mac Catalyst) for this Mac"
  [[ -x $work/catalyst/cloudkit-live.app/Contents/MacOS/cloudkit-live && $work/catalyst/cloudkit-live.app/Contents/MacOS/cloudkit-live -nt tools/cloudkit-live/Sources/cloudkit-live/main.swift && -z ${SEMPERE_CKL_REBUILD:-} ]] && return 0
  echo "== build: the test driver for Mac Catalyst"
  (cd tools/cloudkit-live && swift build -c release --triple arm64-apple-ios27.0-macabi --scratch-path "$work/macabi" 2>&1 | tail -2)
  local bin; bin=$(find "$work/macabi/out/Products" -name cloudkit-live -type f -path '*maccatalyst*' ! -path '*dSYM*' | head -1)
  [[ -n $bin ]] || die "the Mac Catalyst driver did not build"
  local app=$work/catalyst/cloudkit-live.app t; t=$(mktemp)
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
  cp "$bin" "$app/Contents/MacOS/cloudkit-live"
  cat > "$app/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.anthonytw.sempere</string>
<key>CFBundleExecutable</key><string>cloudkit-live</string>
<key>CFBundleName</key><string>cloudkit-live</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
  cp "$catalyst_profile" "$app/Contents/embedded.provisionprofile"
  local id="$team.io.github.anthonytw.sempere"
  cat > "$t" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.developer.icloud-container-identifiers</key><array><string>$container</string></array>
<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
<key>com.apple.developer.icloud-container-environment</key><string>Development</string>
<key>application-identifier</key><string>$id</string>
<key>com.apple.application-identifier</key><string>$id</string>
<key>com.apple.developer.team-identifier</key><string>$team</string>
<key>com.apple.developer.aps-environment</key><string>development</string>
<key>com.apple.security.get-task-allow</key><true/>
</dict></plist>
PL
  codesign --force --sign "Apple Development" --entitlements "$t" "$app" >/dev/null 2>&1 || die "codesign failed for the Catalyst driver"
  rm -f "$t"
}
# Runs the driver in the Catalyst bundle with the arguments $2..; output to $1 (a file). The binary links no UIKit, so it is started
# directly (the app of the C0 spike, which has a UIApplicationMain, had to go through LaunchServices; LaunchServices refuses this bundle).
run_catalyst() {
  local out=$1; shift
  : > "$out"
  CKL_OUT=$out CKL_ARGS=$(IFS="|"; echo "$*") "$work/catalyst/cloudkit-live.app/Contents/MacOS/cloudkit-live" || true
}

sim_base=""; sim_clone=""
build_simulator() {
  [[ -x $work/sim/cloudkit-live-sim.app/cloudkit-live && $work/sim/cloudkit-live-sim.app/cloudkit-live -nt tools/cloudkit-live/Sources/cloudkit-live/main.swift && -z ${SEMPERE_CKL_REBUILD:-} ]] && return 0
  echo "== build: the test driver for the iOS simulator"
  local sdk ent app=$work/sim/cloudkit-live-sim.app
  sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
  mkdir -p "$work/sim"; ent=$work/sim/entitlements.plist
  cat > "$ent" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.developer.icloud-container-identifiers</key><array><string>$container</string></array>
<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
<key>com.apple.developer.icloud-container-environment</key><string>Development</string>
<key>aps-environment</key><string>development</string>
<key>application-identifier</key><string>$team.io.github.anthonytw.sempere</string>
</dict></plist>
PL
  (cd tools/cloudkit-live && swift build -c release --triple arm64-apple-ios27.0-simulator --sdk "$sdk" --scratch-path "$work/simbuild" \
     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$ent" 2>&1 | tail -2)
  local bin; bin=$(find "$work/simbuild/out/Products" -name cloudkit-live -type f -path '*iphonesimulator*' ! -path '*dSYM*' | head -1)
  [[ -n $bin ]] || die "the simulator driver did not build"
  rm -rf "$app"; mkdir -p "$app"
  cp "$bin" "$app/cloudkit-live"
  cat > "$app/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.anthonytw.sempere</string>
<key>CFBundleExecutable</key><string>cloudkit-live</string>
<key>CFBundleName</key><string>cloudkit-live</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>MinimumOSVersion</key><string>27.0</string>
<key>DTPlatformName</key><string>iphonesimulator</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
</dict></plist>
PL
  codesign --force --sign - "$app" >/dev/null 2>&1 || die "codesign failed for the simulator driver"
}
# A clone of the base simulator with the test Apple ID signed in (a clone keeps the sign-in, design §13.1); deleted at exit.
sim_base_id() {
  sim_base=${SEMPERE_CLOUDKIT_SIM:-$(xcrun simctl list devices | sed -n 's/^ *sempere-cloudkit (\([0-9A-F-]\{36\}\)).*/\1/p' | head -1)}
  [[ -n $sim_base ]] || skip "no simulator named sempere-cloudkit (the base simulator with the test Apple ID signed in; docs/design/1.4-cloudkit.md §11)"
}
# Is the base simulator's iCloud account usable? Boots the base itself (not a clone), runs the driver's `account` scenario in it
# (the same call the suite makes). Sets $sim_account_out. The sign-in expires about daily (cloudd: AuthTokenError 2011).
sim_account_ok() {
  build_simulator; sim_base_id
  xcrun simctl boot "$sim_base" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$sim_base" -b >/dev/null 2>&1 || true
  xcrun simctl install "$sim_base" "$work/sim/cloudkit-live-sim.app"
  local out=$work/sim-account.out rc=0 i
  : > "$out"
  xcrun simctl terminate "$sim_base" io.github.anthonytw.sempere >/dev/null 2>&1 || true
  SIMCTL_CHILD_CKL_OUT=$out SIMCTL_CHILD_CKL_ARGS="suite|account" xcrun simctl launch "$sim_base" io.github.anthonytw.sempere >/dev/null || rc=1
  for ((i = 0; i < 120 && rc == 0; i++)); do
    grep -qE '^(all [0-9]+ scenarios passed|[0-9]+ of [0-9]+ scenarios FAILED|FAIL |usage|this process is not signed)' "$out" && break
    sleep 1
  done
  xcrun simctl terminate "$sim_base" io.github.anthonytw.sempere >/dev/null 2>&1 || true
  sim_account_out=$(cat "$out")
  [[ $rc == 0 ]] && grep -q '^all [0-9]* scenarios passed' "$out"
}
# The base simulator's account must work before a clone of it is made (a clone keeps the sign-in): when it does not, sign in again
# (signin/sim-signin.sh: an XCUITest that drives Settings with the test Apple ID from the keychain) and check once more. A
# verification code (2FA) is never answered, and a refused password is never repeated: those fail the leg (returns 1; the caller
# goes on with the other legs and the cleanup) and the simulator is left signed out. The caller holds the base simulator's lock.
sim_ensure_account() {
  [[ -z ${SEMPERE_CKL_NO_SIGNIN:-} ]] || return 0
  if sim_account_ok; then
    echo "ok  simulator iCloud account is valid"
    xcrun simctl shutdown "$sim_base" >/dev/null 2>&1 || true; return 0
  fi
  echo "== the sempere-cloudkit simulator's iCloud account is not usable ($(echo "$sim_account_out" | tr '\n' ' ' | cut -c1-200)): signing in again"
  local rc=0
  xcrun simctl shutdown "$sim_base" >/dev/null 2>&1 || true
  SEMPERE_CKL_SIM_LOCKED=$$ SEMPERE_CLOUDKIT_SIM=$sim_base "$here/signin/sim-signin.sh" || rc=$?
  case $rc in
    0) ;;
    3) echo "error: the simulator needs a verification code (two-factor) from the account's trusted device; sign it in by hand once" >&2; return 1 ;;
    4) echo "error: the test Apple ID's password was tried and did not end in a sign-in (now or earlier); it is not tried again until the keychain item sempere-test-apple-id (account sempere-test) is changed" >&2; return 1 ;;
    77) echo "error: the simulator's account is not usable and there are no keychain items to sign it in again" >&2; return 1 ;;
    *) echo "error: could not sign the sempere-cloudkit simulator in again (exit $rc, see above)" >&2; return 1 ;;
  esac
  if ! sim_account_ok; then
    xcrun simctl shutdown "$sim_base" >/dev/null 2>&1 || true
    echo "error: the simulator's iCloud account is still not usable after signing in: $sim_account_out" >&2; return 1
  fi
  echo "ok  simulator iCloud account is valid again"
  xcrun simctl shutdown "$sim_base" >/dev/null 2>&1 || true
}
# The sign-in alone (run.sh sim-signin), under the base simulator's lock.
do_sim_signin() {
  sim_base_id
  sim_lock || return 1
  xcrun simctl shutdown "$sim_base" >/dev/null 2>&1 || true
  local rc=0
  SEMPERE_CKL_SIM_LOCKED=$$ SEMPERE_CLOUDKIT_SIM=$sim_base "$here/signin/sim-signin.sh" || rc=$?
  sim_unlock
  return $rc
}
# The base simulator is checked, and signed in again when needed, under its lock, which is held until the clone exists.
sim_up() {
  [[ -z $sim_clone ]] || return 0
  sim_base_id
  sim_lock || return 1
  if ! sim_ensure_account; then sim_unlock; return 1; fi
  sim_clone=$(xcrun simctl clone "$sim_base" "sempere-ckl-$$") || { sim_unlock; echo "error: could not clone the simulator" >&2; return 1; }
  sim_unlock
  trap sim_down EXIT
  xcrun simctl boot "$sim_clone" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$sim_clone" -b >/dev/null 2>&1 || true
  xcrun simctl install "$sim_clone" "$work/sim/cloudkit-live-sim.app"
}
sim_down() {
  [[ -n $sim_clone ]] || return 0
  xcrun simctl terminate "$sim_clone" io.github.anthonytw.sempere >/dev/null 2>&1 || true
  xcrun simctl shutdown "$sim_clone" >/dev/null 2>&1 || true
  xcrun simctl delete "$sim_clone" >/dev/null 2>&1 || true
  sim_clone=""
}
# Runs the simulator driver with the arguments $2..; output to $1; waits (bounded) for the last line the driver prints.
run_simulator() {
  local out=$1; shift
  : > "$out"
  xcrun simctl terminate "$sim_clone" io.github.anthonytw.sempere >/dev/null 2>&1 || true
  SIMCTL_CHILD_CKL_OUT=$out SIMCTL_CHILD_CKL_ARGS="$(IFS="|"; echo "$*")" xcrun simctl launch "$sim_clone" io.github.anthonytw.sempere >/dev/null || die "the simulator driver did not launch"
  local i
  for ((i = 0; i < 900; i++)); do
    grep -qE '^(all [0-9]+ scenarios passed|[0-9]+ of [0-9]+ scenarios FAILED|wrote |verified |FAIL |usage|this process is not signed)' "$out" && return 0
    sleep 1
  done
  echo "the simulator driver did not finish in 15 minutes" >&2; return 1
}

# Reads the file the platform's driver wrote; fails unless its last verdict is a success.
verdict() { # file, label
  cat "$1" | sed "s/^/  [$2] /"
  grep -qE '^(all [0-9]+ scenarios passed|wrote |verified )' "$1" && ! grep -q '^FAIL' "$1"
}

do_platform() { # catalyst | simulator
  local name=$1 out=$work/$1.out
  if [[ $name == catalyst ]]; then build_catalyst; echo "== adapter and transport scenarios on Mac Catalyst (real database, development)"; run_catalyst "$out" suite "${platform_scenarios[@]}"
  else build_simulator; sim_up || return 1; echo "== adapter and transport scenarios in the iOS simulator (real database, development)"; run_simulator "$out" suite "${platform_scenarios[@]}"; fi
  verdict "$out" "$name"
}

# Two platforms on one zone, both directions.
do_cross() {
  build_driver; build_catalyst; build_simulator; sim_up || return 1
  local zone="test-cross-$(uuidgen | tr 'A-Z' 'a-z')" ok=0
  echo "== two platforms, one zone: Mac Catalyst and the iOS simulator (real database, development)"
  run_catalyst "$work/c-write.out" cross write "$zone" fromcatalyst; verdict "$work/c-write.out" catalyst || ok=1
  run_simulator "$work/s-verify.out" cross verify "$zone" fromcatalyst; verdict "$work/s-verify.out" simulator || ok=1
  run_simulator "$work/s-write.out" cross write "$zone" fromsim; verdict "$work/s-write.out" simulator || ok=1
  run_catalyst "$work/c-verify.out" cross verify "$zone" fromsim; verdict "$work/c-verify.out" catalyst || ok=1
  "$drv" delete-zone "$zone" || ok=1
  return $ok
}

do_suite() { build_driver; echo "== adapter and transport scenarios (real database, development)"; "$drv" suite "$@"; }
do_cli() {
  build_driver; build_cli
  echo "== two stores through the CLI bundle (real database, development)"
  rm -rf "$work/cli"; CKL=$drv SEMPERE=$cli "$here/cli-scenarios.sh" "$work/cli"
}
do_cleanup() {
  build_driver; "$drv" cleanup "$@" || return 1
  # Only the vault zones the suite made itself (a marker in the vault.json label), never a development build's.
  "$drv" cleanup-vaults
}

case $sub in
  schema) do_schema ;;
  suite) do_suite "$@" ;;
  cli) do_cli ;;
  cleanup) do_cleanup "$@" ;;
  catalyst) build_driver; do_platform catalyst ;;
  simulator) build_driver; do_platform simulator ;;
  sim-account) build_driver; rc=0; sim_base_id; sim_lock || exit 1; sim_account_ok || rc=1; echo "$sim_account_out"; xcrun simctl shutdown "$sim_base" >/dev/null 2>&1 || true; sim_unlock; exit $rc ;;
  sim-signin) do_sim_signin ;;
  cross) do_cross ;;
  all)
    status=0
    do_schema
    do_suite || status=1
    do_cli || status=1
    do_platform catalyst || status=1
    do_platform simulator || status=1
    do_cross || status=1
    sim_down
    echo "== cleanup"
    do_cleanup test- || status=1
    [[ -z ${SEMPERE_CKL_KEEP:-} && -z ${SEMPERE_CKL_WORK:-} ]] && rm -rf "$work"
    [[ $status == 0 ]] && echo "test-cloudkit: all passed" || echo "test-cloudkit: FAILED" >&2
    exit $status ;;
  *) die "usage: run.sh [all|schema|suite|cli|cleanup]" ;;
esac
