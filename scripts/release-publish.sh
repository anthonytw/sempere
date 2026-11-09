#!/usr/bin/env bash
# The GitHub Release for a tag (docs/releasing.md B.6; docs/design/local-first.md). GitHub's main is the real history
# and the tag is already on it (scripts/release-tag.sh), so there is nothing to squash or push here: this checks that
# the tag on GitHub is the one the binaries were built from, then creates the Release with the local build's files.
#
#   scripts/release-publish.sh VERSION             checks, then prints the commands (publishes nothing; the default)
#   scripts/release-publish.sh --publish VERSION   checks, then runs `gh release create` after you type the version
#
# Checks: the local tag exists and is on GitHub at the same commit, build/release/vVERSION (scripts/release-build.sh)
# has SHA256SUMS that verify, notes.md and a tarball per platform, and the release does not exist yet. `gh release
# create` needs a `gh auth login` that can write to the repository; it never needs admin. Without that login (the
# agent seat), run the printed commands yourself. Homebrew stays a separate step (`just formula`), as does the app.
# Environment: SEMPERE_RELEASE_REMOTE (default origin: GitHub), SEMPERE_RELEASE_REPO (default anthonytw/sempere).
set -euo pipefail
cd "$(dirname "$0")/.."
remote=${SEMPERE_RELEASE_REMOTE:-origin}
repo=${SEMPERE_RELEASE_REPO:-anthonytw/sempere}
publish=false
case "${1:-}" in
  --publish) publish=true; shift ;;
  -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
esac
version=${1:?usage: $0 [--publish] VERSION}; version=${version#v}
tag=v$version
die() { echo "error: $*" >&2; exit 1; }

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "no tag $tag here (just release-tag $version)"
local_sha=$(git rev-parse "$tag^{commit}")
remote_sha=$(git ls-remote "$remote" "refs/tags/$tag^{}" "refs/tags/$tag" | awk '{print $1}' | tail -1)
[[ -n $remote_sha ]] || die "$tag is not on $remote yet (just release-push $version)"
[[ $remote_sha == "$local_sha" ]] || die "$tag is ${remote_sha:0:8} on $remote but ${local_sha:0:8} here: the binaries must come from the pushed tag"
echo "ok    $tag on $remote is ${local_sha:0:8}: $(git log --oneline -1 "$local_sha")"

dist=build/release/$tag
[[ -f $dist/SHA256SUMS && -f $dist/notes.md ]] || die "no build in $dist (just release-build $version)"
(cd "$dist" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "$dist/SHA256SUMS does not match the files there"
for p in macos-universal linux-x86_64 linux-aarch64; do
  [[ -f $dist/sempere-$version-$p.tar.gz ]] || die "$dist has no sempere-$version-$p.tar.gz"
done
echo "ok    $dist: SHA256SUMS verify, notes.md and three tarballs"

pre=(); [[ $version == *-* ]] && pre=(--prerelease)
cmd=(gh release create "$tag" --repo "$repo" --verify-tag --title "Sempere CLI $tag" --notes-file "$dist/notes.md"
     ${pre[@]+"${pre[@]}"} "$dist"/*.tar.gz "$dist/SHA256SUMS")

if [[ $publish == false ]]; then
  printf '\nTo publish (nothing has been published):\n  %s\n' "${cmd[*]}"
  printf '  just formula %s ~/dev/homebrew-tap      # then test, commit and push the tap\n  just release-verify %s\n' "$version" "$version"
  exit 0
fi

command -v gh >/dev/null || die "gh is needed (brew install gh; gh auth login)"
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then die "the GitHub release $tag already exists"; fi
answer=""
[[ -t 0 ]] || die "--publish asks for the version on a terminal"
read -r -p "Type the version ($version) to publish $tag on $repo, anything else to stop: " answer
[[ $answer == "$version" ]] || { echo "Not published."; exit 0; }
"${cmd[@]}"
echo "published. Next: just formula $version ~/dev/homebrew-tap, then just release-verify $version"
