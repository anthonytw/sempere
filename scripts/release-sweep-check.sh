#!/usr/bin/env bash
# Has SHA passed the release sweep (`just ci-release`, commit status `local/release-sweep`)?
#
#   scripts/release-sweep-check.sh SHA
#
# Yes if SHA itself has a successful `local/release-sweep`, or if the nearest first-parent ancestor
# that has one differs from SHA only in release-neutral files: the changelog, docs, CI config,
# release tooling, root Markdown. Those cannot change what the release builds, so a changelog date
# fix or a release-script fix after the sweep does not need a second ~2 h sweep. Any other file
# (Sources/, the app, Package.swift, fonts/, scripts/ci-linux.sh, which builds the Linux binaries, …) needs a new sweep.
#
# A CLI-only release (`just release-prep X.Y.Z --no-app`: Version.swift differs from the app's
# MARKETING_VERSION, so no App Store build goes with it) needs no sweep: the sweep gates App Store
# submissions. Instead SHA itself must have passed the CLI's checks: `local/cli-suite`
# (`just ci-cli`: the package tests on a Mac, then the Linux, WebDAV and static-build jobs in Docker).
#
# The statuses are read from Gitea (scripts/forge.sh); the mirror gives the same commit the same SHA there. Prints one "ok"/"FAIL" line; exit 0 = swept,
# 1 = not, 2 = usage. Used by scripts/release-tag.sh and scripts/release-build.sh.
set -euo pipefail

sha=${1:?usage: $0 SHA}
cd "$(dirname "$0")/.."
source scripts/forge.sh
max_back=${SEMPERE_SWEEP_LOOKBACK:-50}

# Paths that do not reach the built app or CLI: one line in scripts/release-neutral.regex, which the PR gate's skip
# decision (scripts/ci-gate-decision.py) reads too. Keep that list small and boring.
neutral=$(<scripts/release-neutral.regex)
# ... except what the app bundles from docs/ (scripts/release-bundled.regex; ci-gate-decision.py --self-test checks it against the
# Xcode project's references).
bundled=$(<scripts/release-bundled.regex)

status_of() {   # sha context -> state, "missing", or "unknown" when Gitea cannot be asked
  local out
  out=$(forge_statuses "$1" 2>/dev/null) || { echo unknown; return; }
  awk -F'\t' -v c="$2" '$1 == c { print $2; found = 1; exit } END { if (!found) print "missing" }' <<<"$out"
}
swept() { [[ $(status_of "$1" local/release-sweep) == success ]]; }

sha=$(git rev-parse "$sha^{commit}")

# CLI-only release: the CLI's checks instead of the sweep.
cli=$(git show "$sha:Sources/SempereCLI/Version.swift" | sed -n 's/^let sempereVersion = "\(.*\)"$/\1/p')
app=$(git show "$sha:Apps/Sempere/Sempere.xcodeproj/project.pbxproj" | sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' | sort -u | tr '\n' ' ')
app=${app% }
if [[ -n $cli && -n $app && $app != "${cli%%-*}" ]]; then
  state=$(status_of "$sha" local/cli-suite)
  if [[ $state != success ]]; then
    echo "FAIL  CLI-only release (CLI $cli, app $app): local/cli-suite is $state on ${sha:0:8} (run 'just ci-cli' on it)"
    exit 1
  fi
  echo "ok    CLI-only release (CLI $cli, app $app): no sweep needed; local/cli-suite passed on ${sha:0:8}"
  exit 0
fi

if swept "$sha"; then echo "ok    local/release-sweep: success on ${sha:0:8}"; exit 0; fi

base=""
for c in $(git rev-list --first-parent --max-count="$max_back" "$sha^" 2>/dev/null); do
  if swept "$c"; then base=$c; break; fi
done
if [[ -z $base ]]; then
  echo "FAIL  no local/release-sweep on ${sha:0:8} or its last $max_back first-parent ancestors: run 'just ci-release'"
  exit 1
fi

# --no-renames: a file moved out of Sources/ into docs/ must list its old path too (git would show only the new one).
changed=$(git diff --no-renames --name-only "$base" "$sha")
other=$({ grep -Ev "$neutral" <<<"$changed" || true; grep -E "$bundled" <<<"$changed" || true; })
if [[ -n $other ]]; then
  echo "FAIL  swept at ${base:0:8}, but ${sha:0:8} changes built files since: $(tr '\n' ' ' <<<"$other")— run 'just ci-release' on ${sha:0:8}"
  exit 1
fi
echo "ok    local/release-sweep: success on ${base:0:8}; since then only release-neutral files: $(tr '\n' ' ' <<<"$changed")"
