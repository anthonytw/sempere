#!/usr/bin/env bash
# Sign a release from YOUR OWN clone of GitHub: the macOS tarball with your Developer ID, then SHA256SUMS with your SSH key
# (docs/releasing.md "Sign the checksums"). You never run code the build account wrote: this script is the repository's, at
# origin/main, and the signers come from `git show origin/main:packaging/allowed_signers`. The build account's hand-off folder
# carries data only: SHA256SUMS, the unsigned macOS tarball (its sempere.app is signed here, never opened or run) and the CLI's
# Developer ID provisioning profile (fetched by the build account; verified whole here before it is used).
#
#   git fetch origin && git checkout --detach origin/main
#   bash scripts/release-sign.sh [-k KEY] VERSION
#
# KEY is a key file, or `key::ssh-ed25519 AAAA...` for a key held by ssh-agent; the default is `git config user.signingkey`
# (a .pub path needs ssh-agent to hold the key). What it does, in order:
#   1. refuses unless scripts/ and packaging/ equal origin/main's, and the hand-off folder (SEMPERE_SIGN_DROP, default
#      /Users/Shared/sempere-release, then vVERSION) and its SHA256SUMS belong to the build account (SEMPERE_BUILD_USER,
#      default claude) and are not writable by group or world; your output folder (SEMPERE_SIGN_OUT, default
#      /Users/Shared/sempere-sign) is yours and not writable by group or world (it is created, mode 755, if missing)
#   2. copies SHA256SUMS to a private temp folder and refuses a list that is not exactly one newline-terminated line per tarball:
#      sempere-VERSION-{macos-universal,linux-x86_64,linux-aarch64}.tar.gz, each with a 64-hex hash
#   3. the macOS tarball (docs/design/1.4-cloudkit.md §6.5): checks it is the one the list names, then scripts/release-sign-macos.sh
#      signs its sempere.app with your Developer ID Application identity (hardened runtime, the CLI's entitlements, the embedded
#      Developer ID profile from the hand-off folder, which scripts/release-sign-macos.sh verifies against Apple's signature, your
#      certificate and the CLI's App ID before using it: you download nothing), notarizes it (notarytool, keychain profile sempere-notary), staples it and repacks the tarball; the
#      list's macOS line becomes the signed tarball's hash. The Linux lines stay the build's
#   4. shows the list, signs the private copy (namespace `file`), and verifies the signature against origin/main's signers
#   5. only then moves SHA256SUMS, SHA256SUMS.sig and the signed macOS tarball into your output folder, vVERSION/, where
#      release-publish reads them
# Compare the list it shows with the one release-build printed: the Linux lines must be identical; the macOS line is the one that
# changes, and the script prints "build hash -> signed hash" for it (the build hash is checked against the hand-off file).
# One-time setup, and what to type: docs/releasing.md "One-time setup for the maintainer".
# Compare the printed list with the one release-build printed in its "SHA256SUMS" step. You cannot check the hashes without
# rebuilding: the signature means "the maintainer approved what the build account produced".
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "error: $*" >&2; exit 1; }
key=""
while getopts k: o; do case $o in k) key=$OPTARG ;; *) echo "usage: $0 [-k KEY] VERSION" >&2; exit 2 ;; esac; done
shift $((OPTIND - 1))
version=${1:?usage: $0 [-k KEY] VERSION}; version=${version#v}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "'$version' is not X.Y.Z or X.Y.Z-prerelease"
tag=v$version
remote=${SEMPERE_RELEASE_REMOTE:-origin}
git fetch -q "$remote" main || die "cannot fetch $remote main"
git diff --quiet "$remote/main" -- scripts/ packaging/ || die "scripts/ or packaging/ differ from $remote/main: git checkout --detach $remote/main first"
check=scripts/release-signature.sh
drop=${SEMPERE_SIGN_DROP:-/Users/Shared/sempere-release}
out=${SEMPERE_SIGN_OUT:-/Users/Shared/sempere-sign}
builder=$(id -u "${SEMPERE_BUILD_USER:-claude}" 2>/dev/null) || die "no build account ${SEMPERE_BUILD_USER:-claude} (SEMPERE_BUILD_USER)"
for p in "$drop" "$drop/$tag" "$drop/$tag/SHA256SUMS"; do "$check" owned "$p" "$builder"; done
[[ -n $key ]] || key=$(git config --get user.signingkey || true)
[[ -n $key ]] || die "no signing key: pass -k KEY or set git's user.signingkey"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [[ $key == key::* ]]; then printf '%s\n' "${key#key::}" > "$tmp/key.pub"; key=$tmp/key.pub
else key=${key/#\~/$HOME}; [[ -f $key ]] || die "the signing key $key is not a file"; fi
if [[ ! -e $out ]]; then mkdir -m 755 -p "$out"; fi
"$check" owned "$out" "$(id -u)"
# SEMPERE_SIGN_DEV=1 is a dry run of the macOS step with a development identity and profile (scripts/release-sign-macos.sh --dev):
# what it makes goes to a folder release-publish never reads.
dev=false; [[ ${SEMPERE_SIGN_DEV:-} == 1 ]] && dev=true   # only the value 1 turns the dry run on
# A dry run makes NO SSH signature at all (a development-signed set must never be publishable): no SHA256SUMS.sig is written.
dest=$out/$tag; $dev && dest=$out/$tag.dry-run
if [[ ! -e $dest ]]; then mkdir -m 755 "$dest"; fi
"$check" owned "$dest" "$(id -u)"

mkdir "$tmp/w"; cp "$drop/$tag/SHA256SUMS" "$tmp/w/SHA256SUMS"
git show "$remote/main:packaging/allowed_signers" > "$tmp/w/allowed_signers"
n=$(grep -c '' "$tmp/w/SHA256SUMS")   # counts an unterminated last line too (wc -l does not)
[[ $n == 3 ]] || die "SHA256SUMS has $n lines, not one per tarball (3)"
[[ $(tail -c1 "$tmp/w/SHA256SUMS" | od -An -tx1 | tr -d ' ') == 0a ]] || die "SHA256SUMS does not end in a newline"
if grep -vqE "^[0-9a-f]{64}  sempere-$version-(macos-universal|linux-x86_64|linux-aarch64)\\.tar\\.gz\$" "$tmp/w/SHA256SUMS"; then
  die "SHA256SUMS has a line that is not a valid tarball line (HASH  sempere-$version-PLATFORM.tar.gz)"
fi
for p in macos-universal linux-x86_64 linux-aarch64; do
  [[ $(grep -c -E "^[0-9a-f]{64}  sempere-$version-$p\.tar\.gz\$" "$tmp/w/SHA256SUMS") == 1 ]] || die "SHA256SUMS lacks exactly one valid line for sempere-$version-$p.tar.gz"
done
# The key first, before the minutes of notarization: a throwaway file signed with it must be a signer of origin/main.
echo probe > "$tmp/w/probe"
ssh-keygen -Y sign -f "$key" -n file "$tmp/w/probe" >/dev/null 2>&1 || die "ssh-keygen could not sign with $key (an agent that holds the key must be running)"
[[ -n $(ssh-keygen -Y find-principals -f "$tmp/w/allowed_signers" -s "$tmp/w/probe.sig" 2>/dev/null | head -1) ]] \
  || die "$key is not a key in $remote/main's packaging/allowed_signers: wrong key, nothing written"
rm -f "$tmp/w/probe" "$tmp/w/probe.sig"
# The macOS tarball: the hand-off folder's, as the list names it (data from the build account; release-sign-macos.sh unpacks it
# entry by entry and runs none of it). Signed and notarized here, so its hash, and the list's macOS line, change.
mac=sempere-$version-macos-universal.tar.gz
"$check" owned "$drop/$tag/$mac" "$builder"
cp "$drop/$tag/$mac" "$tmp/w/$mac.unsigned"
# The profile: data from the build account too (it fetched it from App Store Connect); release-sign-macos.sh checks it whole. A dry run
# (SEMPERE_SIGN_DEV=1) uses SEMPERE_CLI_PROFILE, a development profile, when that is set.
profile_arg=()
if $dev && [[ -n ${SEMPERE_CLI_PROFILE:-} ]]; then
  profile_arg=(--profile "$SEMPERE_CLI_PROFILE")
else
  "$check" owned "$drop/$tag/sempere-cli.provisionprofile" "$builder"
  cp "$drop/$tag/sempere-cli.provisionprofile" "$tmp/w/sempere-cli.provisionprofile"
  profile_arg=(--profile "$tmp/w/sempere-cli.provisionprofile")
fi
want=$(sed -n "s/^\([0-9a-f]\{64\}\)  $mac\$/\1/p" "$tmp/w/SHA256SUMS")
[[ $(shasum -a 256 < "$tmp/w/$mac.unsigned" | cut -d' ' -f1) == "$want" ]] || die "$drop/$tag/$mac is not the file SHA256SUMS names (build again)"
echo "Signing and notarizing $mac (your Developer ID; notarization waits for Apple)..."
bash scripts/release-sign-macos.sh $($dev && echo --dev) "${profile_arg[@]}" --version "$version" "$tmp/w/$mac.unsigned" "$tmp/w/$mac" || die "the macOS tarball was not signed: nothing written"
signed_hash=$(shasum -a 256 < "$tmp/w/$mac" | cut -d' ' -f1)
echo "macOS tarball: build hash $want (checked against the hand-off file) -> signed hash $signed_hash (this line changes in the list below; the Linux lines are the build's)"
sed "s/^[0-9a-f]\{64\}  $mac\$/$signed_hash  $mac/" "$tmp/w/SHA256SUMS" > "$tmp/w/SHA256SUMS.new" && mv "$tmp/w/SHA256SUMS.new" "$tmp/w/SHA256SUMS"
rm -f "$tmp/w/$mac.unsigned"
echo "Signing this list:"; cat -v "$tmp/w/SHA256SUMS" | sed 's/^/  /'
if $dev; then
  rm -f "$dest/SHA256SUMS" "$dest/SHA256SUMS.sig" "$dest/$mac"
  mv "$tmp/w/$mac" "$tmp/w/SHA256SUMS" "$dest/"
  echo "dry run done: $dest holds the dev-signed tarball and the list; NO signature was made, and release-publish never reads this folder"
  exit 0
fi
ssh-keygen -Y sign -f "$key" -n file "$tmp/w/SHA256SUMS" >/dev/null 2>&1 || die "ssh-keygen could not sign with $key (an agent that holds the key must be running)"
who=$(ssh-keygen -Y find-principals -f "$tmp/w/allowed_signers" -s "$tmp/w/SHA256SUMS.sig" 2>/dev/null | head -1) || true
[[ -n $who ]] || die "$key is not a key in $remote/main's packaging/allowed_signers: wrong key, nothing written"
ssh-keygen -Y verify -f "$tmp/w/allowed_signers" -I "$who" -n file -s "$tmp/w/SHA256SUMS.sig" < "$tmp/w/SHA256SUMS" >/dev/null 2>&1 \
  || die "the signature does not verify against the list"
rm -f "$dest/SHA256SUMS" "$dest/SHA256SUMS.sig" "$dest/$mac"
mv "$tmp/w/$mac" "$tmp/w/SHA256SUMS" "$tmp/w/SHA256SUMS.sig" "$dest/"
chmod 0644 "$dest/SHA256SUMS" "$dest/SHA256SUMS.sig" "$dest/$mac"
echo "done: $dest/SHA256SUMS.sig signed by $who. Next, in the build account: just release-publish $version"
