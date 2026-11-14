#!/usr/bin/env bash
# Build a release's CLI binaries on this Mac (docs/releasing.md, docs/design/local-first.md): what GitHub's
# release workflow used to do. Nothing is uploaded or pushed.
#
#   scripts/release-build.sh VERSION
#
# Needs the tag vVERSION, made and pushed by the maintainer (scripts/release-tag.sh --owner-commands), and Docker. A
# release from 1.1.0 on (not a prerelease) is refused unless the tag is signed by a key in packaging/allowed_signers. Builds from a clean
# worktree of the tag, so the binaries are built from exactly the tagged sources. The build and packaging scripts are
# this checkout's (so an older tag gets the current ones), and the script refuses to run unless this tree is clean and
# scripts/ and packaging/ equal origin/main's: nothing local can slip into a release. Every image is pinned by digest. Steps:
#   1. checks: the tag passed the release sweep or, for a CLI-only release, local/cli-suite
#      (scripts/release-sweep-check.sh; a prerelease only warns), Version.swift and CHANGELOG.md say VERSION
#   2. Linux x86_64 and aarch64: the fully static binaries (Static Linux SDK, scripts/ci-linux.sh static),
#      built in the swift:6.4.2 image for both architectures from this Mac's one
#   3. macOS: the universal binary (swift build --arch arm64 --arch x86_64)
#      Steps 2 and 3 are three builds that run AT ONCE (a log each under build/release/vVERSION/logs/, printed when one fails;
#      each Linux build has fresh Docker volumes of its own, F-01). The Static Linux SDK archive is downloaded once into
#      ~/.cache/sempere/swift-sdk, checked against its pinned SHA-256 on every use (a bad file is deleted and fetched again)
#      and mounted read-only (scripts/static-sdk-cache.sh). The versions and tarballs are checked after all three finish.
#   4. each binary reports VERSION; tarballs via scripts/package-cli.sh (Linux ones in the image, GNU tar)
#   5. the Linux tarballs installed and run in Debian 12, Ubuntu 22.04 and 26.04, Fedora 41 and Alpine 3.20
#      (scripts/smoke-linux-cli.sh). The architecture Docker runs natively must pass; the emulated one
#      is reported, because emulation has failed on its own before (tar under qemu on Ubuntu 26.04)
#   6. SHA256SUMS and notes.md (the CHANGELOG section). This build account cannot use the maintainer's key, so it signs
#      nothing: SHA256SUMS goes to a hand-off folder (SEMPERE_SIGN_DROP, default /Users/Shared/sempere-release, then
#      vVERSION/; owned by this account, never group- or world-writable, checked before the long build). The maintainer
#      signs from their own clone of GitHub (scripts/release-sign.sh at origin/main; docs/releasing.md)
# Output: build/release/vVERSION/. Next: the maintainer signs, then scripts/release-publish.sh VERSION.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
version=${1:?usage: $0 VERSION}; version=${version#v}
tag=v$version
die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

# Images, by digest (a tag can move; update with `docker buildx imagetools inspect NAME`). The swift one is the CI test image.
PACK_IMAGE=swift:6.4-noble@sha256:bca121f6eb59fd80340d1296887b2698ed8f3eb9eca7d80c181f8af769dc7ee0
ALPINE_IMAGE=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
SMOKE_IMAGES=(
  debian:12@sha256:268fb24c39bca92d326dd83ea3abebe4a3f7751c804ffef23bb6d857dd343ff8
  ubuntu:22.04@sha256:076e7bf82319619f28dd0aa9c02ab34b055ad37100395b4f49a2ffba04fb5e11
  ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c
  fedora:41@sha256:f1a3fab47bcb3c3ddf3135d5ee7ba8b7b25f2e809a47440936212a3a50957f3d
  $ALPINE_IMAGE
)
# The scripts this one copies from this checkout into the tag's worktree.
TOOLING=(scripts/ci-linux.sh scripts/package-cli.sh scripts/smoke-linux-cli.sh scripts/build-linux-static.sh scripts/static-sdk-pin.sh scripts/static-sdk-cache.sh scripts/release-build-all.sh scripts/apt-install.sh)
unset SEMPERE_LINUX_BUILD_VOLUME   # a release build always starts from fresh volumes

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "no tag $tag here (just release-tag $version)"
sha=$(git rev-parse "$tag^{commit}")
remote=${SEMPERE_RELEASE_REMOTE:-origin}
git fetch -q "$remote" main || die "cannot fetch $remote main to compare the build scripts with"
[[ -z $(git status --porcelain --untracked-files=no) ]] || die "this tree has uncommitted changes; the build scripts must be main's"
git diff --quiet "$remote/main" -- scripts/ packaging/ || die "scripts/ or packaging/ differ from $remote/main: build from a checkout of main"
scripts/release-signature.sh verify-tag "$version" >&2 || die "$tag must be signed by the maintainer before it is built"
# The hand-off folder has one writer, this account: a folder anyone else can write to would let them swap the list the maintainer signs.
drop=${SEMPERE_SIGN_DROP:-/Users/Shared/sempere-release}
[[ -e $drop ]] || mkdir -m 755 -p "$drop"
scripts/release-signature.sh owned "$drop" "$(id -u)" >&2 || die "the hand-off folder $drop must be owned by this account and not writable by group or world"
[[ -e $drop/$tag ]] || mkdir -m 755 "$drop/$tag"
scripts/release-signature.sh owned "$drop/$tag" "$(id -u)" >&2 || die "the hand-off folder $drop/$tag must be owned by this account and not writable by group or world"
command -v docker >/dev/null || die "Docker is needed for the Linux builds"
out=$repo/build/release/$tag
src=$repo/build/release/$tag-src
rm -rf "$out"; mkdir -p "$out"
echo "$sha" > "$out/COMMIT"   # what release-publish and release-verify compare the pushed tag with

step "checks on $(git log --oneline -1 "$sha")"
if line=$(scripts/release-sweep-check.sh "$sha"); then echo "$line"
elif [[ $version == *-* ]]; then echo "warn  ${line#FAIL  } (a prerelease only warns)"
else echo "$line"; die "$tag has not passed its release checks"; fi
v=$(git show "$sha:Sources/SempereCLI/Version.swift" | sed -n 's/^let sempereVersion = "\(.*\)"$/\1/p')
[[ $v == "$version" ]] || die "Version.swift at $tag says '$v'"
f=$(mktemp); git show "$sha:CHANGELOG.md" > "$f"
scripts/changelog-section.sh --file "$f" "$version" > "$out/notes.md" || die "CHANGELOG.md at $tag has no finished section for $version"
rm -f "$f"
# The standard footer: the signing key's fingerprint, to compare with SECURITY.md and the website's security page (a key
# change changes all three; docs/design/1.2-audit-followups.md F-13).
signer_fingerprint="SHA256:u94X5C2t2zAT9krLN4+LLwC3UI/z8d0v0tmuq6y90fM"
printf '\n---\n\nVerify this release: `SHA256SUMS.sig` is signed by the maintainer'"'"'s key, fingerprint `%s`. Compare it with `SECURITY.md` in the repository and the security page of the project website; if they differ, do not trust this release. See [Verifying releases](https://github.com/anthonytw/sempere/blob/main/SECURITY.md#verifying-releases).\n' "$signer_fingerprint" >> "$out/notes.md"
echo "ok    Version.swift and CHANGELOG.md say $version"

step "worktree of $tag"
git worktree remove --force "$src" 2>/dev/null || rm -rf "$src"
git worktree add -q --detach "$src" "$sha"
trap 'git -C "$repo" worktree remove --force "$src" 2>/dev/null || true' EXIT
cd "$src"
# The release tooling is this checkout's (a tag may predate it; checked above to be main's); the sources are the tag's.
for f in "${TOOLING[@]}"; do cp "$repo/$f" "$f"; done

step "The three builds, at once: Linux x86_64, Linux aarch64, macOS universal"
# scripts/release-build-all.sh: independent builds on a Mac that sits mostly idle during a serial one; a log each in
# build/release/vX/logs/ (the tail of a failed one is printed), fresh Docker volumes per Linux build (F-01), the SDK archive
# downloaded once and verified (scripts/static-sdk-cache.sh). Run in the background and waited for, so a TERM or HUP to this
# script reaches the trap below at once: it stops the builds (their containers included) before the worktree goes.
all_pid=
trap 'if [[ -n $all_pid ]]; then kill "$all_pid" 2>/dev/null || true; wait "$all_pid" 2>/dev/null || true; fi; git -C "$repo" worktree remove --force "$src" 2>/dev/null || true' EXIT
trap 'exit 143' TERM HUP INT
scripts/release-build-all.sh "$out/logs" & all_pid=$!
wait "$all_pid" || { all_pid=; die "a build failed (see above)"; }
all_pid=

step "Linux static binaries"
for arch in x86_64 aarch64; do
  platform=linux/amd64; [[ $arch == aarch64 ]] && platform=linux/arm64
  # The whole output, then its first line: `| head -1` closes the pipe early and, with pipefail, fails the build when
  # the writer (docker here) is still writing the version text's other lines.
  got=$(docker run --rm --platform "$platform" -v "$src:/src:ro" "$ALPINE_IMAGE" /src/build/linux-static/sempere-$arch --version)
  got=${got%%$'\n'*}
  [[ $got == "sempere $version" ]] || die "the Linux $arch binary says '$got'"
  docker run --rm -v "$src:/src" -w /src "$PACK_IMAGE" \
    scripts/package-cli.sh "build/linux-static/sempere-$arch" "$version" "linux-$arch" build/dist >/dev/null
done
echo "ok    linux-x86_64, linux-aarch64"

step "macOS universal binary"
bin="$(swift build -c release --product sempere --arch arm64 --arch x86_64 --show-bin-path)/sempere"
archs=$(lipo -archs "$bin")
[[ $archs == *arm64* && $archs == *x86_64* ]] || die "the macOS binary has only: $archs"
got=$("$bin" --version); got=${got%%$'\n'*}
[[ $got == "sempere $version" ]] || die "the macOS binary says '$got'"
scripts/package-cli.sh "$bin" "$version" macos-universal build/dist >/dev/null
echo "ok    macos-universal ($archs)"
cp build/dist/*.tar.gz "$out/"

step "Linux tarballs on other distributions"
native=aarch64; [[ $(docker info --format '{{.Architecture}}') == x86_64 ]] && native=x86_64
failed=false
for arch in x86_64 aarch64; do
  platform=linux/amd64; [[ $arch == aarch64 ]] && platform=linux/arm64
  for image in "${SMOKE_IMAGES[@]}"; do
    name=${image%%@*}
    if docker run --rm --platform "$platform" -v "$src:/w:ro" -v "$out:/dist:ro" "$image" sh -c '
        if command -v apk >/dev/null; then apk add -q ca-certificates >/dev/null
        elif command -v apt-get >/dev/null; then apt-get update -qq >/dev/null && apt-get install -y -qq ca-certificates >/dev/null
        fi
        sh /w/scripts/smoke-linux-cli.sh "/dist/sempere-$0-linux-$1.tar.gz" "$0"' "$version" "$arch" >"$out/smoke-$arch-${name//:/-}.log" 2>&1; then
      echo "ok    $name $arch"
    elif [[ $arch == "$native" ]]; then
      echo "FAIL  $name $arch: $out/smoke-$arch-${name//:/-}.log"; failed=true
    else
      echo "warn  $name $arch (emulated): $out/smoke-$arch-${name//:/-}.log"
    fi
  done
done
[[ $failed == false ]] || die "a native smoke test failed"

step "SHA256SUMS"
(cd "$out" && shasum -a 256 *.tar.gz > SHA256SUMS && cat SHA256SUMS)

step "hand-off to the maintainer"
rm -f "$drop/$tag/SHA256SUMS"
cp "$out/SHA256SUMS" "$drop/$tag/SHA256SUMS"; chmod 0644 "$drop/$tag/SHA256SUMS"
echo "built $tag in $out. Hand-off folder: $drop/$tag (SHA256SUMS only; the list above is what the maintainer should see)"
echo "Next, from the maintainer's own account, in their clone of GitHub:"
echo "  git fetch origin && git checkout --detach origin/main && bash scripts/release-sign.sh $version"
echo "then, here: just release-publish $version"
