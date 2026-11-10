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
cp "$src"/scripts/{release-tag.sh,release-publish.sh,release-verify.sh,release-signature.sh,release-sign.sh,release-build.sh,changelog-section.sh} scripts/
printf '#!/usr/bin/env bash\necho "ok    local/release-sweep: stub on ${1:0:8}"\n' > scripts/release-sweep-check.sh; chmod +x scripts/release-sweep-check.sh
printf 'let sempereVersion = "1.2.3"\n' > Sources/SempereCLI/Version.swift
printf '# Changelog\n\n## [1.2.3] - 2026-11-09\n\n### Fixed\n\n- A thing.\n\n## [1.2.2] - 2026-10-01\n\n- Older.\n' > CHANGELOG.md
# The maintainer's signing key (a throwaway one) and its line in the signers file.
mkdir -p packaging; ssh-keygen -q -t ed25519 -N "" -C test -f "$t/key"; ssh-keygen -q -t ed25519 -N "" -C other -f "$t/other"
echo "maintainer $(cut -d' ' -f1,2 "$t/key.pub")" > packaging/allowed_signers
export SEMPERE_SIGN_DROP="$t/drop" SEMPERE_SIGN_OUT="$t/sign-out" SEMPERE_BUILD_USER=$(id -un) SEMPERE_MAINTAINER_USER=$(id -un)   # the seat's folder, the maintainer's folder; here both are this user
# The maintainer signs with release-sign.sh from their own account; stag makes a tag signed with a given key (default: theirs).
stag() { local k=$t/key; [[ ${1:-} == -k ]] && { k=$2; shift 2; }; git -c gpg.format=ssh -c user.signingkey="$k" tag -s "$@"; }
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
run scripts/release-publish.sh 1.2.3; check "publish refuses an unsigned tag (1.1.0 and later)" '[[ $rc != 0 && $out == *"not signed by a key in"* ]]'
run scripts/release-build.sh 1.2.3; check "build refuses an unsigned tag, before anything else" '[[ $rc != 0 && $out == *"must be signed by the maintainer"* ]]'
git tag -d v1.2.3 >/dev/null; stag -k "$t/other" v1.2.3 -m "other key" "$(git rev-parse origin/main)"; git push -q -f origin refs/tags/v1.2.3
run scripts/release-publish.sh 1.2.3; check "publish refuses a tag signed by another key" '[[ $rc != 0 && $out == *"not signed by a key in"* ]]'
run scripts/release-build.sh 1.2.3; check "build refuses a tag signed by another key" '[[ $rc != 0 && $out == *"must be signed by the maintainer"* ]]'
run scripts/release-signature.sh verify-tag 1.2.3-rc.1; check "a prerelease's tag signature is not required" '[[ $rc == 0 && $out == *"not checked"* ]]'
run scripts/release-signature.sh verify-tag 1.0.1; check "a pre-1.1.0 tag signature is not required" '[[ $rc == 0 && $out == *"not checked"* ]]'
git tag -d v1.2.3 >/dev/null; stag v1.2.3 -m "maintainer" "$(git rev-parse origin/main)"; git push -q -f origin refs/tags/v1.2.3
git tag -d v9.9.7 >/dev/null 2>&1 || true; git update-ref refs/tags/v9.9.7 "$(git rev-parse refs/tags/v1.2.3)"   # a maintainer-signed tag object under another name
run scripts/release-signature.sh verify-tag 9.9.7; check "verify-tag refuses a maintainer-signed tag object that is named something else" '[[ $rc != 0 && $out == *"renamed tag"* ]]'
git tag -d v9.9.7 >/dev/null; git tag v9.9.7 "$(git rev-parse origin/main)"
run scripts/release-signature.sh verify-tag 9.9.7; check "verify-tag refuses a lightweight tag" '[[ $rc != 0 ]]'
git tag -d v9.9.7 >/dev/null
run env SEMPERE_SIGN_DROP="$t/drop-open" bash -c 'mkdir -m 777 "$SEMPERE_SIGN_DROP"; chmod 777 "$SEMPERE_SIGN_DROP"; scripts/release-build.sh 1.2.3'; check "build refuses a hand-off folder that is world-writable (before any build)" '[[ $rc != 0 && $out == *"hand-off folder"* ]]'
[[ $(id -u) == 0 ]] || { run env SEMPERE_SIGN_DROP=/usr scripts/release-build.sh 1.2.3; check "build refuses a hand-off folder owned by someone else" '[[ $rc != 0 && $out == *"hand-off folder /usr"* ]]'; }
run scripts/release-publish.sh 1.2.3; check "publish accepts the maintainer-signed tag (and then wants a build)" '[[ $rc != 0 && $out == *"v1.2.3 is signed by a key in"* && $out == *"no build in"* ]]'
run scripts/release-tag.sh --owner-commands 1.2.4 "$(git rev-parse origin/main)"; check "--owner-commands runs the checks first" '[[ $rc != 0 && $out == *"Version.swift says"* ]]'
run scripts/release-tag.sh --owner-commands 1.2.3 main; check "--owner-commands wants a full commit id" '[[ $rc == 2 ]]'
git tag -d v1.2.3 >/dev/null; git push -q origin :refs/tags/v1.2.3
git push -q origin side   # a commit the remote has but main does not
run scripts/release-tag.sh --owner-commands 1.2.3 "$(git rev-parse origin/main)"
check "--owner-commands prints one fail-closed block with the signed tag, the check and a single-tag push" '[[ $rc == 0 && $out == *"( set -e"* && $out == *"git log -1"* && $out == *"git tag -s v1.2.3 $(git rev-parse origin/main) -m"* && $out == *"tag -v v1.2.3"* && $out == *"git push origin refs/tags/v1.2.3 )"* && $out != *"--tags"* ]] && ! git rev-parse -q --verify refs/tags/v1.2.3 >/dev/null'
printf '%s\n' "$out" | sed -n '/^( set -e/,/ )$/p' > "$t/owner-block"
# run the block AS PRINTED from another clone, as the maintainer would; a SHA that is not on main stops it before the tag and the push
git clone -q "$t/github.git" "$t/owner-clone"
owner() { ( cd "$t/owner-clone" && git config commit.gpgsign false && git config gpg.format ssh && git config user.signingkey "$t/key" && bash "$1" ); }
sed "s/$(git rev-parse origin/main)/$(git rev-parse side)/g" "$t/owner-block" > "$t/owner-block-side"
owner "$t/owner-block-side" >/dev/null 2>&1 && owner_rc=0 || owner_rc=$?
check "the printed block stops on a SHA that is not on main: no tag, nothing pushed" '[[ $owner_rc != 0 ]] && ! git -C "$t/owner-clone" rev-parse -q --verify refs/tags/v1.2.3 >/dev/null && ! git ls-remote --exit-code --tags origin v1.2.3 >/dev/null 2>&1'
sed "s/\"1.2.3\"/\"9.9.8\"/" "$t/owner-block" > "$t/owner-block-ver"
owner "$t/owner-block-ver" >/dev/null 2>&1 && owner_rc=0 || owner_rc=$?
check "the printed block stops when Version.swift does not say the version" '[[ $owner_rc != 0 ]] && ! git ls-remote --exit-code --tags origin v1.2.3 >/dev/null 2>&1'
owner "$t/owner-block" >/dev/null 2>&1 && owner_rc=0 || owner_rc=$?
check "the printed block, as printed, signs, verifies and pushes the tag" '[[ $owner_rc == 0 ]] && git ls-remote --exit-code --tags origin v1.2.3 >/dev/null 2>&1'
git fetch -q --tags origin
run scripts/release-publish.sh 1.2.3; check "publish refuses without a local build"  '[[ $rc != 0 && $out == *"no build in"* ]]'

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
run scripts/release-publish.sh 1.2.3; check "publish refuses unsigned sums" '[[ $rc != 0 && $out == *"no $d/SHA256SUMS.sig"* ]]'
# The hand-off: release-build puts SHA256SUMS (data only) into the seat's folder; the maintainer runs scripts/release-sign.sh from
# their own clone, which writes SHA256SUMS and SHA256SUMS.sig into their own folder, where release-publish reads them.
drop=$SEMPERE_SIGN_DROP/v1.2.3; signed=$SEMPERE_SIGN_OUT/v1.2.3
handoff() { mkdir -m 755 -p "$SEMPERE_SIGN_DROP" "$drop"; cp $d/SHA256SUMS "$drop/"; chmod 755 "$SEMPERE_SIGN_DROP" "$drop"; chmod 644 "$drop/SHA256SUMS"; rm -rf "$SEMPERE_SIGN_OUT"; rm -f $d/SHA256SUMS.sig; }
signit() { run bash scripts/release-sign.sh -k "${1:-$t/key}" 1.2.3; }
handoff
signit "$t/other"; check "the owner script refuses a key origin/main's signers lack, and writes no signature" '[[ $rc != 0 && $out == *"is not a key in"* && ! -f $signed/SHA256SUMS.sig ]]'
signit "$t/nonexistent"; check "the owner script refuses a missing key file" '[[ $rc != 0 && $out == *"is not a file"* ]]'
signit "key::$(cut -d' ' -f1,2 "$t/key.pub")"; check "the owner script wants a key it can sign with (key:: needs an agent)" '[[ $rc != 0 && $out == *"could not sign"* ]]'
cp "$drop/SHA256SUMS" "$t/sums.good"
echo "$(printf '0%.0s' $(seq 64))  sempere-1.2.3-extra.tar.gz" >> "$drop/SHA256SUMS"
signit; check "the owner script refuses a list with an extra line" '[[ $rc != 0 && $out == *"not one per tarball"* && ! -f $signed/SHA256SUMS.sig ]]'
{ cat "$t/sums.good"; printf '%s  evil.tar.gz\033[1A\033[2K' "$(printf '0%.0s' $(seq 64))"; } > "$drop/SHA256SUMS"
signit; check "the owner script refuses an unterminated 4th line with escape codes, and shows nothing of it" '[[ $rc != 0 && $out == *"not one per tarball"* && $out != *evil* && ! -f $signed/SHA256SUMS.sig ]]'
{ cat "$t/sums.good"; } | head -c -1 > "$drop/SHA256SUMS" 2>/dev/null || { printf '%s' "$(cat "$t/sums.good")" > "$drop/SHA256SUMS"; }
signit; check "the owner script refuses a list that does not end in a newline" '[[ $rc != 0 && $out == *"does not end in a newline"* ]]'
sed 's/sempere-1.2.3-linux-aarch64/sempere-1.2.2-linux-aarch64/' "$t/sums.good" > "$drop/SHA256SUMS"
signit; check "the owner script refuses a line for another version" '[[ $rc != 0 && $out == *"not a valid tarball line"* ]]'
sed 's/^[0-9a-f]\{64\}/abc/' "$t/sums.good" > "$drop/SHA256SUMS"
signit; check "the owner script refuses a malformed hash" '[[ $rc != 0 && $out == *"not a valid tarball line"* ]]'
cp "$t/sums.good" "$drop/SHA256SUMS"; chmod 777 "$drop"
signit; check "the owner script refuses a seat folder that is world-writable" '[[ $rc != 0 && $out == *"writable by group or world"* ]]'
chmod 755 "$drop"; chmod 775 "$drop/SHA256SUMS"
signit; check "the owner script refuses a list that is group-writable" '[[ $rc != 0 && $out == *"writable by group or world"* ]]'
chmod 644 "$drop/SHA256SUMS"
SEMPERE_BUILD_USER=nobody signit; check "the owner script refuses a seat folder that is not the build account's" '[[ $rc != 0 && $out == *"is owned by uid"* ]]'
ln -s "$drop/SHA256SUMS" "$t/link"; mv "$drop/SHA256SUMS" "$t/sums.real"; ln -s "$t/sums.real" "$drop/SHA256SUMS"
signit; check "the owner script refuses a symlinked list" '[[ $rc != 0 && $out == *"symlink"* ]]'
rm "$drop/SHA256SUMS"; cp "$t/sums.good" "$drop/SHA256SUMS"
echo '# dirty' >> scripts/release-sign.sh
signit; check "the owner script refuses scripts that differ from origin/main" '[[ $rc != 0 && $out == *"differ from origin/main"* ]]'
git checkout -q -- scripts/release-sign.sh
signit; check "the owner script signs and verifies with the test key (from the checkout, not the drop)" '[[ $rc == 0 && $out == *"done: "* && $out == *"signed by maintainer"* && -f $signed/SHA256SUMS.sig && -f $signed/SHA256SUMS ]]'
run scripts/release-publish.sh 1.2.3; check "publish takes the .sig from the maintainer's folder" '[[ $rc == 0 && $out == *"took SHA256SUMS.sig from"* && -f $d/SHA256SUMS.sig ]]'
rm $d/SHA256SUMS.sig; SEMPERE_MAINTAINER_USER=nobody run scripts/release-publish.sh 1.2.3
check "publish refuses a maintainer folder that is not the maintainer account's" '[[ $rc != 0 && $out == *"must belong to the maintainer account"* && ! -f $d/SHA256SUMS.sig ]]'
chmod 777 "$signed"
run scripts/release-publish.sh 1.2.3; check "publish refuses a maintainer folder that is world-writable" '[[ $rc != 0 && $out == *"writable by group or world"* && ! -f $d/SHA256SUMS.sig ]]'
chmod 755 "$signed"; echo "# changed after the build" >> "$signed/SHA256SUMS"
run scripts/release-publish.sh 1.2.3; check "publish refuses a signed SHA256SUMS that differs from the build's" '[[ $rc != 0 && $out == *"is not the"* && ! -f $d/SHA256SUMS.sig ]]'
handoff; mkdir -m 755 -p "$signed"; printf 'x\n' > "$signed/SHA256SUMS.sig"; cp "$d/SHA256SUMS" "$signed/"
run scripts/release-publish.sh 1.2.3; check "publish refuses a .sig that is not a signature" '[[ $rc != 0 ]]'
handoff
run scripts/release-publish.sh 1.2.3; check "publish refuses when the maintainer has not signed yet" '[[ $rc != 0 && $out == *"no $d/SHA256SUMS.sig"* ]]'
sign_dist() { rm -f $d/SHA256SUMS.sig; ssh-keygen -q -Y sign -f "${1:-$t/key}" -n file $d/SHA256SUMS >/dev/null 2>&1; }
sign_dist "$t/other"
run scripts/release-publish.sh 1.2.3; check "publish refuses a .sig made with another key" '[[ $rc != 0 && $out == *"not signed by a key"* ]]'
sign_dist >/dev/null
run scripts/release-publish.sh 1.2.3
check "publish prints the gh command and publishes nothing" '[[ $rc == 0 && $out == *"SHA256SUMS.sig"* && $out == *"gh release create v1.2.3 --repo example/none --verify-tag"* && $out == *"just formula 1.2.3"* ]]'
check "no squash machinery is left" '[[ ! -e $src/scripts/release-github.sh && $out != *squash* ]]'
run env GH_EXISTS=1 scripts/release-publish.sh 1.2.3; check "print mode refuses a Release that exists" '[[ $rc != 0 && $out == *"already exists"* ]]'
run scripts/release-publish.sh 1.2.3-rc.1; check "an unknown tag is refused" '[[ $rc != 0 && $out == *"no tag v1.2.3-rc.1"* ]]'
echo tampered >> $d/sempere-1.2.3-linux-x86_64.tar.gz
run scripts/release-publish.sh 1.2.3; check "publish refuses files that do not match SHA256SUMS" '[[ $rc != 0 && $out == *"does not match"* ]]'
tarballs   # restore the files; a rebuilt tar can differ by its mtime, so make the sums again
(cd $d && shasum -a 256 sempere-1.2.3-*.tar.gz > SHA256SUMS); sign_dist >/dev/null
git checkout -q side; git tag -a v9.9.9 -m x; git push -q origin refs/tags/v9.9.9 2>/dev/null; git tag -d v9.9.9 >/dev/null; git tag -a v9.9.9 -m y main
run scripts/release-publish.sh 9.9.9; check "publish refuses a tag that differs from GitHub's" '[[ $rc != 0 && $out == *"binaries must come from the pushed tag"* ]]'
git checkout -q main
run scripts/release-publish.sh --publish 1.2.3; check "--publish needs a terminal" '[[ $rc != 0 && $out == *"on a terminal"* ]]'
run scripts/release-publish.sh 1.2.3 --publish; check "--publish works after the version too" '[[ $rc != 0 && $out == *"on a terminal"* ]]'
check "no gh release create was run" '[[ ! -f $STUB_GH_LOG ]] || ! grep -q create "$STUB_GH_LOG"'

# Tagged again after the build: the pushed tag is no longer what was built, and publish and verify refuse.
git checkout -q -b retag main; git commit -q --allow-empty -m "after the build"; git push -q origin retag
git tag -d v1.2.3 >/dev/null; stag v1.2.3 -m again retag; git push -q -f origin refs/tags/v1.2.3
run scripts/release-publish.sh 1.2.3; check "publish refuses a build from another commit than the tag" '[[ $rc != 0 && $out == *"was built from"* ]]'
git tag -d v1.2.3 >/dev/null; stag v1.2.3 -m orig "$(cat $d/COMMIT)"; git push -q -f origin refs/tags/v1.2.3; git checkout -q main
echo extra > $d/sempere-1.2.3-extra.tar.gz
run scripts/release-publish.sh 1.2.3; check "publish refuses a tarball missing from SHA256SUMS" '[[ $rc != 0 && $out == *"not in SHA256SUMS"* ]]'
rm $d/sempere-1.2.3-extra.tar.gz

# release-verify: GitHub's tag against this checkout, and the Gitea mirror when a `gitea` remote exists.
git init -q --bare "$t/gitea.git"; git remote add gitea "$t/gitea.git"
tarballs; (cd $d && shasum -a 256 sempere-1.2.3-*.tar.gz > SHA256SUMS); sign_dist >/dev/null
mkdir -p "$t/dl/releases/download/v1.2.3"; cp $d/* "$t/dl/releases/download/v1.2.3/"
export SEMPERE_RELEASE_URL="file://$t/dl"
cp $d/COMMIT $t/COMMIT.bak; git rev-parse retag > $d/COMMIT
run scripts/release-verify.sh 1.2.3; check "verify refuses a local build of another commit" '[[ $rc != 0 && $out == *"local build is of"* ]]'
cp $t/COMMIT.bak $d/COMMIT
run scripts/release-verify.sh 1.2.3; check "verify warns while the mirror lacks the tag" '[[ $rc == 0 && $out == *"ok    GitHub'"'"'s v1.2.3"* && $out == *"warn  the Gitea mirror has"* ]]'
run scripts/release-verify.sh 1.2.3; check "verify checks the published signature" '[[ $out == *"SHA256SUMS signed by maintainer"* ]]'
echo tampered >> "$t/dl/releases/download/v1.2.3/SHA256SUMS"
run scripts/release-verify.sh 1.2.3; check "verify refuses a published list its signature does not cover" '[[ $rc != 0 ]]'
cp $d/SHA256SUMS "$t/dl/releases/download/v1.2.3/SHA256SUMS"
mv "$t/dl/releases/download/v1.2.3/SHA256SUMS.sig" "$t/sig.bak"
run scripts/release-verify.sh 1.2.3; check "verify fails a release from 1.1.0 on without its signature" '[[ $rc != 0 && $out == *"has no SHA256SUMS.sig"* ]]'
mv "$t/sig.bak" "$t/dl/releases/download/v1.2.3/SHA256SUMS.sig"
git push -q gitea refs/tags/v1.2.3 refs/heads/main
run scripts/release-verify.sh 1.2.3; check "verify sees the mirror's tag" '[[ $rc == 0 && $out == *"the Gitea mirror has v1.2.3 at the same commit"* ]]'
exit $fail
