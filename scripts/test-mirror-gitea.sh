#!/usr/bin/env bash
# Test of scripts/mirror-gitea.sh against two local bare repositories (no network; no real remote is touched).
set -euo pipefail
cd "$(dirname "$0")/.."
mirror=$PWD/scripts/mirror-gitea.sh
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare "$t/github.git"; git init -q --bare "$t/gitea.git"
git init -q -b main "$t/w"; cd "$t/w"
c() { git -c commit.gpgsign=false commit -q --allow-empty -m "$1"; }
c one; c two
git remote add github "$t/github.git"; git remote add gitea "$t/gitea.git"
git push -q github main; git tag v1; git push -q github v1
export SEMPERE_MIRROR_GITHUB=$t/github.git SEMPERE_MIRROR_GITEA=$t/gitea.git SEMPERE_MIRROR_DIR=$t/m/sempere.git
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
rev() { git --git-dir="$t/$1.git" rev-parse -q --verify "$2" 2>/dev/null || echo none; }

out=$("$mirror" --dry-run); check "dry run pushes nothing" '[[ $(rev gitea main) == none ]]'
out=$("$mirror"); check "first run pushes main and the tag" '[[ $(rev gitea main) == $(rev github main) && $(rev gitea v1) == $(rev github v1) ]]'
out=$("$mirror"); check "second run has nothing to do" '[[ $out == *"pushed 0"* ]]'
c three; git push -q github main
git checkout -q -b feat; c feat; git push -q github feat; git checkout -q main
"$mirror" >/dev/null; check "fast-forward and a new branch" '[[ $(rev gitea main) == $(rev github main) && $(rev gitea feat) == $(rev github feat) ]]'
# Gitea ahead: left alone, exit 0
git checkout -q -b ahead; c extra; git push -q gitea ahead:main; git checkout -q main
out=$("$mirror"); check "Gitea ahead is left alone, not an error" '[[ $out == *"Gitea is ahead"* && $(rev gitea main) != $(rev github main) ]]'
# Diverged: refused, exit 1 (GitHub's main is moved sideways with update-ref: nothing here pushes with force)
git checkout -q -b side main; c gh-only; git push -q github side; git checkout -q main
git --git-dir="$t/github.git" update-ref refs/heads/main "$(git rev-parse side)"
set +e; out=$("$mirror"); status=$?; set -e
check "a diverged branch is refused and fails the run" '[[ $status -eq 1 && $out == *"REFUSED heads/main: diverged"* ]]'
# A moved tag is refused
git --git-dir="$t/github.git" update-ref -d refs/tags/v1; git --git-dir="$t/github.git" update-ref refs/tags/v1 "$(git rev-parse side)"
set +e; out=$("$mirror"); status=$?; set -e
check "a moved tag is refused" '[[ $status -eq 1 && $out == *"REFUSED tags/v1"* ]]'
# A stale lock (a run that died an hour ago) is replaced; a fresh one makes the run skip
git checkout -q -b more main; c more; git push -q github more
mkdir "$t/m/sempere.git.lock"
out=$("$mirror"); check "a fresh lock makes the run skip" '[[ $out == *"holds"* && $(rev gitea more) == none ]]'
touch -t 202001010000 "$t/m/sempere.git.lock"
out=$("$mirror" || true); check "a stale lock is replaced and the run pushes" '[[ $(rev gitea more) == $(rev github more) && ! -d $t/m/sempere.git.lock ]]'
exit $fail
