#!/usr/bin/env bash
# Tests for `scripts/release-tag.sh --embargo` (docs/audits/README.md "Embargoed fixes"): a local tag on a commit whose
# parent is on origin/main passes and pushes nothing; a commit two away from origin/main, a dirty tree, a commit already on
# main, a merge commit, a wrong Version.swift and an existing tag are refused. Runs on Linux and macOS (bash + git).
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export SEMPERE_TAG_SIGN=false     # CI has no signing key; the script signs by default
pass=0 fail=0

# fresh: an origin with one commit on main (Version.swift 9.9.9, a dated CHANGELOG section) and a clone of it
fresh() {
  rm -rf "$tmp/origin.git" "$tmp/w"
  git init -q --bare -b main "$tmp/origin.git"
  git clone -q "$tmp/origin.git" "$tmp/w" 2>/dev/null
  cd "$tmp/w"
  git checkout -q -b main
  mkdir -p scripts Sources/SempereCLI
  cp "$here/scripts/release-tag.sh" "$here/scripts/changelog-section.sh" scripts/
  printf '%s\n' 'let sempereVersion = "9.9.9"' > Sources/SempereCLI/Version.swift
  printf '%s\n' '# Changelog' '' '## [9.9.9] - 2026-01-01' '' '- A change.' > CHANGELOG.md
  git add -A && git commit -q -m base && git push -q origin main
}
fix_commit() { printf '%s\n' "$1" > "fix-$1.txt"; git add -A; git commit -q -m "fix $1"; }

# expect NAME ok|fail PATTERN [ARGS...]: runs release-tag.sh --embargo ARGS
expect() {
  local name="$1" want="$2" pattern="$3"; shift 3
  local out code=0
  out="$(scripts/release-tag.sh --embargo "$@" 2>&1)" || code=$?
  local ok=1
  case "$want" in ok) [ "$code" -eq 0 ] || ok=0 ;; fail) [ "$code" -ne 0 ] || ok=0 ;; esac
  grep -qE -- "$pattern" <<<"$out" || ok=0
  if [ "$ok" -eq 1 ]; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name (exit $code, want $want matching /$pattern/)"; sed 's/^/     /' <<<"$out"; fi
}
# check NAME COMMAND...: passes when the command succeeds
check() { local name="$1"; shift; if "$@"; then pass=$((pass + 1)); echo "ok   $name"; else fail=$((fail + 1)); echo "FAIL $name"; fi; }
tag_here() { git rev-parse -q --verify refs/tags/v9.9.9 >/dev/null; }
tag_on_origin() { git ls-remote --exit-code --tags origin refs/tags/v9.9.9 >/dev/null 2>&1; }

fresh; fix_commit one
expect "a commit on top of origin/main is tagged (REF defaults to HEAD)" ok "created signed tag v9.9.9 .*local only" 9.9.9
check "the tag is local" tag_here
check "the tag points at the fix commit" test "$(git rev-parse 'v9.9.9^{commit}')" = "$(git rev-parse HEAD)"
check "nothing was pushed (no tag on origin)" bash -c '! git ls-remote --exit-code --tags origin refs/tags/v9.9.9 >/dev/null 2>&1'
check "nothing was pushed (origin/main unchanged)" test "$(git ls-remote origin refs/heads/main | cut -f1)" = "$(git rev-parse origin/main)"
expect "a second tag of the same version is refused" fail "tag v9.9.9 already exists here" 9.9.9

fresh; fix_commit one; sha=$(git rev-parse HEAD); fix_commit two
expect "a commit two away from origin/main is refused" fail "parent of .* is not on origin/main" 9.9.9
check "no tag was made" bash -c '! git rev-parse -q --verify refs/tags/v9.9.9 >/dev/null'
expect "REF can name the commit explicitly" ok "created signed tag" 9.9.9 "$sha"

fresh; fix_commit one; echo dirty >> CHANGELOG.md
expect "a dirty tree is refused" fail "uncommitted changes" 9.9.9
check "no tag was made on a dirty tree" bash -c '! git rev-parse -q --verify refs/tags/v9.9.9 >/dev/null'
fresh; fix_commit one; echo untracked > scratch.txt
expect "an untracked file does not count as dirty" ok "created signed tag" 9.9.9

fresh
expect "a commit already on origin/main is refused" fail "already on origin/main" 9.9.9

fresh; git checkout -q -b side; fix_commit side; git checkout -q main; fix_commit mainfix; git merge -q --no-ff -m merge side
expect "a merge commit is refused" fail "exactly one parent" 9.9.9

fresh; fix_commit one
expect "a Version.swift that differs is refused" fail "Version.swift says '9.9.9', not 9.9.8" 9.9.8

fresh; fix_commit one; sed -i.bak 's/2026-01-01/TODO(user)/' CHANGELOG.md; rm -f CHANGELOG.md.bak; git add -A; git commit -q -m todo
expect "a CHANGELOG section with TODO(user) is refused" fail "TODO\(user\)" 9.9.9

fresh; fix_commit one
expect "--embargo without a version prints usage" fail "usage:" 
fresh; fix_commit one; git tag v9.9.9 HEAD~1 && git push -q origin v9.9.9
expect "a tag already on origin is refused" fail "already exists" 9.9.9

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
