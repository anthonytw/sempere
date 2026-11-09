#!/usr/bin/env bash
# Tag a release on GitHub's main and push the tag (docs/releasing.md, "B. The release"; docs/design/local-first.md).
# GitHub (`origin`) holds the real history, so a tag is made on a commit of its `main` and pushed there; the Gitea
# mirror (scripts/mirror-gitea.sh) copies it. The push is asked for separately; after it come `just release-build`
# (the binaries, built here) and `just release-publish` (the GitHub Release; the owner or the script, see there).
# Pushing a tag needs write access only, never admin; the seat has neither, so the owner pushes.
#
#   scripts/release-tag.sh VERSION [REF]          checks, then a signed tag on REF (default origin/main),
#                                                 then asks before pushing it
#   scripts/release-tag.sh --check VERSION [REF]  the checks only: no tag, no push
#   scripts/release-tag.sh --push VERSION         push an existing local tag (asks first); it re-checks only that
#                                                 the tag is on origin/main (scripts/release-build.sh checks the rest)
# Environment: SEMPERE_RELEASE_REMOTE (default origin: GitHub), SEMPERE_TAG_SIGN=false for an unsigned annotated tag
# (the tests only).
#
# The checks, run before anything is published: the commit is on
# origin/main, Version.swift there says VERSION, CHANGELOG.md there has a dated section for VERSION with no
# TODO(user) (scripts/changelog-section.sh), and the commit passed the release sweep (`just ci-release`): itself, or
# a swept ancestor with only release-neutral changes since (scripts/release-sweep-check.sh; a prerelease only warns). The tag is signed with your git signing key (`git tag -s`).
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: $0 [--check | --push] VERSION [REF]"
mode=tag
case "${1:-}" in
  --check) mode=check; shift ;;
  --push) mode=push; shift ;;
  -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
esac
[[ $# -ge 1 && $# -le 2 ]] || { echo "$usage" >&2; exit 2; }
version=${1#v}
remote=${SEMPERE_RELEASE_REMOTE:-origin}
ref=${2:-$remote/main}
tag=v$version
die() { echo "error: $*" >&2; exit 1; }
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "'$1' is not X.Y.Z or X.Y.Z-prerelease"
prerelease=false
[[ $version == *-* ]] && prerelease=true

confirm_push() {
  echo
  echo "Pushing $tag to $remote (GitHub) makes it the release. The Gitea mirror copies it within minutes."
  local answer=""
  if [[ -t 0 ]]; then read -r -p "Type the version ($version) to push $tag to $remote, anything else to stop: " answer; fi
  if [[ $answer == "$version" ]]; then
    git push "$remote" "refs/tags/$tag"
    echo "pushed $tag. Next: just release-build $version, then just release-publish $version"
  else
    echo "Not pushed. Push later with: just release-push $version   (or delete the local tag: git tag -d $tag)"
  fi
}

git fetch -q --tags "$remote"

if [[ $mode == push ]]; then
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "no local tag $tag (make it with: just release-tag $version)"
  git ls-remote --exit-code --tags "$remote" "refs/tags/$tag" >/dev/null 2>&1 && die "$tag is already on $remote"
  sha=$(git rev-parse "$tag^{commit}")
  git merge-base --is-ancestor "$sha" "$remote/main" || die "$tag points at ${sha:0:8}, which is not on $remote/main"
  git tag -v "$tag" >/dev/null 2>&1 || echo "warning: git cannot verify $tag's signature here (gpg.ssh.allowedSignersFile?)"
  echo "$tag -> $(git log --oneline -1 "$sha")"
  confirm_push
  exit 0
fi

sha=$(git rev-parse -q --verify "$ref^{commit}") || die "cannot resolve $ref"
echo "commit: $(git log --oneline -1 "$sha")"
ok=true
check() { if "$@"; then :; else ok=false; fi; }

on_main() { git merge-base --is-ancestor "$sha" "$remote/main" || { echo "FAIL  ${sha:0:8} is not on $remote/main"; return 1; }; echo "ok    on $remote/main"; }
cli_version() {
  local v; v=$(git show "$sha:Sources/SempereCLI/Version.swift" | sed -n 's/^let sempereVersion = "\(.*\)"$/\1/p')
  [[ $v == "$version" ]] || { echo "FAIL  Version.swift says '$v', not $version (just release-prep $version)"; return 1; }
  echo "ok    Version.swift = $version"
}
changelog() {
  local f; f=$(mktemp); git show "$sha:CHANGELOG.md" > "$f"
  if scripts/changelog-section.sh --file "$f" "$version" >/dev/null 2>"$f.err"; then
    echo "ok    CHANGELOG.md: $(grep -m1 "^## \[$version\]" "$f")"; rm -f "$f" "$f.err"
  else
    echo "FAIL  $(sed -e "s|$f|CHANGELOG.md|" -e 's/^error: //' "$f.err")"; rm -f "$f" "$f.err"; return 1
  fi
}
sweep() {
  local line
  if line=$(scripts/release-sweep-check.sh "$sha"); then echo "$line"; return 0; fi
  if [[ $prerelease == true ]]; then echo "warn  ${line#FAIL  } (a prerelease only warns)"; return 0; fi
  echo "$line"; return 1
}
not_tagged() {
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then echo "FAIL  tag $tag already exists here"; return 1; fi
  if git ls-remote --exit-code --tags "$remote" "refs/tags/$tag" >/dev/null 2>&1; then echo "FAIL  tag $tag already exists on $remote"; return 1; fi
  echo "ok    $tag is free"
}
check on_main; check cli_version; check changelog; check sweep; check not_tagged
[[ $ok == true ]] || die "not ready to tag $tag"
if [[ $mode == check ]]; then echo "ready: just release-tag $version"; exit 0; fi

if [[ ${SEMPERE_TAG_SIGN:-true} == false ]]; then git tag -a "$tag" -m "Sempere $version" "$sha"; else git tag -s "$tag" -m "Sempere $version" "$sha"; fi
echo "created signed tag $tag on ${sha:0:8} (local only)"
confirm_push
