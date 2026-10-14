#!/usr/bin/env bash
# Package a built CLI binary as a release tarball.
#   scripts/package-cli.sh BINARY VERSION PLATFORM OUTDIR
# Produces OUTDIR/sempere-VERSION-PLATFORM.tar.gz containing
# sempere-VERSION-PLATFORM/{sempere,LICENSE,LICENSE-EXCEPTION,README.md,CHANGELOG.md,docs/cli.md,fonts/}
# (fonts/: the Noto fonts for text in exports and their OFL licence, found next to the binary).
set -euo pipefail
cd "$(dirname "$0")/.."
bin="${1:?binary}"; version="${2:?version}"; platform="${3:?platform}"; out="${4:?outdir}"
name="sempere-${version}-${platform}"
stage="$(mktemp -d)/${name}"
mkdir -p "$stage/docs" "$stage/fonts" "$out"
install -m 0755 "$bin" "$stage/sempere"
cp LICENSE LICENSE-EXCEPTION README.md CHANGELOG.md "$stage/"
cp docs/cli.md "$stage/docs/"
cp Sources/SempereFonts/Fonts/* "$stage/fonts/"
# Fixed owner and timestamps keep the tarball content independent of the runner.
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2000-01-01 00:00Z' \
  -C "$(dirname "$stage")" -cf - "$name" 2>/dev/null | gzip -9n > "$out/${name}.tar.gz" \
  || { # bsdtar (macOS) has no --sort/--mtime
    tar -C "$(dirname "$stage")" -czf "$out/${name}.tar.gz" "$name"; }
echo "$out/${name}.tar.gz"
