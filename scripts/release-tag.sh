#!/usr/bin/env bash
# Tag a release and push the tag (docs/releasing.md, "B. The release"). Pushing `vX.Y.Z` starts
# .github/workflows/release.yml, which publishes the GitHub Release: the push is asked for separately.
#
#   scripts/release-tag.sh VERSION [REF]          checks, then a signed tag on REF (default origin/main),
#                                                 then asks before pushing it
#   scripts/release-tag.sh --check VERSION [REF]  the checks only: no tag, no push
#   scripts/release-tag.sh --push VERSION         push an existing local tag (asks first); it re-checks only that
#                                                 the tag is on origin/main: release.yml's prepare job checks the rest
#
# The checks are release.yml's `prepare` job, run before anything is published: the commit is on
# origin/main, Version.swift there says VERSION, CHANGELOG.md there has a dated section for VERSION with no
# TODO(user) (scripts/changelog-section.sh), and the commit has a successful `local/release-sweep` status
# (`just ci-release`; a prerelease only warns). The tag is signed with your git signing key (`git tag -s`).
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: $0 [--check | --push] VERSION [REF]"
mode=tag
case "${1:-}" in
  --check) mode=check; shift ;;
  --push) mode=push; shift ;;
  -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
esac
[[ $# -ge 1 && $# -le 2 ]] || { echo "$usage" >&2; exit 2; }
version=${1#v}
ref=${2:-origin/main}
tag=v$version
gh_repo=${SEMPERE_GH_REPO:-anthonytw/sempere}
die() { echo "error: $*" >&2; exit 1; }
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "'$1' is not X.Y.Z or X.Y.Z-prerelease"
prerelease=false
[[ $version == *-* ]] && prerelease=true

confirm_push() {
  echo
  echo "Pushing $tag starts the release workflow, which publishes a GitHub Release and its binaries."
  local answer=""
  if [[ -t 0 ]]; then read -r -p "Type the version ($version) to push $tag to origin, anything else to stop: " answer; fi
  if [[ $answer == "$version" ]]; then
    git push origin "refs/tags/$tag"
    echo "pushed $tag. Watch it: gh run watch --repo $gh_repo \$(gh run list --repo $gh_repo --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
    echo "Then: just release-verify $version"
  else
    echo "Not pushed. Push later with: just release-push $version   (or delete the local tag: git tag -d $tag)"
  fi
}

git fetch -q --tags origin

if [[ $mode == push ]]; then
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "no local tag $tag (make it with: just release-tag $version)"
  git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 && die "$tag is already on origin"
  sha=$(git rev-parse "$tag^{commit}")
  git merge-base --is-ancestor "$sha" origin/main || die "$tag points at ${sha:0:8}, which is not on origin/main"
  git tag -v "$tag" >/dev/null 2>&1 || echo "warning: git cannot verify $tag's signature here (gpg.ssh.allowedSignersFile?)"
  echo "$tag -> $(git log --oneline -1 "$sha")"
  confirm_push
  exit 0
fi

sha=$(git rev-parse -q --verify "$ref^{commit}") || die "cannot resolve $ref"
echo "commit: $(git log --oneline -1 "$sha")"
ok=true
check() { if "$@"; then :; else ok=false; fi; }

on_main() { git merge-base --is-ancestor "$sha" origin/main || { echo "FAIL  ${sha:0:8} is not on origin/main"; return 1; }; echo "ok    on origin/main"; }
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
  local state
  state=$(gh api "repos/$gh_repo/commits/$sha/status" \
    --jq '[.statuses[] | select(.context == "local/release-sweep")][0].state // "missing"' 2>/dev/null) || state="unknown (gh api failed)"
  if [[ $state == success ]]; then echo "ok    local/release-sweep: success"; return 0; fi
  if [[ $prerelease == true ]]; then echo "warn  local/release-sweep is $state (a prerelease only warns)"; return 0; fi
  echo "FAIL  local/release-sweep is $state on ${sha:0:8}: run 'just ci-release' on that commit"; return 1
}
not_tagged() {
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then echo "FAIL  tag $tag already exists here"; return 1; fi
  if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then echo "FAIL  tag $tag already exists on origin"; return 1; fi
  echo "ok    $tag is free"
}
check on_main; check cli_version; check changelog; check sweep; check not_tagged
[[ $ok == true ]] || die "not ready to tag $tag"
if [[ $mode == check ]]; then echo "ready: just release-tag $version"; exit 0; fi

git tag -s "$tag" -m "Sempere $version" "$sha"
echo "created signed tag $tag on ${sha:0:8} (local only)"
confirm_push
