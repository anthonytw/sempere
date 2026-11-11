#!/bin/bash
# Install Ubuntu packages in a CI container, surviving a flaky or unreachable archive (2026-11-11: every Linux job failed
# for hours on "Could not resolve 'archive.ubuntu.com'" while github.com resolved).
#
#   scripts/apt-install.sh PACKAGE...
#
# Tries the image's own sources twice, then switches them to Azure's mirror of the Ubuntu archive (the one GitHub's
# runner hosts use) and tries twice more. apt checks every package against the archive's signed Release files, so
# the mirror changes where packages come from, never what is trusted.
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: $0 PACKAGE..." >&2; exit 2; }
export DEBIAN_FRONTEND=noninteractive
mirror=http://azure.archive.ubuntu.com/ubuntu/

attempt() {
  apt-get -o Acquire::Retries=3 -o APT::Update::Error-Mode=any update -q >/dev/null &&
    apt-get -o Acquire::Retries=3 install -y -q "$@" >/dev/null
}

for try in 1 2 3 4; do
  attempt "$@" && exit 0
  if [ "$try" = 2 ]; then
    echo "apt-install: the image's archive failed twice; switching to $mirror" >&2
    for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list; do
      [ -f "$f" ] && sed -i -E "s#https?://(archive|security)\.ubuntu\.com/ubuntu/?#$mirror#g" "$f"
    done
  fi
  [ "$try" = 4 ] || { echo "apt-install: attempt $try failed; retrying in $((try * 10)) s" >&2; sleep $((try * 10)); }
done
echo "apt-install: could not install $* after 4 attempts" >&2
exit 1
