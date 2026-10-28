#!/usr/bin/env bash
# Archive the Sempere app from a clean, temporary worktree of REF and upload it to TestFlight
# (docs/releasing.md, "A. TestFlight build"). Your own checkout is never checked out or changed.
#
#   scripts/testflight.sh [options] [ios|mac|both] [REF]      (defaults: both, main)
#
#   ios    the iPad and iPhone app (generic/platform=iOS)
#   mac    the Mac Catalyst app (generic/platform=macOS,variant=Mac Catalyst)
#   REF    a branch, tag or commit GitHub has; a branch name means origin/<branch> after a fetch
#
# Options:
#   --dry-run           check the configuration, the ref and the suite status, write the export options,
#                       print the xcodebuild commands (identifiers redacted) and stop before `xcodebuild archive`
#   --export-only       archive and export signed packages into the output folder; upload nothing
#   --skip-suite-check  build although `local/testflight-suite` did not pass on the commit (prints a loud
#                       warning; for an emergency only, docs/releasing.md)
#   --keep              keep the temporary worktree after the run
#   --yes               upload without asking (unattended runs); otherwise an upload asks [y/N] first
#   -h, --help          print this help
#
# Policy (docs/ci.md): a TestFlight build needs `scripts/local-ci.sh --testflight` (`just ci-testflight`)
# passed on the exact commit, which posts the commit status `local/testflight-suite`; the release sweep
# (`just ci-release`, `local/release-sweep`) runs all of it and is accepted too.
#
# Configuration: ${SEMPERE_RELEASE_ENV:-~/.config/sempere/release.env} (template: scripts/release.env.example);
# a variable set in the environment wins over the file. No team, key or account identifier lives in this repository.
#   SEMPERE_TEAM_ID              Apple Developer team ID (required)
#   SEMPERE_SIGNING              xcode | api (default: api when SEMPERE_ASC_KEY_ID is set, else xcode)
#       xcode: automatic signing with the Apple ID signed in to Xcode (Settings > Accounts), plus
#              -allowProvisioningUpdates; no API key. The Apple ID needs the Admin or Account Holder role.
#       api:   an App Store Connect API key for the upload, manual signing with App Store provisioning
#              profiles and distribution certificates installed on this Mac
#   SEMPERE_ASC_KEY_PATH         api: the .p8 key file (keep it outside any repository)
#   SEMPERE_ASC_KEY_ID           api: the key's ID
#   SEMPERE_ASC_ISSUER_ID        api: the issuer ID (App Store Connect > Users and Access > Integrations)
#   SEMPERE_PROFILE_IOS          api: profile name for io.github.anthonytw.sempere on iOS (default "Sempere iOS App Store")
#   SEMPERE_PROFILE_WIDGETS_IOS  api: profile for ….widgets (default "Sempere Widgets iOS App Store")
#   SEMPERE_PROFILE_MAC          api: Mac Catalyst profile (default "Sempere Mac App Store")
#   SEMPERE_DIST_CERT            api: signing certificate (default "Apple Distribution")
#   SEMPERE_INSTALLER_CERT       api: Mac installer certificate (default "3rd Party Mac Developer Installer")
#   SEMPERE_KEYCHAIN             optional: a keychain to unlock first (holding the signing identities)
#   SEMPERE_KEYCHAIN_PASSWORD_FILE  optional: a file with that keychain's password (else `security` asks; with
#                                the file, the password is briefly visible to `ps` as an argument of `security`)
#   SEMPERE_TF_OUT               output folder (default $TMPDIR/sempere-testflight): archives, logs, exports;
#                                one run at a time per folder
#   SEMPERE_GH_REPO              GitHub repository of the status check (default anthonytw/sempere)
#   SEMPERE_XC_LOCK              a wrapper for each xcodebuild run (default ~/.claude/scripts/xc-lock.sh,
#                                used only when it exists: the agent seat's build queue)
set -euo pipefail

usage="usage: $0 [--dry-run] [--export-only] [--skip-suite-check] [--keep] [--yes] [ios|mac|both] [REF]"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dry=false export_only=false skip_suite=false keep=false yes=false which="" ref=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry=true ;;
    --export-only) export_only=true ;;
    --skip-suite-check) skip_suite=true ;;
    --keep) keep=true ;;
    --yes) yes=true ;;
    -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
    -*) echo "$usage" >&2; exit 2 ;;
    *) if [[ -z $which ]]; then which=$arg; elif [[ -z $ref ]]; then ref=$arg; else echo "$usage" >&2; exit 2; fi ;;
  esac
done
which=${which:-both}
ref=${ref:-main}
case "$which" in ios|mac|both) ;; *) echo "$usage" >&2; exit 2 ;; esac

die() { echo "error: $*" >&2; exit 1; }

# --- Configuration -------------------------------------------------------------------------------
env_file=${SEMPERE_RELEASE_ENV:-$HOME/.config/sempere/release.env}
if [[ -f $env_file ]]; then
  # The environment wins over the file: keep what is already set, read the file, put it back.
  env_saved=""
  env_names=$(compgen -v SEMPERE_ || true)
  # shellcheck disable=SC2086  # a list of variable names
  [[ -n $env_names ]] && env_saved=$(declare -p $env_names)
  set -a
  # shellcheck disable=SC1090  # the owner's own settings file, outside the repository
  source "$env_file"
  set +a
  [[ -n $env_saved ]] && eval "$env_saved"
  echo "config: $env_file"
elif [[ -n ${SEMPERE_RELEASE_ENV:-} ]]; then
  die "SEMPERE_RELEASE_ENV names $env_file, which does not exist"
fi

team=${SEMPERE_TEAM_ID:-}
[[ -n $team ]] || die "SEMPERE_TEAM_ID is not set (copy scripts/release.env.example to ~/.config/sempere/release.env and fill it in)"
[[ $team =~ ^[A-Z0-9]{10}$ ]] || die "SEMPERE_TEAM_ID does not look like a team ID (10 letters and digits)"

signing=${SEMPERE_SIGNING:-}
if [[ -z $signing ]]; then
  if [[ -n ${SEMPERE_ASC_KEY_ID:-} ]]; then signing=api; else signing=xcode; fi
fi
auth=()
case "$signing" in
  xcode) ;;
  api)
    key_path=${SEMPERE_ASC_KEY_PATH:-}; key_id=${SEMPERE_ASC_KEY_ID:-}; issuer=${SEMPERE_ASC_ISSUER_ID:-}
    [[ -n $key_path && -n $key_id && -n $issuer ]] \
      || die "api signing needs SEMPERE_ASC_KEY_PATH, SEMPERE_ASC_KEY_ID and SEMPERE_ASC_ISSUER_ID"
    key_path=${key_path/#\~/$HOME}
    [[ -r $key_path ]] || die "SEMPERE_ASC_KEY_PATH: the key file is missing or unreadable"
    case "$key_path" in "$repo_root"/*) die "the API key must not live inside the repository" ;; esac
    auth=(-authenticationKeyPath "$key_path" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")
    ;;
  *) die "SEMPERE_SIGNING must be xcode or api, not '$signing'" ;;
esac
profile_ios=${SEMPERE_PROFILE_IOS:-Sempere iOS App Store}
profile_widgets=${SEMPERE_PROFILE_WIDGETS_IOS:-Sempere Widgets iOS App Store}
profile_mac=${SEMPERE_PROFILE_MAC:-Sempere Mac App Store}
dist_cert=${SEMPERE_DIST_CERT:-Apple Distribution}
installer_cert=${SEMPERE_INSTALLER_CERT:-3rd Party Mac Developer Installer}
gh_repo=${SEMPERE_GH_REPO:-anthonytw/sempere}

out=${SEMPERE_TF_OUT:-${TMPDIR:-/tmp}/sempere-testflight}
out=${out%/}
# After $out is chosen (its default is under the shared TMPDIR): a TMPDIR of this run's own, removed at exit.
source "$repo_root/scripts/run-tmp.sh"
# xcodebuild writes the export and upload diagnostics (SempereApp_*.xcdistributionlogs, ResultBundle_*) to TMPDIR,
# which is removed at exit: keep them in $out/diagnostics when the run failed (argument: its exit status).
save_dist_logs() {
  local f
  [[ ${1:-1} -ne 0 ]] || return 0
  for f in "$SEMPERE_RUN_TMP"/*.xcdistributionlogs "$SEMPERE_RUN_TMP"/ResultBundle_*; do
    [[ -e $f ]] || continue
    mkdir -p "$out/diagnostics" && cp -R "$f" "$out/diagnostics/" 2>/dev/null || true
  done
}
if [[ ! -d $out ]]; then mkdir -p "$out" && chmod 700 "$out"; fi
# One run per output folder: archives, export options and derived data are shared by runs there.
mkdir "$out/.run-lock" 2>/dev/null \
  || die "another testflight.sh run is using $out (if none is, remove $out/.run-lock)"
trap 'st=$?; rmdir "$out/.run-lock" 2>/dev/null || true; save_dist_logs "$st"; run_tmp_end' EXIT

lock=()
xc_lock=${SEMPERE_XC_LOCK:-$HOME/.claude/scripts/xc-lock.sh}
[[ -x $xc_lock ]] && lock=("$xc_lock")

# Never print an identifier from the configuration: show placeholders instead.
redact() {
  local s=$1
  s=${s//"$team"/<SEMPERE_TEAM_ID>}
  if [[ $signing == api ]]; then
    s=${s//"$key_path"/<SEMPERE_ASC_KEY_PATH>}
    s=${s//"$key_id"/<SEMPERE_ASC_KEY_ID>}
    s=${s//"$issuer"/<SEMPERE_ASC_ISSUER_ID>}
  fi
  printf '%s\n' "$s"
}
show_cmd() { local q; q=$(printf '%q ' "$@"); redact "  ${q% }"; }

echo "signing: $signing$([[ $signing == api ]] && echo " (App Store Connect API key, manual profiles)" || echo " (Xcode account, automatic)")"
echo "output:  $out"
[[ ${#lock[@]} -gt 0 ]] && echo "xcode jobs run through: ${lock[0]}"

# --- The commit ----------------------------------------------------------------------------------
git -C "$repo_root" fetch -q origin || die "git fetch origin failed"
if git -C "$repo_root" rev-parse -q --verify "refs/remotes/origin/$ref^{commit}" >/dev/null; then
  sha=$(git -C "$repo_root" rev-parse "refs/remotes/origin/$ref^{commit}")
elif sha=$(git -C "$repo_root" rev-parse -q --verify "$ref^{commit}"); then
  :
else
  if git -C "$repo_root" fetch -q origin "$ref" 2>/dev/null; then
    sha=$(git -C "$repo_root" rev-parse -q --verify "FETCH_HEAD^{commit}") || die "cannot resolve '$ref'"
  else
    die "cannot resolve '$ref' (a branch, tag or commit on origin)"
  fi
fi
echo "commit:  $(git -C "$repo_root" log --oneline -1 "$sha")"

# --- The pre-TestFlight suite gate ---------------------------------------------------------------
command -v gh >/dev/null || die "gh (GitHub CLI) is needed for the local/testflight-suite check: brew install gh, gh auth login"
# The release sweep (`just ci-release`, local/release-sweep) runs everything --testflight runs, so it counts too.
statuses=$(gh api "repos/$gh_repo/commits/$sha/status" \
  --jq '.statuses[] | select(.context == "local/testflight-suite" or .context == "local/release-sweep") | "\(.context)=\(.state)"' \
  2>/dev/null) || statuses="gh-api-failed"
state=$(sed -n 's|^local/testflight-suite=||p' <<<"$statuses" | head -1)
sweep=$(sed -n 's|^local/release-sweep=||p' <<<"$statuses" | head -1)
[[ $statuses == gh-api-failed ]] && state="unknown (gh api failed)"
state=${state:-missing}
if [[ $state == success || $sweep == success ]]; then
  if [[ $state == success ]]; then echo "local/testflight-suite: success"; else echo "local/release-sweep: success (covers the TestFlight suite)"; fi
elif [[ $skip_suite == true ]]; then
  cat >&2 <<WARN

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!  WARNING: --skip-suite-check                                                           !!
!!  local/testflight-suite is '$state' on ${sha:0:8}.
!!  This build has NOT passed the pre-TestFlight suite (Mac UI tests, smoke tests, offline !!
!!  and performance suites). Testers may get a build that fails where those tests would  !!
!!  have caught it. Run 'just ci-testflight' on this commit instead whenever you can.     !!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

WARN
  if [[ $dry == false && -t 0 ]]; then
    for i in 10 9 8 7 6 5 4 3 2 1; do printf '\rcontinuing in %2d s (Ctrl-C to stop) ' "$i" >&2; sleep 1; done
    echo >&2
  fi
else
  die "local/testflight-suite is '$state' on ${sha:0:8}: run 'just ci-testflight' (scripts/local-ci.sh --testflight) on that commit first"
fi

# --- A clean worktree of the commit (removed at exit) --------------------------------------------
work="$out/src-${sha:0:12}-$$"
# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() {
  local st=$?
  if [[ $keep == true ]]; then
    echo "kept worktree: $work"
  else
    git -C "$repo_root" worktree remove --force "$work" 2>/dev/null || rm -rf "$work"
    git -C "$repo_root" worktree prune 2>/dev/null || true
  fi
  rmdir "$out/.run-lock" 2>/dev/null || true
  save_dist_logs "$st"
  run_tmp_end
}
git -C "$repo_root" worktree add -q --detach "$work" "$sha"
trap cleanup EXIT
echo "worktree: $work"

targets=$([[ $which == both ]] && echo "ios mac" || echo "$which")
marketing=$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);/\1/p' "$work/Apps/Sempere/Sempere.xcodeproj/project.pbxproj" | sort -u | tr '\n' ' ')
echo "version: ${marketing% } (MARKETING_VERSION; the build number is assigned on upload)"

# --- Confirm the upload --------------------------------------------------------------------------
if [[ $dry == false && $export_only == false && $yes == false ]]; then
  if [[ ! -t 0 ]]; then die "not a terminal: pass --yes to upload without asking"; fi
  echo
  echo "About to archive and UPLOAD to TestFlight: $targets, version ${marketing% }, commit ${sha:0:12}."
  read -r -p "Upload to TestFlight? [y/N] " answer
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || { echo "Stopped; nothing was built or uploaded."; exit 1; }
fi

# --- Keychain (optional) -------------------------------------------------------------------------
if [[ -n ${SEMPERE_KEYCHAIN:-} ]]; then
  kc=${SEMPERE_KEYCHAIN/#\~/$HOME}
  [[ -f $kc ]] || die "SEMPERE_KEYCHAIN: no keychain at that path"
  if [[ $dry == true ]]; then
    echo "dry run: would unlock the keychain in SEMPERE_KEYCHAIN"
  elif [[ -n ${SEMPERE_KEYCHAIN_PASSWORD_FILE:-} ]]; then
    pwf=${SEMPERE_KEYCHAIN_PASSWORD_FILE/#\~/$HOME}
    [[ -r $pwf ]] || die "SEMPERE_KEYCHAIN_PASSWORD_FILE is missing or unreadable"
    security unlock-keychain -p "$(cat "$pwf")" "$kc" || die "could not unlock the keychain"
  else
    security unlock-keychain "$kc" || die "could not unlock the keychain"
  fi
fi

# Homebrew's rsync 3.x breaks Xcode's IPA packaging ("Copy failed"): the system tools first.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH

export_options() {  # $1 = ios|mac -> $out/ExportOptions-$1.plist
  local f="$out/ExportOptions-$1.plist" destination=upload signing_keys
  [[ $export_only == true ]] && destination="export"
  if [[ $signing == api ]]; then
    local profiles installer=""
    if [[ $1 == mac ]]; then
      profiles="<key>io.github.anthonytw.sempere</key><string>$profile_mac</string>"
      installer="<key>installerSigningCertificate</key><string>$installer_cert</string>"
    else
      profiles="<key>io.github.anthonytw.sempere</key><string>$profile_ios</string><key>io.github.anthonytw.sempere.widgets</key><string>$profile_widgets</string>"
    fi
    signing_keys="<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>$dist_cert</string>$installer
<key>provisioningProfiles</key><dict>$profiles</dict>"
  else
    signing_keys="<key>signingStyle</key><string>automatic</string>"
  fi
  cat > "$f" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>$destination</string>
<key>teamID</key><string>$team</string>
$signing_keys
<key>manageAppVersionAndBuildNumber</key><true/>
<key>uploadSymbols</key><true/>
</dict></plist>
PLIST
  chmod 600 "$f"
  plutil -lint "$f" >/dev/null || die "invalid export options: $f"
}

# --- Archive, then export (upload) ---------------------------------------------------------------
rc=0
for t in ios mac; do
  [[ $which == both || $which == "$t" ]] || continue
  dest='generic/platform=iOS'
  [[ $t == mac ]] && dest='generic/platform=macOS,variant=Mac Catalyst'
  export_options "$t"
  archive=(xcodebuild archive -project "$work/Apps/Sempere/Sempere.xcodeproj" -scheme SempereApp
    -configuration Release -destination "$dest" -archivePath "$out/$t.xcarchive"
    -derivedDataPath "$out/dd-$t.noindex" "DEVELOPMENT_TEAM=$team" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"})
  export_cmd=(xcodebuild -exportArchive -archivePath "$out/$t.xcarchive"
    -exportOptionsPlist "$out/ExportOptions-$t.plist" -exportPath "$out/export-$t"
    -allowProvisioningUpdates ${auth[@]+"${auth[@]}"})
  if [[ $dry == true ]]; then
    echo
    echo "== $t (dry run) =="
    echo "export options ($out/ExportOptions-$t.plist):"
    redact "$(sed 's/^/  /' "$out/ExportOptions-$t.plist")"
    echo "would run:"
    show_cmd ${lock[@]+"${lock[@]}"} "${archive[@]}"
    show_cmd ${lock[@]+"${lock[@]}"} "${export_cmd[@]}"
    continue
  fi
  rm -rf "$out/$t.xcarchive" "$out/export-$t"
  echo "$t: archiving (log: $out/$t-archive.log)"
  if ! ${lock[@]+"${lock[@]}"} "${archive[@]}" > "$out/$t-archive.log" 2>&1; then
    echo "$t: ARCHIVE FAILED"; grep -E " error:" "$out/$t-archive.log" | head -5; rc=1; continue
  fi
  echo "$t: exporting$([[ $export_only == true ]] && echo "" || echo " and uploading") (log: $out/$t-export.log)"
  if ${lock[@]+"${lock[@]}"} "${export_cmd[@]}" > "$out/$t-export.log" 2>&1; then
    if [[ $export_only == true ]]; then echo "$t: exported to $out/export-$t (not uploaded)"; else echo "$t: uploaded"; fi
  else
    echo "$t: EXPORT/UPLOAD FAILED"; grep -E "error" "$out/$t-export.log" | tail -3; rc=1
  fi
done

if [[ $dry == true ]]; then
  echo
  echo "dry run: stopped before xcodebuild archive; nothing was built or uploaded"
elif [[ $rc == 0 && $export_only == false ]]; then
  echo "Done. The build shows in App Store Connect > Sempere > TestFlight after processing (usually 5-30 minutes)."
fi
exit $rc
