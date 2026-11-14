#!/bin/bash
# Install Ubuntu packages in a CI container, surviving a flaky or unreachable archive (2026-11-11: every Linux job failed
# for hours on "Could not resolve 'archive.ubuntu.com'" while github.com resolved).
#
#   scripts/apt-install.sh PACKAGE...
#
# Tries the image's own sources twice, then (amd64 only) switches them to Azure's mirror of the Ubuntu archive (the one
# GitHub's runner hosts use) and tries twice more. apt checks every package against the archive's signed Release files,
# so the mirror changes where packages come from, never what is trusted.
#
# The mirror is served over HTTPS (azure.archive.ubuntu.com answers on 443, checked 2026-11-14), which keeps what is
# fetched private and stops an on-path party from withholding or replaying old (still validly signed) indexes. HTTPS
# needs ca-certificates in the image: when it is absent the script tries to install it from the image's own sources, and
# if it is still not there the mirror stays plain HTTP. Acquire::Check-Valid-Until is set explicitly (apt's default for
# signed repositories) so an expired, replayed index is refused.
#
# arm64 gets no mirror switch: its sources point at ports.ubuntu.com, which Azure does not mirror, and the sed below
# does not match that host, so the fallback there is only a retry of the image's own sources.
#
# Environment (tests): APT_INSTALL_ARCH overrides `dpkg --print-architecture`; APT_INSTALL_SLEEP=0 skips the waits;
# APT_INSTALL_SOURCES lists the sources files to rewrite (default: the image's), APT_INSTALL_CA_FILE the certificate bundle to look for.
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: $0 PACKAGE..." >&2; exit 2; }
export DEBIAN_FRONTEND=noninteractive
arch=${APT_INSTALL_ARCH:-$(dpkg --print-architecture)}
nap=${APT_INSTALL_SLEEP:-1}
ca_file=${APT_INSTALL_CA_FILE:-/etc/ssl/certs/ca-certificates.crt}
mirror_host=azure.archive.ubuntu.com
opts=(-o Acquire::Retries=3 -o Acquire::Check-Valid-Until=true)

attempt() {
  apt-get "${opts[@]}" -o APT::Update::Error-Mode=any update -q >/dev/null &&
    apt-get "${opts[@]}" install -y -q "$@" >/dev/null
}

# The scheme for the mirror: https when ca-certificates is present (or installable from the image's sources), else http.
mirror_scheme() {
  if [ -e "$ca_file" ] ||
     { apt-get "${opts[@]}" -o Acquire::Retries=0 install -y -q ca-certificates >/dev/null 2>&1 &&
       [ -e "$ca_file" ]; }; then
    echo https
  else
    echo http
  fi
}

for try in 1 2 3 4; do
  attempt "$@" && exit 0
  if [ "$try" = 2 ]; then
    if [ "$arch" = amd64 ]; then
      mirror="$(mirror_scheme)://$mirror_host/ubuntu/"
      echo "apt-install: the image's archive failed twice; switching to $mirror" >&2
      if [ -n "${APT_INSTALL_SOURCES:-}" ]; then read -r -a srcs <<<"$APT_INSTALL_SOURCES"
      else srcs=(/etc/apt/sources.list.d/*.sources /etc/apt/sources.list); fi
      for f in "${srcs[@]}"; do
        # No `sed -i`: its argument differs between GNU and BSD sed, and the test runs on both.
        [ -f "$f" ] || continue
        sed -E "s#https?://(archive|security)\.ubuntu\.com/ubuntu/?#$mirror#g" "$f" > "$f.new" && cat "$f.new" > "$f"
        rm -f "$f.new"
      done
    else
      echo "apt-install: the image's archive failed twice; no mirror for $arch (ports.ubuntu.com has none), retrying as is" >&2
    fi
  fi
  [ "$try" = 4 ] || { echo "apt-install: attempt $try failed; retrying in $((try * 10)) s" >&2; sleep $((try * 10 * nap)); }
done
echo "apt-install: could not install $* after 4 attempts" >&2
exit 1
