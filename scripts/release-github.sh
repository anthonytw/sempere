#!/usr/bin/env bash
# Prepare the GitHub side of a release (docs/design/local-first.md): ONE commit whose tree is the Gitea tag's
# tree and whose parent is GitHub's current main, so GitHub's history is one squashed commit per release.
# It pushes nothing: it prints the owner's commands (push, GitHub Release, Homebrew formula).
#
#   scripts/release-github.sh VERSION
#
# Run it as the owner: the commit is authored (and signed, with commit.gpgsign) by whoever runs it.
# GitHub is read anonymously over HTTPS, so no GitHub login is needed here. Needs build/release/vVERSION
# from scripts/release-build.sh. The commit is kept as refs/github-release/vVERSION.
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:?usage: $0 VERSION}; version=${version#v}
tag=v$version
public=https://github.com/anthonytw/sempere.git
die() { echo "error: $*" >&2; exit 1; }

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "no tag $tag here"
dist=build/release/$tag
[[ -f $dist/SHA256SUMS && -f $dist/notes.md ]] || die "no build in $dist (just release-build $version)"
tree=$(git rev-parse "$tag^{tree}")

git fetch -q --no-tags "$public" main
parent=$(git rev-parse FETCH_HEAD)
git update-ref refs/github/main "$parent"
echo "GitHub main: $(git log --oneline -1 "$parent")"

# GitHub's main should be the previous release: its tree is one of our release tags' trees.
prev=""
for t in $(git tag -l 'v*' --sort=-v:refname); do
  [[ $t == "$tag" ]] && continue
  [[ $(git rev-parse "$t^{tree}") == "$(git rev-parse "$parent^{tree}")" ]] && { prev=$t; break; }
done
if [[ -n $prev ]]; then echo "GitHub main is release $prev"
else echo "warning: GitHub main's tree matches no release tag here: it has changes that are not a release of ours"; fi

if [[ $(git rev-parse "$parent^{tree}") == "$tree" ]]; then
  commit=$parent
  echo "GitHub main already has $tag's tree: no new commit, only the tag"
else
  sign=(); [[ $(git config --bool commit.gpgsign || true) == true ]] && sign=(-S)
  msg=$(printf 'Sempere %s\n\nSquashed from the development repository%s.\n\n%s\n' \
    "$version" "${prev:+ since $prev}" "$(cat "$dist/notes.md")")
  commit=$(git commit-tree ${sign[@]+"${sign[@]}"} "$tree" -p "$parent" -m "$msg")
fi
git update-ref "refs/github-release/$tag" "$commit"
echo "commit for GitHub: $(git log --oneline -1 "$commit") (refs/github-release/$tag)"
echo "  $(git diff --shortstat "$parent" "$commit")"

pre=""; [[ $version == *-* ]] && pre=" --prerelease"
cat <<EOF

Owner, to publish (nothing has been pushed):
  git push git@github.com:anthonytw/sempere.git $commit:refs/heads/main $commit:refs/tags/$tag
  gh release create $tag --repo anthonytw/sempere --verify-tag --title "Sempere CLI $tag" \\
     --notes-file $dist/notes.md$pre $dist/*.tar.gz $dist/SHA256SUMS
  just formula $version ~/dev/homebrew-tap      # then test, commit and push the tap
  just release-verify $version
EOF
