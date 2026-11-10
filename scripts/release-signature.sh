#!/usr/bin/env bash
# Checks on the maintainer's signatures (SECURITY.md "Verifying releases"). The maintainer signs release tags and each
# release's SHA256SUMS with their own SSH key, on their own account, never on the build account (scripts/release-sign.sh
# signs; docs/releasing.md). This script only verifies:
#
#   scripts/release-signature.sh verify DIR        checks DIR/SHA256SUMS against DIR/SHA256SUMS.sig
#   scripts/release-signature.sh verify-tag VERSION   a release tag from 1.1.0 on (not a prerelease) must be a tag object
#                                                  named vVERSION that verifies against the signers file; older
#                                                  versions and prereleases pass unchecked
#   scripts/release-signature.sh owned PATH UID|any   PATH (a folder or file) is not a symlink, is owned by UID (or any)
#                                                  and is not writable by group or world: the hand-off folders have
#                                                  one writer each (docs/releasing.md)
#
# The signers file is packaging/allowed_signers (`ssh-keygen -Y verify` format; its lines are published in SECURITY.md);
# there is no way to name another one. The namespace of SHA256SUMS.sig is `file`.
set -euo pipefail
cd "$(dirname "$0")/.."
signers=packaging/allowed_signers
die() { echo "error: $*" >&2; exit 1; }

verify() {   # DIR
  local d=$1
  [[ -f $signers ]] || die "no $signers: add the maintainer's line (see SECURITY.md)"
  [[ -f $d/SHA256SUMS.sig ]] || die "no $d/SHA256SUMS.sig"
  local who
  who=$(ssh-keygen -Y find-principals -f "$signers" -s "$d/SHA256SUMS.sig" 2>/dev/null | head -1) || true
  [[ -n $who ]] || die "$d/SHA256SUMS.sig is not signed by a key in $signers"
  ssh-keygen -Y verify -f "$signers" -I "$who" -n file -s "$d/SHA256SUMS.sig" < "$d/SHA256SUMS" >/dev/null 2>&1 \
    || die "$d/SHA256SUMS.sig does not verify against $d/SHA256SUMS"
  echo "ok    SHA256SUMS signed by $who"
}

verify_tag() {   # VERSION
  local version=${1#v} tag=v${1#v} major minor
  [[ $version =~ ^([0-9]+)\.([0-9]+)\.[0-9]+(-.+)?$ ]] || die "'$1' is not a version"
  major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}
  if [[ $version == *-* ]] || (( major < 1 || (major == 1 && minor < 1) )); then
    echo "warn  $tag's signature is not checked (only releases from 1.1.0 on, not prereleases, must be signed by the maintainer)"
    return 0
  fi
  [[ -f $signers ]] || die "no $signers: add the maintainer's line (see SECURITY.md)"
  git -c gpg.ssh.allowedSignersFile="$signers" tag -v "$tag" >/dev/null 2>&1 \
    || die "tag $tag is not signed by a key in $signers: the maintainer makes and pushes release tags (scripts/release-tag.sh --owner-commands)"
  # A maintainer-signed tag object put under another name would verify too: the ref must be a tag object that says vX.
  [[ $(git cat-file -t "refs/tags/$tag" 2>/dev/null) == tag ]] || die "$tag is not an annotated tag object"
  [[ $(git cat-file tag "refs/tags/$tag" | sed -n 's/^tag //p;/^$/q') == "$tag" ]] || die "the tag object at $tag is named something else (a renamed tag)"
  echo "ok    $tag is signed by a key in $signers"
}

owned() {   # PATH UID|any
  local f=$1 want=$2 uid perm
  [[ -e $f && ! -L $f ]] || die "$f is missing or a symlink"
  read -r uid perm < <(stat -c '%u %a' "$f" 2>/dev/null || stat -f '%u %Lp' "$f")
  [[ $want == any || $uid == "$want" ]] || die "$f is owned by uid $uid, not $want"
  (( (8#$perm & 8#022) == 0 )) || die "$f (mode $perm) is writable by group or world"
}

case ${1:-} in
  owned) owned "${2:?usage: $0 owned PATH UID|any}" "${3:?usage: $0 owned PATH UID|any}" ;;
  verify) verify "${2:?usage: $0 verify DIR}" ;;
  verify-tag) verify_tag "${2:?usage: $0 verify-tag VERSION}" ;;
  *) sed -n '2,9p' "$0" >&2; exit 2 ;;
esac
