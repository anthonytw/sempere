#!/usr/bin/env bash
# Tests for scripts/changelog-collect.py. Runs on Linux and macOS; CI runs it in the `release` job.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/d"
run() { python3 -I "$here/scripts/changelog-collect.py" --dir "$tmp/d" --file "$tmp/c.md" "$@"; }
fail() { echo "FAIL $1"; exit 1; }

printf '%s\n' "# Changelog" "" "## [Unreleased]" "" "### Added" "" "- Old A." "" "### Fixed" "" "- Old F." "" "## [1.0.0] - 2026-01-01" "" "### Added" "- Keep." > "$tmp/c.md"
printf '%s\n' "### Added" "" "- New A," "  wrapped." "" "### Removed" "" "- New R." > "$tmp/d/one.md"
printf '%s\n' "### Fixed" "- New F." > "$tmp/d/two.md"
printf '# readme\n' > "$tmp/d/README.md"

run >/dev/null
want="$(printf '%s\n' "# Changelog" "" "## [Unreleased]" "" "### Added" "" "- Old A." "- New A," "  wrapped." "" "### Fixed" "" "- Old F." "- New F." "" "### Removed" "" "- New R." "" "## [1.0.0] - 2026-01-01" "" "### Added" "- Keep.")"
[ "$(cat "$tmp/c.md")" = "$want" ] || { cat "$tmp/c.md"; fail "fold result"; }
[ ! -e "$tmp/d/one.md" ] && [ ! -e "$tmp/d/two.md" ] || fail "fragments deleted"
[ -e "$tmp/d/README.md" ] || fail "README kept"

printf '### Bogus\n\n- x\n' > "$tmp/d/bad.md"
if run 2>/dev/null; then fail "bad section accepted"; fi
[ -e "$tmp/d/bad.md" ] || fail "bad fragment kept"
echo "ok   changelog-collect"
