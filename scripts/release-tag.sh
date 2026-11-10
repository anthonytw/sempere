#!/usr/bin/env bash
# Tag a release on GitHub's main and push the tag (docs/releasing.md, "B. The release"; docs/design/local-first.md).
# GitHub (`origin`) holds the real history, so a tag is made on a commit of its `main` and pushed there; the Gitea
# mirror (scripts/mirror-gitea.sh) copies it. The push is asked for separately; after it come `just release-build`
# (the binaries, built here) and `just release-publish` (the GitHub Release; the owner or the script, see there).
# From 1.1.0 on the MAINTAINER makes and pushes the release tag with their own key, from their own account, and
# release-build.sh / release-publish.sh refuse a tag that does not verify against packaging/allowed_signers. The seat
# (splarg-bot) only runs --check and prints the maintainer's commands (--owner-commands); it pushes a tag only with the
# owner's explicit OK, and the typed version is a human gate an agent must never answer for the owner.
#
#   scripts/release-tag.sh VERSION [REF]          checks, then a signed tag on REF (default origin/main),
#                                                 then asks before pushing it
#   scripts/release-tag.sh --check VERSION [REF]  the checks only: no tag, no push
#   scripts/release-tag.sh --owner-commands VERSION SHA   the checks on SHA (a full commit id on origin/main), then the exact
#                                                 commands the maintainer runs to sign and push vVERSION from any clone of GitHub
#   scripts/release-tag.sh --embargo VERSION [REF]: a LOCAL tag on an unpushed fix commit (see "Embargoed fixes" below)
#   scripts/release-tag.sh --push VERSION         push an existing local tag (asks first); it re-checks only that
#                                                 the tag is on origin/main (scripts/release-build.sh checks the rest)
# Environment: SEMPERE_RELEASE_REMOTE (default origin: GitHub), SEMPERE_TAG_SIGN=false for an unsigned annotated tag
# (the tests only).
#
# Known gap: --embargo tags are signed by whoever runs this (the build account), so from 1.1.0 release-build.sh refuses
# them. Like the other gaps (docs/audits/README.md "Embargoed fixes"), it is closed when that path is first needed: the
# maintainer would sign the tag on the fix commit themselves, for example from a `git bundle` of it.
#
# The checks, run before anything is published: the commit is on
# origin/main, Version.swift there says VERSION, CHANGELOG.md there has a dated section for VERSION with no
# TODO(user) (scripts/changelog-section.sh), and the commit passed the release sweep (`just ci-release`): itself, or
# a swept ancestor with only release-neutral changes since (scripts/release-sweep-check.sh; a prerelease only warns). The tag is signed with your git signing key (`git tag -s`).
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: $0 [--check | --push | --embargo] VERSION [REF] | --owner-commands VERSION SHA   (--embargo: a local tag only, REF default HEAD)"
mode=tag
case "${1:-}" in
  --embargo) mode=embargo; shift; if [[ $# -eq 1 ]]; then set -- "$1" HEAD; fi ;;   # see "Embargoed fixes" below
  --check) mode=check; shift ;;
  --owner-commands) mode=owner; shift; [[ $# -eq 2 && ${2:-} =~ ^[0-9a-f]{40}$ ]] || { echo "usage: $0 --owner-commands VERSION SHA   (SHA: the full 40-digit commit id)" >&2; exit 2; } ;;
  --push) mode=push; shift ;;
  -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
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
# Embargoed fixes (docs/audits/README.md, "Embargoed fixes"): `--embargo VERSION [REF]` makes the signed tag on a local,
# never-pushed commit REF (default HEAD) so the release build can be made from it before the fix is public. REF must
# be one commit on top of origin/main (its one parent is on origin/main; a commit two away, a merge, or a commit
# already on origin/main is refused), and the working tree must be clean. The tag stays local and nothing is pushed.
# The repository is squash-merge only, so once the fix is on main it is a different commit: `--push` does not accept this
# tag yet (it wants the tag's commit on origin/main). The first embargoed release adds that: an embargo tag whose commit is
# off main, whose parent is on main, and whose patch-id (`git patch-id --stable`) equals a main commit's.
if [[ $mode == embargo ]]; then
  base="${remote:-origin}/main"
  embargo_ok=true
  [[ -z $(git status --porcelain --untracked-files=no) ]] || { echo "FAIL  the working tree has uncommitted changes"; embargo_ok=false; }
  parents=$(git rev-list --parents -n 1 "$sha" | wc -w)
  if git merge-base --is-ancestor "$sha" "$base"; then echo "FAIL  ${sha:0:8} is already on $base: use \`just release-tag $version\`"; embargo_ok=false
  elif (( parents != 2 )); then echo "FAIL  ${sha:0:8} must have exactly one parent (it is a root or a merge commit)"; embargo_ok=false
  elif git merge-base --is-ancestor "$sha^" "$base"; then echo "ok    parent ${sha:0:8}^ is on $base"
  else echo "FAIL  the parent of ${sha:0:8} is not on $base (an embargoed fix is one commit on top of it)"; embargo_ok=false; fi
  check cli_version; check changelog; check not_tagged
  echo "warn  release sweep not checked for an unpushed commit: run it locally (just ci-release) before the build"
  [[ $embargo_ok == true && $ok == true ]] || die "not ready to tag $tag"
  signed=signed
  if [[ ${SEMPERE_TAG_SIGN:-true} == false ]]; then signed=unsigned; git tag -a "$tag" -m "Sempere $version" "$sha"; else git tag -s "$tag" -m "Sempere $version" "$sha"; fi
  echo "created $signed tag $tag on ${sha:0:8} (local only, embargoed: NOT pushed)"
  exit 0
fi

check on_main; check cli_version; check changelog; check sweep; check not_tagged
[[ $ok == true ]] || die "not ready to tag $tag"
if [[ $mode == check ]]; then echo "ready: just release-tag $version"; exit 0; fi
if [[ $mode == owner ]]; then
  cat <<EOF2

The maintainer signs and pushes $tag, from their own account. Any clone of GitHub works (the first time:
\`git clone https://github.com/anthonytw/sempere && cd sempere\`); git's SSH signing must be set up (gpg.format=ssh,
user.signingkey). The block stops at the first failed step, so nothing is pushed after a failure; it pushes this one tag,
by name. Read the commit it shows. After a failed \`tag -v\`, delete the local tag with \`git tag -d $tag\`.

( set -e
  git fetch origin main
  git log -1 --format='%H %s' $sha
  git merge-base --is-ancestor $sha origin/main
  git show $sha:Sources/SempereCLI/Version.swift | grep -Fqx 'let sempereVersion = "$version"'
  git show origin/main:packaging/allowed_signers > "\${TMPDIR:-/tmp}/sempere-allowed-signers"
  git tag -s $tag $sha -m "Sempere $version"
  git -c gpg.ssh.allowedSignersFile="\${TMPDIR:-/tmp}/sempere-allowed-signers" tag -v $tag
  git push origin refs/tags/$tag )

\`git tag -v\` must say Good "git" signature for maintainer. Then the build account runs: just release-build $version
EOF2
  exit 0
fi
if [[ ${SEMPERE_TAG_SIGN:-true} == false ]]; then git tag -a "$tag" -m "Sempere $version" "$sha"; else git tag -s "$tag" -m "Sempere $version" "$sha"; fi
echo "created signed tag $tag on ${sha:0:8} (local only)"
confirm_push
