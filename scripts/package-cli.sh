#!/usr/bin/env bash
# Package a built CLI binary as a release tarball.
#   scripts/package-cli.sh BINARY VERSION PLATFORM OUTDIR
# Produces OUTDIR/sempere-VERSION-PLATFORM.tar.gz containing
# sempere-VERSION-PLATFORM/{sempere,LICENSE,LICENSE-EXCEPTION,README.md,CHANGELOG.md,docs/cli.md,fonts/}
# (fonts/: the Noto fonts for text in exports and their OFL license, found next to the binary).
# With SEMPERE_CLI_BUNDLE=DIR (the macOS tarball): the binary is the bundle DIR/sempere.app instead
# (sempere-VERSION-macos-universal/sempere.app, scripts/cli-bundle.sh; its fonts are inside it), and there is no top-level
# `sempere` or fonts/: Homebrew links bin/sempere into the bundle (docs/design/1.4-cloudkit.md §6.5).
set -euo pipefail
cd "$(dirname "$0")/.."
bin="${1:?binary}"; version="${2:?version}"; platform="${3:?platform}"; out="${4:?outdir}"
name="sempere-${version}-${platform}"
stage="$(mktemp -d)/${name}"
mkdir -p "$stage/docs" "$out"
if [[ -n ${SEMPERE_CLI_BUNDLE:-} ]]; then
  cp -R "$SEMPERE_CLI_BUNDLE/sempere.app" "$stage/sempere.app"
else
  mkdir -p "$stage/fonts"
  install -m 0755 "$bin" "$stage/sempere"
  cp Sources/SempereFonts/Fonts/* "$stage/fonts/"
fi
cp LICENSE LICENSE-EXCEPTION README.md CHANGELOG.md "$stage/"
cp docs/cli.md "$stage/docs/"
# Fixed owner and timestamps keep the tarball content independent of the runner.
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2000-01-01 00:00Z' \
  -C "$(dirname "$stage")" -cf - "$name" 2>/dev/null | gzip -9n > "$out/${name}.tar.gz" \
  || { # bsdtar (macOS) has no --sort/--mtime
    COPYFILE_DISABLE=1 tar -C "$(dirname "$stage")" -czf "$out/${name}.tar.gz" "$name"; }
echo "$out/${name}.tar.gz"
