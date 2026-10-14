#!/usr/bin/env bash
# Print the body of one CHANGELOG.md section, e.g. `scripts/changelog-section.sh 0.6.0`.
# Exits 1 if the section is missing or empty, if its heading is not
# `## [X.Y.Z] - YYYY-MM-DD`, or if the heading or body still holds a `TODO(user)`
# (a decision left for the maintainer, such as the release date): the release
# workflow relies on that, so such a section is never published or packaged.
#
# Usage: scripts/changelog-section.sh [--file CHANGELOG] VERSION
#   --file  read another file (scripts/test-changelog-section.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
file=CHANGELOG.md
if [ "${1:-}" = "--file" ]; then
  file="${2:?usage: changelog-section.sh [--file CHANGELOG] VERSION}"
  shift 2
fi
version="${1:?usage: changelog-section.sh [--file CHANGELOG] VERSION}"
version="${version#v}"
heading="$(awk -v v="$version" 'index($0, "## [" v "]") == 1 { print; exit }' "$file")"
body="$(awk -v v="$version" '
  /^## \[/ { if (on) exit; if (index($0, "## [" v "]") == 1) { on = 1; next } }
  on { print }
' "$file" | sed -e '/./,$!d')"
if [ -z "$body" ]; then
  echo "error: no non-empty $file section for $version" >&2
  exit 1
fi
if ! [[ "$heading" =~ ^"## ["[^]]+"] - "[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "error: the $file heading for $version is not \`## [$version] - YYYY-MM-DD\`: $heading" >&2
  exit 1
fi
todo="$(printf '%s\n%s\n' "$heading" "$body" | grep -n 'TODO(user)' || true)"
if [ -n "$todo" ]; then
  echo "error: the $file section for $version still has TODO(user) (resolve it before tagging):" >&2
  printf '%s\n' "$todo" >&2
  exit 1
fi
printf '%s\n' "$body"
