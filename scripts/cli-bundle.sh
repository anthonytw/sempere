#!/usr/bin/env bash
# The macOS CLI as a bundle (docs/design/1.4-cloudkit.md §6.5).
#   scripts/cli-bundle.sh BINARY VERSION OUTDIR [FONTS_DIR]
# Makes OUTDIR/sempere.app: Contents/Info.plist (packaging/cli/Info.plist with @VERSION@), Contents/MacOS/sempere (BINARY) and,
# when FONTS_DIR is given, Contents/Resources/fonts/ (the Noto fonts: `SempereFonts.directory` looks beside the executable
# and in ../Resources/fonts, through the Homebrew symlink). Unsigned: release-build packages it so, and the maintainer signs it
# (scripts/release-sign-macos.sh), because Developer ID signing needs a key that is not on the build account.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=${1:?binary}; version=${2:?version}; out=${3:?outdir}; fonts=${4:-}
[[ -f $bin ]] || { echo "error: no binary $bin" >&2; exit 1; }
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "error: '$version' is not X.Y.Z" >&2; exit 1; }
app=$out/sempere.app
rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
# CFBundleShortVersionString is numeric: a prerelease's suffix is dropped.
sed "s/@VERSION@/${version%%-*}/g" packaging/cli/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
install -m 0755 "$bin" "$app/Contents/MacOS/sempere"
if [[ -n $fonts ]]; then mkdir -p "$app/Contents/Resources/fonts"; cp "$fonts"/* "$app/Contents/Resources/fonts/"; fi
echo "$app"
