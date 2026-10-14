#!/usr/bin/env bash
# Fill packaging/homebrew/sempere.rb from a published release's SHA256SUMS.
#   scripts/update-formula.sh 0.5.0 > /path/to/homebrew-tap/Formula/sempere.rb
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: update-formula.sh VERSION}"; version="${version#v}"
sums="$(curl -fsSL "https://github.com/anthonytw/sempere/releases/download/v${version}/SHA256SUMS")"
sum() { printf '%s\n' "$sums" | awk -v f="sempere-${version}-$1.tar.gz" '$2 == f { print $1 }' | grep .; }
# Assignments, not $(...) inside sed's arguments: a missing checksum must stop the script
# (set -e ignores a failing command substitution used as an argument), never write an empty sha256.
mac="$(sum macos-universal)" || { echo "error: no macos-universal checksum in SHA256SUMS" >&2; exit 1; }
lx="$(sum linux-x86_64)" || { echo "error: no linux-x86_64 checksum in SHA256SUMS" >&2; exit 1; }
la="$(sum linux-aarch64)" || { echo "error: no linux-aarch64 checksum in SHA256SUMS" >&2; exit 1; }
sed -e "s/@VERSION@/${version}/" \
    -e "s/@SHA256_MACOS_UNIVERSAL@/${mac}/" \
    -e "s/@SHA256_LINUX_X86_64@/${lx}/" \
    -e "s/@SHA256_LINUX_AARCH64@/${la}/" \
    packaging/homebrew/sempere.rb
