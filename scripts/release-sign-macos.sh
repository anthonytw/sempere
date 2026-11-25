#!/usr/bin/env bash
# Sign, notarize and repack the macOS release tarball (docs/design/1.4-cloudkit.md §6.5; docs/releasing.md "Sign the checksums").
# release-sign.sh runs this, on the maintainer's own account, on the tarball the build account handed off; it can also be
# run alone:
#
#   scripts/release-sign-macos.sh [--dev] [--profile FILE] --version X.Y.Z IN.tar.gz OUT.tar.gz
#   scripts/release-sign-macos.sh [--dev] --check-profile FILE      only judge the profile, as signing does (scripts/test-profile-check.sh)
#
# IN is the build account's tarball: DATA. Nothing in it is executed. It is checked entry by entry (only the files the build
# makes, no link, no path outside the folder), and only its `sempere` binary is taken: the bundle's Info.plist, the
# entitlements are this checkout's (packaging/cli), and the provisioning profile (FILE: release-sign.sh passes the hand-off folder's,
# which the build account fetched from the App Store Connect API) is DATA that is verified whole before one byte of it is used (step
# 2), so the build account cannot change what the signature vouches for beyond the binary itself, which is what the maintainer
# approves by signing. Steps:
#   1. checks the tarball's entries and unpacks them in a private folder
#   2. makes the bundle again (scripts/cli-bundle.sh) from the binary alone (it must be universal; fonts, Info.plist and entitlements
#      are this checkout's), verifies the provisioning profile and embeds it. Verified: Apple's own CMS signature and its chain to
#      an Apple root of the system's trust store (`openssl smime -verify`: `security cms -D` decodes a profile whose content was
#      changed without a word, so it is not used to judge one), the signer is Apple's provisioning-profile signing certificate, the
#      CLI's App ID on the profile's team, the iCloud container, a Developer ID profile for macOS (no device list), not expired, and
#      it lists YOUR signing certificate (the one the identity names), whose team is the profile's
#   3. entitlements from packaging/cli/entitlements.plist, the team and App ID taken from the profile (no team identifier lives
#      in the repository), the container environment Production
#   4. codesign with the Developer ID Application identity: hardened runtime, secure timestamp, those entitlements
#   5. notarizes (`xcrun notarytool submit --wait --keychain-profile sempere-notary`) and staples the ticket to the bundle
#   6. checks the result with codesign and spctl, and repacks OUT.tar.gz (the same layout as the build's tarball)
# One-time setup (docs/releasing.md): the "Developer ID Application" certificate and its private key in your keychain, and
# `xcrun notarytool store-credentials sempere-notary`. The profile needs nothing of you: the build account puts it in the
# hand-off folder, and this script checks it. Settings in $SEMPERE_RELEASE_ENV (default ~/.config/sempere/release.env) or the environment:
#   SEMPERE_CLI_PROFILE      a profile file to use instead of --profile (a --dev dry run's development profile)
#   SEMPERE_SIGN_IDENTITY    the codesign identity (default "Developer ID Application")
#   SEMPERE_SIGN_KEYCHAIN    a keychain to look in (default: the search list)
#   SEMPERE_NOTARY_PROFILE   notarytool's keychain profile (default sempere-notary)
# --dev: a dry run with a DEVELOPMENT identity and profile (default identity "Apple Development", a development profile for
# the CLI App ID, container environment Development, no notarization, no stapling): it proves the whole path up to Apple's
# service, and the result runs CloudKit's development environment. It is never a release file.
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "error: $*" >&2; exit 1; }
dev=false check_only=false version="" profile="" args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --dev) dev=true; shift ;;
    --version) version=${2:?--version X.Y.Z}; shift 2 ;;
    --profile) profile=${2:?--profile FILE}; shift 2 ;;
    --check-profile) check_only=true; profile=${2:?--check-profile FILE}; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) args+=("$1"); shift ;;
  esac
done
$check_only || [[ ${#args[@]} == 2 && -n $version ]] || { echo "usage: $0 [--dev] [--profile FILE] --version X.Y.Z IN.tar.gz OUT.tar.gz" >&2; exit 2; }
in=${args[0]:-}; outfile=${args[1]:-}
$check_only || [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "'$version' is not X.Y.Z or X.Y.Z-prerelease"
[[ $(uname) == Darwin ]] || die "macOS signing runs on a Mac"
$check_only || [[ -f $in && ! -L $in ]] || die "$in is not a regular file"
env_file=${SEMPERE_RELEASE_ENV:-$HOME/.config/sempere/release.env}
if [[ -f $env_file ]]; then   # a variable set in the environment wins over the file, as in testflight.sh
  while IFS='=' read -r k v; do
    [[ $k == SEMPERE_CLI_PROFILE || $k == SEMPERE_SIGN_IDENTITY || $k == SEMPERE_SIGN_KEYCHAIN || $k == SEMPERE_NOTARY_PROFILE ]] || continue
    v=${v%\"}; v=${v#\"}; v=${v/#\~/$HOME}
    [[ -n ${!k:-} ]] || export "$k=$v"
  done < "$env_file"
fi
[[ -n $profile ]] || profile=${SEMPERE_CLI_PROFILE:-}
[[ -n $profile ]] || die "no provisioning profile: pass --profile FILE (release-sign.sh passes the hand-off folder's sempere-cli.provisionprofile)"
profile=${profile/#\~/$HOME}
[[ -f $profile && ! -L $profile ]] || die "the profile $profile is not a regular file"
identity=${SEMPERE_SIGN_IDENTITY:-Developer ID Application}
$dev && identity=${SEMPERE_SIGN_IDENTITY:-Apple Development}
notary=${SEMPERE_NOTARY_PROFILE:-sempere-notary}
name=sempere-$version-macos-universal

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

# The profile is data from the build account: judged whole, before any of it is used (a function so that --check-profile and the tests
# run exactly what signing runs). `security cms -D` decodes a profile whose signed content was changed (it reports DigestMismatch only
# with -h, and exits 0), so Apple's signature is checked with openssl against the Apple roots of the system's trust store. Sets
# app_id, team and identity_sha1. Needs $tmp, $profile, $dev and $identity.
verify_profile() {
  [[ -x /usr/bin/openssl ]] || die "/usr/bin/openssl is missing: it verifies the profile's signature"
  security find-certificate -a -c "Apple Root CA" -p /System/Library/Keychains/SystemRootCertificates.keychain > "$tmp/apple-roots.pem" 2>/dev/null || true
  grep -q 'BEGIN CERTIFICATE' "$tmp/apple-roots.pem" || die "no Apple root certificates in the system keychain"
  # The file is exactly one DER message: bytes after it would be embedded unverified.
  local head hl len size
  head=$(/usr/bin/openssl asn1parse -inform DER -in "$profile" 2>/dev/null | head -1) || true
  hl=$(sed -n 's/.*hl= *\([0-9][0-9]*\) l= *\([0-9][0-9]*\) cons.*/\1/p' <<<"$head"); len=$(sed -n 's/.*hl= *\([0-9][0-9]*\) l= *\([0-9][0-9]*\) cons.*/\2/p' <<<"$head")
  size=$(wc -c < "$profile" | tr -d ' ')
  [[ -n $hl && -n $len && $((hl + len)) == "$size" ]] || die "$profile is not one DER-encoded message (unreadable, truncated, or bytes after the signed data)"
  /usr/bin/openssl smime -verify -inform DER -in "$profile" -CAfile "$tmp/apple-roots.pem" -purpose smimesign -signer "$tmp/profile-signer.pem" \
    -out "$tmp/profile.plist" >/dev/null 2>"$tmp/verify.err" \
    || die "$profile is not a provisioning profile signed by Apple (its signature or its chain to an Apple root does not verify): $(head -c 200 "$tmp/verify.err" | tr '\n' ' ')"
  [[ $(grep -c 'BEGIN CERTIFICATE' "$tmp/profile-signer.pem") == 1 ]] || die "the profile has more than one signer"
  [[ $(/usr/bin/openssl x509 -in "$tmp/profile-signer.pem" -noout -subject -nameopt RFC2253) == "subject= C=US,O=Apple Inc.,CN=Mac OS X Provisioning Profile Signing" ]] \
    || die "the profile is not signed by Apple's \"Mac OS X Provisioning Profile Signing\" certificate"
  [[ $(/usr/bin/openssl x509 -in "$tmp/profile-signer.pem" -noout -issuer -nameopt RFC2253) == "issuer= C=US,O=Apple Inc.,OU="*",CN=Apple Worldwide Developer Relations Certification Authority" ]] \
    || die "the profile's signer was not issued by Apple's Worldwide Developer Relations CA"
  /usr/bin/openssl x509 -in "$tmp/profile-signer.pem" -noout -text | grep -q '1\.2\.840\.113635\.100\.4\.11' \
    || die "the profile's signer lacks Apple's provisioning-profile signing extension (1.2.840.113635.100.4.11)"
  plutil -lint "$tmp/profile.plist" >/dev/null || die "the profile's content is not a property list"
  pl() { plutil -extract "$1" raw -o - "$tmp/profile.plist" 2>/dev/null || true; }
  app_id=$(pl 'Entitlements.com\.apple\.application-identifier')
  team=$(pl 'Entitlements.com\.apple\.developer\.team-identifier')
  [[ $team =~ ^[A-Z0-9]{10}$ ]] || die "the profile's team identifier '$team' is not ten letters and digits"
  [[ $app_id == "$team.io.github.anthonytw.sempere.cli" ]] || die "the profile is for '$app_id', not $team.io.github.anthonytw.sempere.cli"
  [[ $(pl 'TeamIdentifier.0') == "$team" ]] || die "the profile's team identifiers disagree"
  [[ $(pl 'Platform.0') == OSX ]] || die "the profile is not a macOS profile (platform '$(pl 'Platform.0')')"
  plutil -extract 'Entitlements.com\.apple\.developer\.icloud-container-identifiers' json -o - "$tmp/profile.plist" 2>/dev/null \
    | grep -q '"iCloud.io.github.anthonytw.sempere"' || die "the profile does not list the container iCloud.io.github.anthonytw.sempere"
  if $dev; then
    [[ -n $(pl ProvisionedDevices.0) ]] || die "a --dev run needs a development profile (it lists devices)"
  else
    [[ -z $(pl ProvisionedDevices.0) ]] || die "the profile lists devices: it is a development profile, not Developer ID"
  fi
  local expires created
  expires=$(pl ExpirationDate)
  [[ -n $expires ]] || die "the profile has no expiry date"
  [[ $(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$expires" +%s 2>/dev/null || echo 0) -gt $(date +%s) ]] || die "the profile expired on $expires: the build account makes a new one (docs/releasing.md)"
  created=$(pl CreationDate)
  [[ -z $created || $(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$created" +%s 2>/dev/null || echo 0) -le $(date +%s) ]] || die "the profile's creation date ($created) is in the future"
  # It must be for YOUR certificate: the one codesign will use (resolved once, by its SHA-1) has to be one the profile lists.
  local ids=(security find-identity -v -p codesigning) matches
  [[ -z ${SEMPERE_SIGN_KEYCHAIN:-} ]] || ids+=("$SEMPERE_SIGN_KEYCHAIN")
  matches=$("${ids[@]}" 2>/dev/null | awk -v want="$identity" 'index($0, "\"" ) && index($0, want) {print $2}' | sort -u)
  [[ -n $matches ]] || die "no signing identity \"$identity\" in your keychain (docs/releasing.md \"The macOS CLI's Developer ID signing\")"
  [[ $(wc -l <<<"$matches" | tr -d ' ') == 1 ]] || die "\"$identity\" names more than one identity in your keychain; set SEMPERE_SIGN_IDENTITY to a longer name"
  identity_sha1=$matches
  local listed=false i=0 cert h
  while cert=$(pl "DeveloperCertificates.$i") && [[ -n $cert ]]; do
    h=$(printf '%s' "$cert" | /usr/bin/openssl base64 -d -A 2>/dev/null | shasum -a 1 | cut -d' ' -f1 | tr 'a-f' 'A-F')
    if [[ $h == "$identity_sha1" ]]; then listed=true; break; fi
    i=$((i + 1))
  done
  $listed || die "the profile does not list your \"$identity\" certificate: it was made for another certificate; the build account makes the profile again with yours"
}
if $check_only; then verify_profile; echo "ok    $profile is acceptable (team $team)"; exit 0; fi

# 1. The tarball is data: every entry is a plain file or folder below $name/, with names from a short list.
[[ $(head -c2 "$in" | od -An -tx1 | tr -d ' \n') == 1f8b ]] || die "$in is not gzip data (bad magic)"
[[ $(gzip -dc < "$in" 2>/dev/null | dd bs=1 skip=257 count=5 2>/dev/null) == ustar ]] || die "$in does not hold a tar archive (no ustar header after gunzip)"
tar -tzf "$in" > "$tmp/names" || die "$in is not a readable tar.gz"
tar -tvzf "$in" | cut -c1 | sort -u > "$tmp/types"
if grep -vqE '^[-d]$' "$tmp/types"; then die "$in holds an entry that is not a plain file or folder (a link or a device): refused"; fi
while IFS= read -r n; do
  case $n in
    "$name/"|"$name") ;;
    "$name/sempere.app/"*|"$name/docs/"*|"$name/docs"|"$name/LICENSE"|"$name/LICENSE-EXCEPTION"|"$name/README.md"|"$name/CHANGELOG.md") ;;
    *) die "$in holds $(printf '%q' "$n"), which a release tarball does not: refused" ;;
  esac
  case $n in */._*|._*) die "$in holds an AppleDouble entry ($(printf '%q' "$n")): refused" ;; esac
  case $n in *..*|/*) die "$in holds a path with .. or a leading /: refused" ;; esac
done < "$tmp/names"
mkdir "$tmp/in"
tar -xzf "$in" -C "$tmp/in" --no-same-owner --no-same-permissions --no-xattrs --no-mac-metadata
src=$tmp/in/$name
bin=$src/sempere.app/Contents/MacOS/sempere
[[ -f $bin && ! -L $bin ]] || die "$in has no sempere.app/Contents/MacOS/sempere"
file "$bin" | grep -q 'Mach-O' || die "the sempere in $in is not a Mach-O executable"
# Only the binary comes from the build account: the fonts are this checkout's, the Info.plist and entitlements too.
$dev || { lipo -archs "$bin" | tr ' ' '\n' | grep -qx arm64 && lipo -archs "$bin" | tr ' ' '\n' | grep -qx x86_64; } \
  || die "the binary is not universal (arm64 and x86_64): $(lipo -archs "$bin" 2>&1)"
fonts=Sources/SempereFonts/Fonts
[[ -f $fonts/NotoSans-Bold.ttf ]] || die "no fonts in $fonts: run this from a full checkout of origin/main"

# 2. The bundle again, from the binary alone; this checkout's fonts and Info.plist.
mkdir "$tmp/out"
scripts/cli-bundle.sh "$bin" "$version" "$tmp/out" "$fonts" >/dev/null
app=$tmp/out/sempere.app
verify_profile
cp "$profile" "$app/Contents/embedded.provisionprofile"

# 3. Entitlements.
if $dev; then env_value=Development; else env_value=Production; fi
sed "s/@APPLICATION_IDENTIFIER@/$app_id/; s/@TEAM_IDENTIFIER@/$team/; s/@CONTAINER_ENVIRONMENT@/$env_value/" packaging/cli/entitlements.plist > "$tmp/entitlements.plist"
plutil -lint "$tmp/entitlements.plist" >/dev/null || die "the entitlements are not a property list"
! grep -qE '@[A-Z_]+@' "$tmp/entitlements.plist" || { grep -nE '@[A-Z_]+@' "$tmp/entitlements.plist" >&2; die "an entitlement value was not filled in"; }

# 4. Sign.
sign=(codesign --force --sign "$identity_sha1" --entitlements "$tmp/entitlements.plist")
[[ -z ${SEMPERE_SIGN_KEYCHAIN:-} ]] || sign+=(--keychain "$SEMPERE_SIGN_KEYCHAIN")
$dev || sign+=(--options runtime --timestamp)
"${sign[@]}" "$app" || die "codesign failed: is the \"$identity\" identity, with its private key, in your keychain?"
codesign --verify --strict --deep "$app" || die "the signature does not verify"
codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q 'iCloud.io.github.anthonytw.sempere' || die "the signed bundle lacks the container entitlement"
echo "ok    signed with \"$identity\" (team $team)"

# 5. Notarize and staple (a Developer ID release only).
if $dev; then
  echo "warn  --dev: not notarized, not stapled; this bundle is for a dry run and never a release"
else
  ditto -c -k --keepParent "$app" "$tmp/notarize.zip"
  echo "notarizing (this waits for Apple, usually a few minutes)..."
  if ! xcrun notarytool submit "$tmp/notarize.zip" --keychain-profile "$notary" --wait --output-format plist > "$tmp/notary.plist" 2> "$tmp/notary.err"; then
    cat "$tmp/notary.err" >&2; die "notarytool failed (xcrun notarytool store-credentials $notary, once; docs/releasing.md)"
  fi
  status=$(plutil -extract status raw -o - "$tmp/notary.plist" 2>/dev/null || echo unknown)
  if [[ $status != Accepted ]]; then
    id=$(plutil -extract id raw -o - "$tmp/notary.plist" 2>/dev/null || true)
    [[ -z $id ]] || xcrun notarytool log "$id" --keychain-profile "$notary" >&2 || true
    die "Apple's notarization says '$status', not Accepted"
  fi
  xcrun stapler staple "$app" >/dev/null || die "stapler could not staple the ticket"
  xcrun stapler validate "$app" >/dev/null || die "the stapled ticket does not validate"
  spctl --assess --type execute --verbose=2 "$app" 2>&1 | sed 's/^/      /' || die "Gatekeeper refuses the bundle"
  echo "ok    notarized and stapled"
fi

# 6. Repack: the build's layout, with the signed bundle.
rm -rf "$src/sempere.app"
mkdir -p "$tmp/pack"
cp -R "$src" "$tmp/pack/$name"
rm -rf "$tmp/pack/$name/sempere.app"
cp -R "$app" "$tmp/pack/$name/sempere.app"
mkdir -p "$(dirname "$outfile")"
COPYFILE_DISABLE=1 tar -C "$tmp/pack" -czf "$tmp/$name.tar.gz" "$name"
mv "$tmp/$name.tar.gz" "$outfile"
echo "ok    $outfile"
