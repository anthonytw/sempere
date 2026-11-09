#!/usr/bin/env bash
# Check a published release (docs/releasing.md B.6): GitHub's tag is the commit the binaries were built from, the Gitea
# mirror has the same tag, and the published assets match SHA256SUMS (and the local build, when it is here).
#
#   scripts/release-verify.sh VERSION
#
# Reads GitHub anonymously. The mirror check runs only where a `gitea` remote exists and only warns (the mirror
# runs every ten minutes). Environment: SEMPERE_RELEASE_REMOTE (default origin), SEMPERE_RELEASE_REPO
# (default anthonytw/sempere), SEMPERE_RELEASE_URL (default https://github.com/$repo, for the assets).
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:?usage: $0 VERSION}; version=${version#v}
tag=v$version
remote=${SEMPERE_RELEASE_REMOTE:-origin}
repo=${SEMPERE_RELEASE_REPO:-anthonytw/sempere}
url=${SEMPERE_RELEASE_URL:-https://github.com/$repo}
peeled() { git ls-remote "$1" "refs/tags/$tag^{}" "refs/tags/$tag" | awk '{print $1}' | tail -1; }

gh_sha=$(peeled "$remote")
[[ -n $gh_sha ]] || { echo "FAIL  $tag is not on $remote"; exit 1; }
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  [[ $gh_sha == "$(git rev-parse "$tag^{commit}")" ]] || { echo "FAIL  GitHub's $tag (${gh_sha:0:8}) is not this checkout's"; exit 1; }
  echo "ok    GitHub's $tag is ${gh_sha:0:8}, the commit tagged here"
else
  echo "warn  no local $tag to compare with; GitHub's is ${gh_sha:0:8}"
fi
if git remote get-url gitea >/dev/null 2>&1; then
  g=$(peeled gitea || true)
  if [[ $g == "$gh_sha" ]]; then echo "ok    the Gitea mirror has $tag at the same commit"
  else echo "warn  the Gitea mirror has ${g:+${g:0:8}}${g:-no $tag} (scripts/mirror-gitea.sh copies it; wait or run it)"; fi
fi

d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
curl -fsSL -o "$d/SHA256SUMS" "$url/releases/download/$tag/SHA256SUMS"
for f in $(awk '{print $2}' "$d/SHA256SUMS"); do curl -fsSL -o "$d/$f" "$url/releases/download/$tag/$f"; done
(cd "$d" && shasum -a 256 -c SHA256SUMS)
sums="build/release/$tag/SHA256SUMS"
if [[ -f $sums ]]; then
  if cmp -s "$sums" "$d/SHA256SUMS"; then echo "ok    the same files as the local build"; else echo "FAIL  the published files differ from $sums"; exit 1; fi
fi
if [[ $(uname) == Darwin ]]; then
  tar -xzf "$d/sempere-$version-macos-universal.tar.gz" -C "$d"
  "$d/sempere-$version-macos-universal/sempere" --version | head -1
fi
