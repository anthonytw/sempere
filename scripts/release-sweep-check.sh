#!/usr/bin/env bash
# Has SHA passed the release sweep (`just ci-release`, commit status `local/release-sweep`)?
#
#   scripts/release-sweep-check.sh SHA [REPO]
#
# Yes if SHA itself has a successful `local/release-sweep`, or if the nearest first-parent ancestor
# that has one differs from SHA only in release-neutral files: the changelog, docs, CI config,
# release tooling, root Markdown. Those cannot change what the release builds, so a changelog date
# fix or a release-script fix after the sweep does not need a second ~2 h sweep. Any other file
# (Sources/, the app, Package.swift, fonts/, …) needs a new sweep.
#
# Prints one "ok"/"FAIL" line; exit 0 = swept, 1 = not, 2 = usage. Used by scripts/release-tag.sh
# and .github/workflows/release.yml (prepare). Needs `gh` (GH_TOKEN in CI) and the git history.
set -euo pipefail

sha=${1:?usage: $0 SHA [REPO]}
repo=${2:-${SEMPERE_GH_REPO:-anthonytw/sempere}}
max_back=${SEMPERE_SWEEP_LOOKBACK:-50}

# Paths that do not reach the built app or CLI. Keep this list small and boring.
neutral='^(CHANGELOG\.md|changelog\.d/.*|docs/.*|\.github/.*|[^/]+\.md|justfile|packaging/homebrew/.*|scripts/(release-[^/]*|changelog-[^/]*|update-formula)\.(sh|py))$'

swept() {
  local state
  state=$(gh api "repos/$repo/commits/$1/status" \
    --jq '[.statuses[] | select(.context == "local/release-sweep")][0].state // "missing"' 2>/dev/null) || state="unknown"
  [[ $state == success ]]
}

sha=$(git rev-parse "$sha^{commit}")
if swept "$sha"; then echo "ok    local/release-sweep: success on ${sha:0:8}"; exit 0; fi

base=""
for c in $(git rev-list --first-parent --max-count="$max_back" "$sha^" 2>/dev/null); do
  if swept "$c"; then base=$c; break; fi
done
if [[ -z $base ]]; then
  echo "FAIL  no local/release-sweep on ${sha:0:8} or its last $max_back first-parent ancestors: run 'just ci-release'"
  exit 1
fi

changed=$(git diff --name-only "$base" "$sha")
other=$(grep -Ev "$neutral" <<<"$changed" || true)
if [[ -n $other ]]; then
  echo "FAIL  swept at ${base:0:8}, but ${sha:0:8} changes built files since: $(tr '\n' ' ' <<<"$other")— run 'just ci-release' on ${sha:0:8}"
  exit 1
fi
echo "ok    local/release-sweep: success on ${base:0:8}; since then only release-neutral files: $(tr '\n' ' ' <<<"$changed")"
