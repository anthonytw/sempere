#!/usr/bin/env bash
# The signature on a release's SHA256SUMS (SECURITY.md "Verifying releases"). Releases are built on the maintainer's
# Mac, so there is no build attestation; the maintainer's SSH signing key signs the list of checksums instead.
#
#   scripts/release-signature.sh sign   DIR      writes DIR/SHA256SUMS.sig with the git signing key, then verifies it
#   scripts/release-signature.sh verify DIR      checks DIR/SHA256SUMS against DIR/SHA256SUMS.sig
#   scripts/release-signature.sh ready           checks that signing can work (a key, and its line in the signers file)
#
# The signers file is packaging/allowed_signers (`ssh-keygen -Y verify` format; its lines are published in SECURITY.md);
# SEMPERE_RELEASE_SIGNERS names another one. The key is SEMPERE_RELEASE_SIGNING_KEY or `git config user.signingkey`
# (a key file, or `key::ssh-ed25519 ...` for a key in an agent). The namespace is `file`.
set -euo pipefail
cd "$(dirname "$0")/.."
signers=${SEMPERE_RELEASE_SIGNERS:-packaging/allowed_signers}
die() { echo "error: $*" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

key_file() {   # prints a path ssh-keygen -Y sign -f accepts
  local k=${SEMPERE_RELEASE_SIGNING_KEY:-$(git config --get user.signingkey || true)}
  [[ -n $k ]] || die "no signing key: set git's user.signingkey (or SEMPERE_RELEASE_SIGNING_KEY)"
  if [[ $k == key::* ]]; then printf '%s\n' "${k#key::}" > "$tmp/key.pub"; echo "$tmp/key.pub"; return; fi
  k=${k/#\~/$HOME}
  [[ -f $k ]] || die "the signing key $k is not a file"
  echo "$k"
}

verify() {   # DIR
  local d=$1
  [[ -f $signers ]] || die "no $signers: add the maintainer's line (see SECURITY.md)"
  [[ -f $d/SHA256SUMS.sig ]] || die "no $d/SHA256SUMS.sig"
  local who
  who=$(ssh-keygen -Y find-principals -f "$signers" -s "$d/SHA256SUMS.sig" 2>/dev/null | head -1) || true
  [[ -n $who ]] || die "$d/SHA256SUMS.sig is not signed by a key in $signers"
  ssh-keygen -Y verify -f "$signers" -I "$who" -n file -s "$d/SHA256SUMS.sig" < "$d/SHA256SUMS" >/dev/null 2>&1 \
    || die "$d/SHA256SUMS.sig does not verify against $d/SHA256SUMS"
  echo "ok    SHA256SUMS signed by $who"
}

case ${1:-} in
  sign)
    d=${2:?usage: $0 sign DIR}
    [[ -f $d/SHA256SUMS ]] || die "no $d/SHA256SUMS"
    [[ -f $signers ]] || die "no $signers: add the maintainer's line (see SECURITY.md)"
    k=$(key_file)
    rm -f "$d/SHA256SUMS.sig"
    ssh-keygen -Y sign -f "$k" -n file "$d/SHA256SUMS" >/dev/null 2>&1 || die "ssh-keygen could not sign with $k (an agent that holds the key must be running)"
    verify "$d" ;;
  verify) verify "${2:?usage: $0 verify DIR}" ;;
  ready)
    [[ -f $signers ]] || die "no $signers: add the maintainer's line (see SECURITY.md)"
    k=$(key_file); echo probe > "$tmp/probe"
    ssh-keygen -Y sign -f "$k" -n file "$tmp/probe" >/dev/null 2>&1 || die "cannot sign with $k (is the agent that holds the key running?)"
    ssh-keygen -Y find-principals -f "$signers" -s "$tmp/probe.sig" >/dev/null 2>&1 || die "$k is not a key in $signers"
    echo "ok    release signing: $k is in $signers" ;;
  *) sed -n '2,13p' "$0" >&2; exit 2 ;;
esac
