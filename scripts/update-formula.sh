#!/usr/bin/env bash
# Fill packaging/homebrew/sempere.rb from a release's SHA256SUMS (the local build's, else the published one).
#   scripts/update-formula.sh 0.5.0 > /path/to/homebrew-tap/Formula/sempere.rb
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: update-formula.sh VERSION}"; version="${version#v}"
# The local build's SHA256SUMS (scripts/release-build.sh) if it is here, else the published release's.
local_sums="build/release/v${version}/SHA256SUMS"
if [ -f "$local_sums" ]; then sums="$(cat "$local_sums")"
else sums="$(curl -fsSL "https://github.com/anthonytw/sempere/releases/download/v${version}/SHA256SUMS")"; fi
sum() { printf '%s\n' "$sums" | awk -v f="sempere-${version}-$1.tar.gz" '$2 == f { print $1 }' | grep .; }
# Assignments, not $(...) inside sed's arguments: a missing checksum must stop the script
# (set -e ignores a failing command substitution used as an argument), never write an empty sha256.
mac="$(sum macos-universal)" || { echo "error: no macos-universal checksum in SHA256SUMS" >&2; exit 1; }
lx="$(sum linux-x86_64)" || { echo "error: no linux-x86_64 checksum in SHA256SUMS" >&2; exit 1; }
la="$(sum linux-aarch64)" || { echo "error: no linux-aarch64 checksum in SHA256SUMS" >&2; exit 1; }
sed -e "s/@VERSION@/${version}/g" \
    -e "s/@SHA256_MACOS_UNIVERSAL@/${mac}/g" \
    -e "s/@SHA256_LINUX_X86_64@/${lx}/g" \
    -e "s/@SHA256_LINUX_AARCH64@/${la}/g" \
    packaging/homebrew/sempere.rb
