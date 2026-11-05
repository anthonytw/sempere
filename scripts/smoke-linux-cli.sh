#!/bin/sh
# Install a Linux release tarball the way docs tell users to (bin/ + share/sempere/fonts) and check
# that it runs on this distribution: version, a new vault, its fonts, HTTPS with certificate checks.
#
#   scripts/smoke-linux-cli.sh TARBALL VERSION     POSIX sh (Alpine has no bash); needs network
#
# release.yml's `linux-distros` job runs it in several distribution images before publishing.
set -eu
tarball=$1 version=$2
work=$(mktemp -d)
tar xzf "$tarball" -C "$work"
dir=$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -1)
mkdir -p "$work/p/bin" "$work/p/share/sempere"
cp "$dir/sempere" "$work/p/bin/" && cp -R "$dir/fonts" "$work/p/share/sempere/fonts"
s="$work/p/bin/sempere"

got=$("$s" --version | head -1)
[ "$got" = "sempere $version" ] || { echo "FAIL version: $got"; exit 1; }
"$s" vault init "$work/T.sempere" --recovery-out "$work/r.key" >/dev/null || { echo "FAIL vault init"; exit 1; }
# A plain HTTPS site answers PROPFIND with an HTTP error: TLS worked and the CA bundle was found.
out=$("$s" webdav check https://example.com/ 2>&1 || true)
case $out in *"HTTP "[0-9]*) ;; *) echo "FAIL https: $out"; exit 1 ;; esac
# A bad certificate must be refused.
out=$("$s" webdav check https://expired.badssl.com/ 2>&1 || true)
case $out in *"SSL certificate"*) ;; *) echo "FAIL bad cert accepted or other error: $out"; exit 1 ;; esac
echo "ok    $(. /etc/os-release && echo "$PRETTY_NAME") $(uname -m): $got"
