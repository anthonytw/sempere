#!/usr/bin/env bash
# The release sweep for a commit whose tree is one that already passed it (docs/audits/README.md "Embargoed fixes",
# docs/releasing.md). A commit's tree id names its content exactly, whatever its parents or message: the release commit
# built and swept locally (`scripts/local-ci.sh --release --no-status`) and the squash merge of the same changes on main
# have different commit ids and the same tree. Nothing is run here and nothing is trusted but the record.
#
#   scripts/release-sweep-tree.sh record [SHA]   remember the tree of SHA (default HEAD) as one a full sweep passed:
#                                                local-ci.sh calls it after a passing `--release` run on a clean checkout
#   scripts/release-sweep-tree.sh post SHA       post `local/release-sweep` (success) on SHA, only if its tree was recorded
#   scripts/release-sweep-tree.sh --list         the recorded trees
#
# The record is data/local-ci/release-sweep-trees (git-ignored; SEMPERE_SWEEP_TREES names another file): one line per
# sweep, "tree commit unix-time host". `post` needs the forge to have the commit (scripts/forge.sh: the mirror has
# copied it). A sweep of another tree, an edited commit, a tree that differs by one byte: refused.
set -euo pipefail
cd "$(dirname "$0")/.."
records=${SEMPERE_SWEEP_TREES:-data/local-ci/release-sweep-trees}
die() { echo "release-sweep-tree: $*" >&2; exit 1; }

case ${1:-} in
  record)
    sha=$(git rev-parse "${2:-HEAD}^{commit}")
    # A tree is only the sweep's if the checkout was the commit exactly.
    if [[ ${2:-HEAD} == HEAD && -n $(git status --porcelain) ]]; then die "the checkout has uncommitted changes; not recorded"; fi
    tree=$(git rev-parse "$sha^{tree}")
    mkdir -p "$(dirname "$records")"
    printf '%s %s %s %s\n' "$tree" "$sha" "$(date +%s)" "$(scutil --get ComputerName 2>/dev/null || hostname -s | tr ' ' '_')" >> "$records"
    echo "release-sweep-tree: tree ${tree:0:12} of ${sha:0:8} recorded as swept; a commit with this tree can be posted: scripts/local-ci.sh --post-sweep SHA"
    ;;
  post)
    sha=$(git rev-parse "${2:?usage: $0 post SHA}^{commit}")
    tree=$(git rev-parse "$sha^{tree}")
    [[ -f $records ]] || die "no record of a sweep ($records)"
    line=$(awk -v t="$tree" '$1 == t { l = $0 } END { print l }' "$records")
    [[ -n $line ]] || die "the tree of ${sha:0:8} (${tree:0:12}) is not one a release sweep passed here: run scripts/local-ci.sh --release on it"
    read -r _ swept at host <<<"$line"
    source scripts/forge.sh
    forge_has_commit "$sha" || die "the forge does not have ${sha:0:8} yet (the mirror copies main every ten minutes)"
    when=$(date -r "$at" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date -d "@$at" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "$at")
    forge_post_status "$sha" local/release-sweep success "release sweep: same tree as ${swept:0:8}, swept $when on $host"
    echo "release-sweep-tree: local/release-sweep posted for ${sha:0:8} (tree ${tree:0:12}, swept as ${swept:0:8})"
    ;;
  --list)
    [[ -f $records ]] && cat "$records" || echo "(no sweeps recorded)" ;;
  *) sed -n '2,15p' "$0" >&2; exit 2 ;;
esac
