#!/usr/bin/env bash
# Setup script for a Claude Code cloud environment (Ubuntu 24.04, runs as root).
# Paste into the environment's "Setup script" box. Installs a Swift toolchain so
# `swift build` / `swift test` work natively. Needs download.swift.org on the
# environment's network allowlist.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q zlib1g-dev age binutils gnupg2 libc6-dev libcurl4-openssl-dev \
  libedit2 libgcc-13-dev libncurses-dev libsqlite3-0 libstdc++-13-dev libxml2-dev \
  libz3-dev pkg-config tzdata unzip python3-lldb-18 || true

# swift.org names releases with the patch number (6.4.0, not 6.4); a short
# version 404s. Check https://www.swift.org/api/v1/install/releases.json.
SWIFT_VER="${SWIFT_VER:-6.4.0}"
if ! command -v swift >/dev/null; then
  URL="https://download.swift.org/swift-${SWIFT_VER}-release/ubuntu2404/swift-${SWIFT_VER}-RELEASE/swift-${SWIFT_VER}-RELEASE-ubuntu24.04.tar.gz"
  # Fail loudly: the cloud VM has no Docker daemon, so there is no fallback.
  curl -fsSL "$URL" -o /tmp/swift.tgz
  mkdir -p /opt/swift && tar -xzf /tmp/swift.tgz -C /opt/swift --strip-components=1
  rm -f /tmp/swift.tgz
  # Agent shells are non-login, so /etc/profile.d alone is not enough: link the
  # tools into /usr/local/bin, which is on every PATH.
  for t in /opt/swift/usr/bin/*; do ln -sf "$t" /usr/local/bin/; done
  echo 'export PATH=/opt/swift/usr/bin:$PATH' > /etc/profile.d/swift.sh
fi
swift --version
if [ -f Package.swift ]; then
  swift package resolve || true
fi
