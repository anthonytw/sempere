#!/usr/bin/env bash
# Sign a release's SHA256SUMS with YOUR SSH key (docs/releasing.md). Self-contained: it needs only ssh-keygen and git
# (for the key setting), not the repository. scripts/release-build.sh copies it, SHA256SUMS and allowed_signers into
# the hand-off folder (/Users/Shared/sempere-release/vVERSION by default); run it from your own account:
#
#   bash /Users/Shared/sempere-release/vVERSION/release-sign.sh [-k KEY] [DIR]
#
# DIR defaults to the folder this script is in. KEY is a key file, or `key::ssh-ed25519 AAAA...` for a key held by
# ssh-agent; the default is `git config user.signingkey`. It writes DIR/SHA256SUMS.sig (namespace `file`) and says
# "done" only after the signature verifies against DIR/allowed_signers, so a wrong key is caught here, not at publish.
set -euo pipefail
die() { echo "error: $*" >&2; exit 1; }
key=""
while getopts k: o; do case $o in k) key=$OPTARG ;; *) echo "usage: $0 [-k KEY] [DIR]" >&2; exit 2 ;; esac; done
shift $((OPTIND - 1))
d=${1:-$(cd "$(dirname "$0")" && pwd)}
[[ -f $d/SHA256SUMS ]] || die "no $d/SHA256SUMS"
[[ -f $d/allowed_signers ]] || die "no $d/allowed_signers"
[[ -n $key ]] || key=$(git config --get user.signingkey || true)
[[ -n $key ]] || die "no signing key: pass -k KEY or set git's user.signingkey"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [[ $key == key::* ]]; then printf '%s\n' "${key#key::}" > "$tmp/key.pub"; key=$tmp/key.pub
else key=${key/#\~/$HOME}; [[ -f $key ]] || die "the signing key $key is not a file"; fi

echo "Signing this list:"; sed 's/^/  /' "$d/SHA256SUMS"
rm -f "$d/SHA256SUMS.sig"
ssh-keygen -Y sign -f "$key" -n file "$d/SHA256SUMS" >/dev/null 2>&1 || die "ssh-keygen could not sign with $key (an agent that holds the key must be running)"
who=$(ssh-keygen -Y find-principals -f "$d/allowed_signers" -s "$d/SHA256SUMS.sig" 2>/dev/null | head -1) || true
[[ -n $who ]] || { rm -f "$d/SHA256SUMS.sig"; die "$key is not a key in $d/allowed_signers: wrong key, nothing written"; }
ssh-keygen -Y verify -f "$d/allowed_signers" -I "$who" -n file -s "$d/SHA256SUMS.sig" < "$d/SHA256SUMS" >/dev/null 2>&1 \
  || die "the signature does not verify against $d/SHA256SUMS"
echo "done: $d/SHA256SUMS.sig signed by $who. Next, in the build account: just release-publish VERSION"
