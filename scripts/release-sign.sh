#!/usr/bin/env bash
# Sign a release's SHA256SUMS with YOUR SSH key, from YOUR OWN clone of GitHub (docs/releasing.md "Sign the checksums").
# You never run code the build account wrote: this script is the repository's, at origin/main, and the signers come from
# `git show origin/main:packaging/allowed_signers`. The build account's hand-off folder carries data only (SHA256SUMS).
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
#   2. copies SHA256SUMS to a private temp folder and refuses a list that is not exactly one line per tarball:
#      sempere-VERSION-{macos-universal,linux-x86_64,linux-aarch64}.tar.gz, each with a 64-hex hash
#   3. shows the list, signs the private copy (namespace `file`), and verifies the signature against origin/main's signers
#   4. only then moves SHA256SUMS and SHA256SUMS.sig into your output folder, vVERSION/, where release-publish reads them
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
if [[ ! -e $out/$tag ]]; then mkdir -m 755 "$out/$tag"; fi
"$check" owned "$out/$tag" "$(id -u)"

mkdir "$tmp/w"; cp "$drop/$tag/SHA256SUMS" "$tmp/w/SHA256SUMS"
git show "$remote/main:packaging/allowed_signers" > "$tmp/w/allowed_signers"
n=$(wc -l < "$tmp/w/SHA256SUMS" | tr -d ' ')
[[ $n == 3 ]] || die "SHA256SUMS has $n lines, not one per tarball (3)"
for p in macos-universal linux-x86_64 linux-aarch64; do
  [[ $(grep -c -E "^[0-9a-f]{64}  sempere-$version-$p\.tar\.gz\$" "$tmp/w/SHA256SUMS") == 1 ]] || die "SHA256SUMS lacks exactly one valid line for sempere-$version-$p.tar.gz"
done
echo "Signing this list:"; sed 's/^/  /' "$tmp/w/SHA256SUMS"
ssh-keygen -Y sign -f "$key" -n file "$tmp/w/SHA256SUMS" >/dev/null 2>&1 || die "ssh-keygen could not sign with $key (an agent that holds the key must be running)"
who=$(ssh-keygen -Y find-principals -f "$tmp/w/allowed_signers" -s "$tmp/w/SHA256SUMS.sig" 2>/dev/null | head -1) || true
[[ -n $who ]] || die "$key is not a key in $remote/main's packaging/allowed_signers: wrong key, nothing written"
ssh-keygen -Y verify -f "$tmp/w/allowed_signers" -I "$who" -n file -s "$tmp/w/SHA256SUMS.sig" < "$tmp/w/SHA256SUMS" >/dev/null 2>&1 \
  || die "the signature does not verify against the list"
rm -f "$out/$tag/SHA256SUMS" "$out/$tag/SHA256SUMS.sig"
mv "$tmp/w/SHA256SUMS" "$tmp/w/SHA256SUMS.sig" "$out/$tag/"
chmod 0644 "$out/$tag/SHA256SUMS" "$out/$tag/SHA256SUMS.sig"
echo "done: $out/$tag/SHA256SUMS.sig signed by $who. Next, in the build account: just release-publish $version"
