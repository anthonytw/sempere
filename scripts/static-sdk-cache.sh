#!/usr/bin/env bash
# Host-side cache of the Static Linux SDK archive (~/.cache/sempere/swift-sdk/<file>; SEMPERE_SDK_CACHE overrides the folder),
# so a release build downloads it once, not once per architecture and per build. Prints the archive's path.
#
#   scripts/static-sdk-cache.sh
#
# The archive is ALWAYS checked against the pinned SHA-256 (scripts/static-sdk-pin.sh) before its path is printed: a cached file
# that does not match (or is a symlink, or not a regular file) is deleted and downloaded again, never used. A download is
# checked before it is moved into place (atomic rename), so two builds at once cannot see a half-written file. The containers
# mount it read-only and check it again (scripts/build-linux-static.sh): this is a download cache, not a trust anchor.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/static-sdk-pin.sh

dir=${SEMPERE_SDK_CACHE:-$HOME/.cache/sempere/swift-sdk}
file=$dir/$(basename "$SDK_URL")
mkdir -p "$dir"; chmod 700 "$dir" 2>/dev/null || true

if [[ -e $file || -L $file ]]; then
  if [[ -f $file && ! -L $file && $(sha256_of "$file") == "$SDK_SHA256" ]]; then echo "$file"; exit 0; fi
  echo "static-sdk-cache: $file does not match the pinned checksum (or is not a plain file): deleting it" >&2
  rm -f "$file"
fi
echo "static-sdk-cache: downloading $SDK_URL" >&2
tmp=$(mktemp "$dir/.download.XXXXXX")
trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp" "$SDK_URL" >&2
got=$(sha256_of "$tmp")
[[ $got == "$SDK_SHA256" ]] || { echo "error: the downloaded SDK has SHA-256 $got, expected $SDK_SHA256" >&2; exit 1; }
mv -f "$tmp" "$file"; trap - EXIT
echo "$file"
