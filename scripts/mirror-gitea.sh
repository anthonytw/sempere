#!/usr/bin/env bash
# Mirror GitHub (the primary, docs/design/local-first.md) to Gitea (the mirror and the fallback): main, every other branch and
# every tag, fast-forward only. GitHub cannot reach Gitea (LAN only), so a Mac on the LAN pulls from GitHub and pushes to Gitea.
#
#   scripts/mirror-gitea.sh              mirror now
#   scripts/mirror-gitea.sh --dry-run    say what would be pushed, push nothing
#
# Per ref:
#   missing on Gitea                     pushed
#   Gitea is behind GitHub               fast-forwarded
#   same commit                          nothing to do
#   Gitea is ahead of GitHub             left alone, noted (the owner has not fast-forwarded GitHub yet, or a branch was
#                                        pushed to Gitea first): not an error
#   the two have diverged                REFUSED and reported: the run exits 1 (a person decides; nothing is ever forced)
#   a tag on both with different commits REFUSED and reported, same
# Branches that exist only on Gitea are left alone (nothing is ever deleted). GitHub's refs/pull/* are not mirrored.
#
# The work happens in a bare clone of its own ($SEMPERE_MIRROR_DIR, default ~/.cache/sempere-mirror/sempere.git), never in a
# working checkout, and one run at a time (a lock folder next to it). Needs read access to GitHub and push access to Gitea:
# `git ls-remote` on both must work for the user this runs as.
# SEMPERE_MIRROR_GITHUB and SEMPERE_MIRROR_GITEA name the two remotes (scripts/test-mirror-gitea.sh points them at local repos).
# Exit status: 0 everything mirrored or nothing to do, 1 a refusal or a failed push, 2 usage or a fetch that failed.
# Run it every ten minutes by launchd: packaging/launchd/net.gulwertz.sempere-mirror.plist.
set -uo pipefail

github=${SEMPERE_MIRROR_GITHUB:-git@github.com:anthonytw/sempere.git}
gitea=${SEMPERE_MIRROR_GITEA:-git@git-ssh.lab.gulwertz.net:awertz/sempere.git}
dir=${SEMPERE_MIRROR_DIR:-$HOME/.cache/sempere-mirror/sempere.git}
dry=false
case "${1:-}" in
  "") ;;
  --dry-run) dry=true ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

mkdir -p "$(dirname "$dir")"
if ! mkdir "$dir.lock" 2>/dev/null; then
  # A lock left by a run that died is replaced after an hour; otherwise another run is working: skip.
  if [[ -n $(find "$dir.lock" -maxdepth 0 -mmin +60 2>/dev/null) ]] && rmdir "$dir.lock" 2>/dev/null && mkdir "$dir.lock" 2>/dev/null; then :
  else echo "mirror: another run holds $dir.lock; skipping"; exit 0; fi
fi
trap 'rmdir "$dir.lock" 2>/dev/null' EXIT

[[ -d $dir ]] || git init -q --bare "$dir" || exit 2
export GIT_DIR=$dir

# GitHub's branches into refs/gh/heads, its tags into refs/gh/tags; Gitea's the same under refs/gt. Nothing is forced
# here: both are only copies for the comparison below.
git fetch -q --prune --no-tags "$github" '+refs/heads/*:refs/gh/heads/*' '+refs/tags/*:refs/gh/tags/*' || { echo "mirror: cannot fetch GitHub" >&2; exit 2; }
git fetch -q --prune --no-tags "$gitea" '+refs/heads/*:refs/gt/heads/*' '+refs/tags/*:refs/gt/tags/*' || { echo "mirror: cannot fetch Gitea" >&2; exit 2; }

rc=0
pushed=0
refspecs=()
while read -r sha ref; do
  kind=${ref#refs/gh/}      # heads/NAME or tags/NAME
  full=refs/${kind}
  have=$(git rev-parse -q --verify "refs/gt/$kind" 2>/dev/null || true)
  # Compared by commit: an annotated tag on one side and a lightweight tag on the other name the same release.
  if [[ -n $have ]]; then have=$(git rev-parse -q --verify "refs/gt/$kind^{commit}"); sha=$(git rev-parse -q --verify "refs/gh/$kind^{commit}"); fi
  if [[ -z $have ]]; then
    echo "mirror: $kind: new on Gitea (${sha:0:8})"; refspecs+=("$(git rev-parse "refs/gh/$kind"):$full")
  elif [[ $have == "$sha" ]]; then
    continue
  elif [[ $kind == tags/* ]]; then
    echo "mirror: REFUSED $kind: Gitea has ${have:0:8}, GitHub has ${sha:0:8} (a tag never moves)"; rc=1
  elif git merge-base --is-ancestor "$have" "$sha" 2>/dev/null; then
    echo "mirror: $kind: fast-forward ${have:0:8}..${sha:0:8}"; refspecs+=("$sha:$full")
  elif git merge-base --is-ancestor "$sha" "$have" 2>/dev/null; then
    echo "mirror: $kind: Gitea is ahead of GitHub (${have:0:8} vs ${sha:0:8}); left alone"
  else
    echo "mirror: REFUSED $kind: diverged (Gitea ${have:0:8}, GitHub ${sha:0:8})"; rc=1
  fi
done < <(git for-each-ref --format='%(objectname) %(refname)' refs/gh/heads refs/gh/tags)

# Push one ref at a time: a refusal by Gitea (a protected branch the user may not push to) must not stop the others.
# Plain `git push`: no force, so Gitea itself refuses anything that is not a fast-forward.
for spec in ${refspecs[@]+"${refspecs[@]}"}; do
  if $dry; then echo "mirror: (dry run) would push ${spec#*:}"; continue; fi
  if git push -q "$gitea" "$spec" 2>&1 | sed 's/^/mirror:   /'; [[ ${PIPESTATUS[0]} -eq 0 ]]; then
    pushed=$((pushed + 1))
  else
    echo "mirror: FAILED to push ${spec#*:}"; rc=1
  fi
done
$dry || echo "mirror: pushed $pushed ref(s)$([[ $rc -ne 0 ]] && echo ', with refusals or failures above')"
exit $rc
