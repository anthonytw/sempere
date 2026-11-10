#!/usr/bin/env bash
# Test of scripts/release-sweep-tree.sh against a local repository and a stub forge: no network, nothing posted.
set -euo pipefail
cd "$(dirname "$0")/.."
src=$PWD
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q -b main "$t/w"; cd "$t/w"; git config commit.gpgsign false
mkdir scripts; cp "$src/scripts/release-sweep-tree.sh" scripts/
# The stub forge: every commit is there unless NO_COMMIT is set; a posted status is appended to the log.
cat > scripts/forge.sh <<'EOF'
forge_has_commit() { [[ -z ${NO_COMMIT:-} ]]; }
forge_post_status() { echo "$1 $2 $3 $4" >> "$STUB_FORGE_LOG"; }
EOF
export STUB_FORGE_LOG="$t/forge.log" SEMPERE_SWEEP_TREES="$t/trees"
echo one > f; git add -A; git commit -q -m "release commit (local)"; local_sha=$(git rev-parse HEAD)
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi }
run() { out=$("$@" 2>&1) && rc=0 || rc=$?; }

run scripts/release-sweep-tree.sh post "$local_sha"; check "nothing is posted before a sweep was recorded" '[[ $rc != 0 && $out == *"no record of a sweep"* && ! -f $STUB_FORGE_LOG ]]'
echo dirty >> f
run scripts/release-sweep-tree.sh record; check "a dirty checkout is not recorded" '[[ $rc != 0 && $out == *"uncommitted"* && ! -f $SEMPERE_SWEEP_TREES ]]'
git checkout -q f
git commit -q --allow-empty -m "later"; run scripts/release-sweep-tree.sh record "$local_sha"
check "an explicit commit that is not HEAD is refused" '[[ $rc != 0 && $out == *"not HEAD"* && ! -f $SEMPERE_SWEEP_TREES ]]'
git reset -q --hard "$local_sha"
run scripts/release-sweep-tree.sh record; check "a clean checkout is recorded" '[[ $rc == 0 && -f $SEMPERE_SWEEP_TREES ]]'

# The squash merge on main: another commit id, the same tree (here: a root commit with the same files).
git checkout -q --orphan merged; git commit -q -m "squash merge (PR)"; merge_sha=$(git rev-parse HEAD)
check "the merge commit is another commit with the same tree" '[[ $merge_sha != $local_sha && $(git rev-parse "$merge_sha^{tree}") == $(git rev-parse "$local_sha^{tree}") ]]'
run scripts/release-sweep-tree.sh post "$merge_sha"
check "a commit with a swept tree gets local/release-sweep" '[[ $rc == 0 && $(cat "$STUB_FORGE_LOG") == "$merge_sha local/release-sweep success "* ]]'
rm -f "$STUB_FORGE_LOG"
run env NO_COMMIT=1 scripts/release-sweep-tree.sh post "$merge_sha"; check "a commit the forge lacks is refused" '[[ $rc != 0 && $out == *"does not have"* && ! -f $STUB_FORGE_LOG ]]'

# One byte of difference: another tree, refused.
echo two > f; git add -A; git commit -q -m "one more change"; other=$(git rev-parse HEAD)
run scripts/release-sweep-tree.sh post "$other"; check "a commit with another tree is refused" '[[ $rc != 0 && $out == *"not one a release sweep passed"* && ! -f $STUB_FORGE_LOG ]]'
run scripts/release-sweep-tree.sh post nonsense; check "an unknown commit is refused" '[[ $rc != 0 ]]'
exit $fail
