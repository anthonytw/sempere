#!/usr/bin/env bash
# Tests for scripts/changelog-section.sh, which the release workflow uses for the
# release notes and to refuse a tag whose CHANGELOG section is not ready.
# Runs on Linux and macOS (bash); CI runs it in the `release` job.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
section="$here/scripts/changelog-section.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

# expect NAME ok|fail VERSION PATTERN: runs on $tmp/CHANGELOG.md; PATTERN must match the output.
expect() {
  local name="$1" want="$2" version="$3" pattern="$4" out code=0
  out="$("$section" --file "$tmp/CHANGELOG.md" "$version" 2>&1)" || code=$?
  local ok=1
  case "$want" in
    ok) [ "$code" -eq 0 ] || ok=0 ;;
    fail) [ "$code" -ne 0 ] || ok=0 ;;
  esac
  if [ "$ok" -eq 1 ] && ! grep -qE -- "$pattern" <<<"$out"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name (exit $code, want $want matching /$pattern/)"; sed 's/^/     /' <<<"$out"; fi
}

changelog() { printf '%s\n' "$@" > "$tmp/CHANGELOG.md"; }

changelog "# Changelog" "" "## [Unreleased]" "" "- TODO(user): later" "" "## [1.2.0] - 2026-11-02" "" "### Added" "- A thing." "" "## [1.1.0] - 2026-10-01" "" "- Old."
expect "a dated section prints its body only" ok 1.2.0 '^### Added$'
out="$("$section" --file "$tmp/CHANGELOG.md" v1.2.0)"
if [ "$out" = $'### Added\n- A thing.' ]; then pass=$((pass + 1)); echo "ok   body is exact, v prefix accepted"
else fail=$((fail + 1)); echo "FAIL body is exact: $out"; fi
expect "another section's TODO(user) does not matter" ok 1.1.0 '^- Old\.$'

changelog "## [0.5.0] - TODO(user): date of the first release" "" "- First."
expect "TODO(user) in the heading" fail 0.5.0 'not `## \[0.5.0\] - YYYY-MM-DD`'

changelog "## [0.5.0] - 2026-10-20 TODO(user)" "" "- First."
expect "TODO(user) after the date" fail 0.5.0 'not `## \[0.5.0\] - YYYY-MM-DD`'

changelog "## [0.5.0] - 2026-10-20" "" "- First." "- TODO(user): say what changed" "" "## [0.4.0] - 2026-01-01"
expect "TODO(user) in the body" fail 0.5.0 'still has TODO\(user\)'

changelog "## [0.5.0]" "" "- First."
expect "no date" fail 0.5.0 'YYYY-MM-DD'

changelog "## [0.5.0] - 2026-10-20" "" "## [0.4.0] - 2026-01-01" "" "- x"
expect "empty section" fail 0.5.0 'no non-empty'

changelog "## [0.4.0] - 2026-01-01" "" "- x"
expect "missing section" fail 0.5.0 'no non-empty'

changelog "## [0.5.0-rc.1] - 2026-10-20" "" "- Candidate."
expect "a prerelease section" ok v0.5.0-rc.1 'Candidate'

echo "changelog-section tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
