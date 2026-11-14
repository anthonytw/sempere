#!/usr/bin/env bash
# The fingerprints of the keys in packaging/allowed_signers, derived from the file (never typed anywhere), and the check that
# SECURITY.md publishes each of them (docs/design/1.2-audit-followups.md F-13). Used by release-build.sh (the release notes'
# footer, and a refusal to build when main's SECURITY.md lacks a key) and by check-security.sh (the same check at the PR, so a
# key change without SECURITY.md fails there rather than at release time).
#
#   scripts/release-fingerprints.sh [--signers FILE] list              one SHA256:... per line
#   scripts/release-fingerprints.sh [--signers FILE] check DOC         fail unless DOC (a file, or - for stdin) names every one
#
# `ssh-keygen -lf` rejects an allowed_signers file (principal and options in front), so the key type and blob are cut out first.
set -euo pipefail
signers=packaging/allowed_signers
[[ ${1:-} == --signers ]] && { signers=$2; shift 2; }
[[ -f $signers ]] || { echo "error: no $signers" >&2; exit 1; }

list() {
  local out
  out=$(grep -vE '^[[:space:]]*(#|$)' "$signers" |
        grep -oE '(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-[a-z0-9]+|sk-ecdsa-sha2-[a-z0-9]+@openssh\.com|ssh-rsa) [A-Za-z0-9+/=]+' |
        ssh-keygen -lf - 2>/dev/null | awk '{print $2}') || true
  [[ -n $out ]] || { echo "error: cannot read a key fingerprint from $signers" >&2; exit 1; }
  printf '%s\n' "$out"
}

case "${1:-}" in
  list) list ;;
  check)
    [[ -n ${2:-} ]] || { echo "usage: $0 check DOC" >&2; exit 2; }
    if [[ $2 == - ]]; then doc=$(cat); else doc=$(cat -- "$2"); fi
    fps=$(list); bad=0
    while IFS= read -r fp; do
      grep -qF -- "$fp" <<<"$doc" || { echo "error: SECURITY.md does not publish $fp (the key in $signers)" >&2; bad=1; }
    done <<<"$fps"
    exit $bad ;;
  *) echo "usage: $0 [--signers FILE] list | check DOC" >&2; exit 2 ;;
esac
