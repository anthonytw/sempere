#!/usr/bin/env bash
# Tests for scripts/release-prep.py. Runs on Linux and macOS; CI runs it in the `release` job.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL $1"; exit 1; }
url=https://github.com/anthonytw/sempere

# A minimal tree with the four files the script edits.
setup() {
  rm -rf "$tmp/r"; mkdir -p "$tmp/r/changelog.d" "$tmp/r/Sources/SempereCLI" "$tmp/r/Tests/CLITests" \
    "$tmp/r/Apps/Sempere/Sempere.xcodeproj"
  printf '%s\n' 'let sempereVersion = "1.0.0"' > "$tmp/r/Sources/SempereCLI/Version.swift"
  printf '%s\n' '        XCTAssertEqual(try cli(["--version"]).out.split(separator: "\n").first.map(String.init), "sempere 1.0.0")' \
    > "$tmp/r/Tests/CLITests/CLICommandTests.swift"
  printf '%s\n' '				MARKETING_VERSION = 1.0.0;' '				CURRENT_PROJECT_VERSION = 1;' '				MARKETING_VERSION = 1.0.0;' \
    > "$tmp/r/Apps/Sempere/Sempere.xcodeproj/project.pbxproj"
  printf '# readme\n' > "$tmp/r/changelog.d/README.md"
}
run() { python3 -I "$here/scripts/release-prep.py" --root "$tmp/r" "$@"; }

# 1. A new version: fragments folded, [Unreleased] becomes the version's undated section, links move on.
setup
printf '%s\n' "# Changelog" "" "## [Unreleased]" "" "### Fixed" "" "- Old F." "" "## [1.0.0] - 2026-01-01" "" "### Added" "- Keep." "" \
  "[Unreleased]: $url/compare/v1.0.0...HEAD" "[1.0.0]: $url/releases/tag/v1.0.0" > "$tmp/r/CHANGELOG.md"
printf '%s\n' "### Added" "" "- New A." > "$tmp/r/changelog.d/one.md"
run 1.1.0 >/dev/null
want="$(printf '%s\n' "# Changelog" "" "## [Unreleased]" "" "## [1.1.0] - TODO(user): release date (YYYY-MM-DD)" "" "### Fixed" "" "- Old F." "" \
  "### Added" "" "- New A." "" "## [1.0.0] - 2026-01-01" "" "### Added" "- Keep." "" \
  "[Unreleased]: $url/compare/v1.1.0...HEAD" "[1.1.0]: $url/compare/v1.0.0...v1.1.0" "[1.0.0]: $url/releases/tag/v1.0.0")"
[ "$(cat "$tmp/r/CHANGELOG.md")" = "$want" ] || { cat "$tmp/r/CHANGELOG.md"; fail "new version section"; }
[ ! -e "$tmp/r/changelog.d/one.md" ] || fail "fragment folded and deleted"
grep -q 'let sempereVersion = "1.1.0"' "$tmp/r/Sources/SempereCLI/Version.swift" || fail "Version.swift bumped"
grep -q '"sempere 1.1.0")' "$tmp/r/Tests/CLITests/CLICommandTests.swift" || fail "--version assertion bumped"
[ "$(grep -c 'MARKETING_VERSION = 1.1.0;' "$tmp/r/Apps/Sempere/Sempere.xcodeproj/project.pbxproj")" = 2 ] || fail "MARKETING_VERSION bumped"
# release.yml's guard must still refuse the section until the maintainer dates it.
if "$here/scripts/changelog-section.sh" --file "$tmp/r/CHANGELOG.md" 1.1.0 >/dev/null 2>&1; then fail "TODO(user) date accepted"; fi
# Dating it by hand makes it releasable.
sed -i.bak 's/TODO(user): release date (YYYY-MM-DD)/2026-11-01/' "$tmp/r/CHANGELOG.md"
"$here/scripts/changelog-section.sh" --file "$tmp/r/CHANGELOG.md" 1.1.0 >/dev/null || fail "dated section accepted"

# 2. An undated section that already exists (1.0.0 before the first release) takes the entries.
setup
printf '%s\n' "# Changelog" "" "## [Unreleased]" "" "### Fixed" "" "- New F." "" "## [1.0.0] - TODO(user): date" "" "Intro." "" "### Fixed" "" "- Old F." "" \
  "[Unreleased]: $url/compare/v1.0.0...HEAD" "[1.0.0]: $url/releases/tag/v1.0.0" > "$tmp/r/CHANGELOG.md"
run 1.0.0 --no-app >/dev/null 2>"$tmp/err"
grep -q '^warning: \[1.0.0\] already existed, undated' "$tmp/err" || fail "warning for an existing section"
want="$(printf '%s\n' "# Changelog" "" "## [Unreleased]" "" "## [1.0.0] - TODO(user): date" "" "Intro." "" "### Fixed" "" "- Old F." "- New F." "" \
  "[Unreleased]: $url/compare/v1.0.0...HEAD" "[1.0.0]: $url/releases/tag/v1.0.0")"
[ "$(cat "$tmp/r/CHANGELOG.md")" = "$want" ] || { cat "$tmp/r/CHANGELOG.md"; fail "merge into existing section"; }
grep -q 'MARKETING_VERSION = 1.0.0;' "$tmp/r/Apps/Sempere/Sempere.xcodeproj/project.pbxproj" || fail "--no-app"

# 3. A prerelease bumps the CLI to the full version and the app to X.Y.Z.
setup
printf '%s\n' "# Changelog" "" "## [Unreleased]" "" "### Fixed" "" "- F." "" "[Unreleased]: $url/compare/v1.0.0...HEAD" > "$tmp/r/CHANGELOG.md"
run v1.0.1-rc.1 >/dev/null
grep -q 'let sempereVersion = "1.0.1-rc.1"' "$tmp/r/Sources/SempereCLI/Version.swift" || fail "prerelease CLI version"
grep -q 'MARKETING_VERSION = 1.0.1;' "$tmp/r/Apps/Sempere/Sempere.xcodeproj/project.pbxproj" || fail "prerelease app version"
grep -q "^\[1.0.1-rc.1\]: $url/compare/v1.0.0...v1.0.1-rc.1$" "$tmp/r/CHANGELOG.md" || fail "prerelease link"

# 4. Refusals: a dated section, nothing to release, a bad version; a dry run writes nothing.
setup
printf '%s\n' "# Changelog" "" "## [Unreleased]" "" "### Fixed" "" "- F." "" "## [1.0.0] - 2026-01-01" "" "- x" > "$tmp/r/CHANGELOG.md"
if run 1.0.0 >/dev/null 2>&1; then fail "dated section accepted"; fi
printf '%s\n' "# Changelog" "" "## [Unreleased]" "" "## [1.0.0] - 2026-01-01" "" "- x" > "$tmp/r/CHANGELOG.md"
if run 1.0.1 >/dev/null 2>&1; then fail "empty [Unreleased] accepted"; fi
if run 1.0 >/dev/null 2>&1; then fail "bad version accepted"; fi
# Never lower the app's version; --no-app still allows a CLI-only release.
setup
printf '%s\n' "# Changelog" "" "## [Unreleased]" "" "### Fixed" "" "- F." > "$tmp/r/CHANGELOG.md"
printf '%s\n' "### Added" "" "- A." > "$tmp/r/changelog.d/three.md"
if run 0.9.0 >/dev/null 2>&1; then fail "lowering MARKETING_VERSION accepted"; fi
[ -e "$tmp/r/changelog.d/three.md" ] || fail "a refused run folded the fragments"
grep -q 'let sempereVersion = "1.0.0"' "$tmp/r/Sources/SempereCLI/Version.swift" || fail "a refused run wrote"
run 0.9.0 --no-app >/dev/null || fail "--no-app with a lower CLI version"
printf '%s\n' "# Changelog" "" "## [Unreleased]" "" "### Fixed" "" "- F." > "$tmp/r/CHANGELOG.md"
printf '%s\n' "### Added" "" "- A." > "$tmp/r/changelog.d/two.md"
before="$(cat "$tmp/r/CHANGELOG.md" "$tmp/r/Sources/SempereCLI/Version.swift")"
run 1.0.1 --dry-run | grep -q '^+## \[1.0.1\] - TODO(user)' || fail "dry run prints the diff"
[ "$(cat "$tmp/r/CHANGELOG.md" "$tmp/r/Sources/SempereCLI/Version.swift")" = "$before" ] || fail "dry run wrote"
[ -e "$tmp/r/changelog.d/two.md" ] || fail "dry run kept the fragment"
echo "ok   release-prep"
