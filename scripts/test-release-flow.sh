#!/usr/bin/env bash
# Test of the release scripts' GitHub flow (release-tag.sh, release-publish.sh, release-verify.sh) against local bare
# repositories and a stub `gh`: no network, no tag or push outside the temp folder. The sweep check is stubbed (it reads
# Gitea's commit statuses); the typed push approval needs a terminal, so a push is covered only as "not pushed".
set -euo pipefail
cd "$(dirname "$0")/.."
src=$PWD
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export SEMPERE_TAG_SIGN=false
# The release scripts run on a Mac, where `shasum` and `curl` exist; the Linux CI image has neither (shims for file:// only).
mkdir -p "$t/bin"; export PATH="$t/bin:$PATH"
# A stub gh, so no test reaches the network or a real login: `release view` fails (no such release) unless GH_EXISTS=1.
printf '#!/bin/sh\n[ "$1 $2" = "release view" ] && [ -n "$GH_EXISTS" ] && exit 0\n[ "$1 $2" = "release view" ] && exit 1\necho "stub gh: $*" >> "$STUB_GH_LOG"\n' > "$t/bin/gh"; chmod +x "$t/bin/gh"
export SEMPERE_RELEASE_REPO=example/none STUB_GH_LOG="$t/gh.log"
command -v shasum >/dev/null || { printf '#!/bin/sh\nshift 2\nexec sha256sum "$@"\n' > "$t/bin/shasum"; chmod +x "$t/bin/shasum"; }
command -v curl >/dev/null || { printf '#!/bin/sh\nwhile [ "$1" != -o ]; do shift; done; out=$2; url=$3; exec cp "${url#file://}" "$out"\n' > "$t/bin/curl"; chmod +x "$t/bin/curl"; }
git init -q --bare "$t/github.git"
git init -q -b main "$t/w"; cd "$t/w"
git config commit.gpgsign false
mkdir -p scripts Sources/SempereCLI
cp "$src"/scripts/{release-tag.sh,release-publish.sh,release-verify.sh,changelog-section.sh} scripts/
printf '#!/usr/bin/env bash\necho "ok    local/release-sweep: stub on ${1:0:8}"\n' > scripts/release-sweep-check.sh; chmod +x scripts/release-sweep-check.sh
printf 'let sempereVersion = "1.2.3"\n' > Sources/SempereCLI/Version.swift
printf '# Changelog\n\n## [1.2.3] - 2026-11-09\n\n### Fixed\n\n- A thing.\n\n## [1.2.2] - 2026-10-01\n\n- Older.\n' > CHANGELOG.md
git add -A; git commit -q -m "release: 1.2.3"
git remote add origin "$t/github.git"; git push -q origin main; git fetch -q origin
git checkout -q -b side; git commit -q --allow-empty -m "off main"; git checkout -q main
export SEMPERE_RELEASE_REMOTE=origin
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
run() { out=$("$@" 2>&1) && rc=0 || rc=$?; }

run scripts/release-tag.sh --check 1.2.3; check "--check passes and tags nothing" '[[ $rc == 0 && $out == *"ready: just release-tag"* ]] && ! git rev-parse -q --verify refs/tags/v1.2.3 >/dev/null'
run scripts/release-tag.sh --check 1.2.4; check "--check refuses a version Version.swift does not say" '[[ $rc != 0 && $out == *"Version.swift says"* ]]'
run scripts/release-tag.sh --check 1.2.3 side; check "--check refuses a commit that is not on origin/main" '[[ $rc != 0 && $out == *"is not on origin/main"* ]]'
run scripts/release-tag.sh 1.2.3; check "tagging makes a local tag and, without a terminal, pushes nothing" '[[ $rc == 0 && $out == *"Not pushed"* ]] && git rev-parse -q --verify refs/tags/v1.2.3 >/dev/null && ! git ls-remote --exit-code --tags origin v1.2.3 >/dev/null 2>&1'
check "the tag is on main's commit" '[[ $(git rev-parse v1.2.3^{commit}) == $(git rev-parse origin/main) ]]'
run scripts/release-tag.sh --check 1.2.3; check "an existing local tag is refused" '[[ $rc != 0 && $out == *"already exists here"* ]]'
run scripts/release-publish.sh 1.2.3; check "publish refuses a tag that is not on GitHub yet" '[[ $rc != 0 && $out == *"not on origin yet"* ]]'
git push -q origin refs/tags/v1.2.3
run scripts/release-publish.sh 1.2.3; check "publish refuses without a local build" '[[ $rc != 0 && $out == *"no build in"* ]]'

d=build/release/v1.2.3; mkdir -p $d
tarballs() {
  for p in macos-universal linux-x86_64 linux-aarch64; do echo "bin $p" > $d/sempere-1.2.3-$p.tar.gz; done
  mkdir -p "$t/pkg/sempere-1.2.3-macos-universal"; printf '#!/bin/sh\necho sempere 1.2.3\n' > "$t/pkg/sempere-1.2.3-macos-universal/sempere"
  chmod +x "$t/pkg/sempere-1.2.3-macos-universal/sempere"; tar -czf $d/sempere-1.2.3-macos-universal.tar.gz -C "$t/pkg" sempere-1.2.3-macos-universal
}
tarballs
scripts/changelog-section.sh 1.2.3 > $d/notes.md
git rev-parse v1.2.3^{commit} > $d/COMMIT
(cd $d && shasum -a 256 sempere-1.2.3-*.tar.gz > SHA256SUMS)
run scripts/release-publish.sh 1.2.3
check "publish prints the gh command and publishes nothing" '[[ $rc == 0 && $out == *"gh release create v1.2.3 --repo example/none --verify-tag"* && $out == *"just formula 1.2.3"* ]]'
check "no squash machinery is left" '[[ ! -e $src/scripts/release-github.sh && $out != *squash* ]]'
run env GH_EXISTS=1 scripts/release-publish.sh 1.2.3; check "print mode refuses a Release that exists" '[[ $rc != 0 && $out == *"already exists"* ]]'
run scripts/release-publish.sh 1.2.3-rc.1; check "an unknown tag is refused" '[[ $rc != 0 && $out == *"no tag v1.2.3-rc.1"* ]]'
echo tampered >> $d/sempere-1.2.3-linux-x86_64.tar.gz
run scripts/release-publish.sh 1.2.3; check "publish refuses files that do not match SHA256SUMS" '[[ $rc != 0 && $out == *"does not match"* ]]'
tarballs   # restore the files the sums were made from
git checkout -q side; git tag -a v9.9.9 -m x; git push -q origin refs/tags/v9.9.9 2>/dev/null; git tag -d v9.9.9 >/dev/null; git tag -a v9.9.9 -m y main
run scripts/release-publish.sh 9.9.9; check "publish refuses a tag that differs from GitHub's" '[[ $rc != 0 && $out == *"binaries must come from the pushed tag"* ]]'
git checkout -q main
run scripts/release-publish.sh --publish 1.2.3; check "--publish needs a terminal" '[[ $rc != 0 && $out == *"on a terminal"* ]]'
run scripts/release-publish.sh 1.2.3 --publish; check "--publish works after the version too" '[[ $rc != 0 && $out == *"on a terminal"* ]]'
check "no gh release create was run" '[[ ! -f $STUB_GH_LOG ]] || ! grep -q create "$STUB_GH_LOG"'

# Tagged again after the build: the pushed tag is no longer what was built, and publish and verify refuse.
git checkout -q -b retag main; git commit -q --allow-empty -m "after the build"; git push -q origin retag
git tag -d v1.2.3 >/dev/null; git tag -a v1.2.3 -m again retag; git push -q -f origin refs/tags/v1.2.3
run scripts/release-publish.sh 1.2.3; check "publish refuses a build from another commit than the tag" '[[ $rc != 0 && $out == *"was built from"* ]]'
git tag -d v1.2.3 >/dev/null; git tag -a v1.2.3 -m orig "$(cat $d/COMMIT)"; git push -q -f origin refs/tags/v1.2.3; git checkout -q main
echo extra > $d/sempere-1.2.3-extra.tar.gz
run scripts/release-publish.sh 1.2.3; check "publish refuses a tarball missing from SHA256SUMS" '[[ $rc != 0 && $out == *"not in SHA256SUMS"* ]]'
rm $d/sempere-1.2.3-extra.tar.gz

# release-verify: GitHub's tag against this checkout, and the Gitea mirror when a `gitea` remote exists.
git init -q --bare "$t/gitea.git"; git remote add gitea "$t/gitea.git"
tarballs; (cd $d && shasum -a 256 sempere-1.2.3-*.tar.gz > SHA256SUMS)
mkdir -p "$t/dl/releases/download/v1.2.3"; cp $d/* "$t/dl/releases/download/v1.2.3/"
export SEMPERE_RELEASE_URL="file://$t/dl"
cp $d/COMMIT $t/COMMIT.bak; git rev-parse retag > $d/COMMIT
run scripts/release-verify.sh 1.2.3; check "verify refuses a local build of another commit" '[[ $rc != 0 && $out == *"local build is of"* ]]'
cp $t/COMMIT.bak $d/COMMIT
run scripts/release-verify.sh 1.2.3; check "verify warns while the mirror lacks the tag" '[[ $rc == 0 && $out == *"ok    GitHub'"'"'s v1.2.3"* && $out == *"warn  the Gitea mirror has"* ]]'
git push -q gitea refs/tags/v1.2.3 refs/heads/main
run scripts/release-verify.sh 1.2.3; check "verify sees the mirror's tag" '[[ $rc == 0 && $out == *"the Gitea mirror has v1.2.3 at the same commit"* ]]'
exit $fail
