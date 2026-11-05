#!/usr/bin/env bash
# Build the fully static Linux `sempere` with Swift's Static Linux SDK (musl): no glibc, libcurl or
# libxml2 needed at run time, so one binary runs on any Linux distribution of its architecture.
#
#   scripts/build-linux-static.sh ARCH [OUT]     ARCH: x86_64 or aarch64; prints the binary's path
#                                                (copied to OUT if given)
#
# Runs in the `swift:$SWIFT_VERSION-noble` image (release.yml, ci.yml `linux-static`): the SDK must
# be exactly the compiler's version, so both pins live here. Bump them together: the checksum is the
# "Static SDK" entry for that release in https://www.swift.org/api/v1/install/releases.json.
# The binary is stripped (-Xlinker -s): about 80 MB instead of 240 MB.
set -euo pipefail

SWIFT_VERSION=6.4.2
SDK_SHA256=3786b179936d9cc9e266dd506bd1654176358d7b25288e243359f4d17cc4dc5a
SDK_URL="https://download.swift.org/swift-$SWIFT_VERSION-release/static-sdk/swift-$SWIFT_VERSION-RELEASE/swift-$SWIFT_VERSION-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"

arch=${1:?usage: $0 x86_64|aarch64 [OUT]}
out=${2:-}
case $arch in x86_64|aarch64) ;; *) echo "unknown arch '$arch'" >&2; exit 2 ;; esac
cd "$(dirname "$0")/.."

have=$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -1)
if [[ $have != "$SWIFT_VERSION" ]]; then
  echo "error: the compiler is Swift $have; the pinned Static Linux SDK needs exactly $SWIFT_VERSION (use swift:$SWIFT_VERSION-noble)" >&2
  exit 1
fi
if ! swift sdk list 2>/dev/null | grep -qx "swift-$SWIFT_VERSION-RELEASE_static-linux-0.1.0"; then
  swift sdk install "$SDK_URL" --checksum "$SDK_SHA256" >&2
fi

flags=(-c release --product sempere --swift-sdk "$arch-swift-linux-musl" -Xlinker -s)
swift build "${flags[@]}" >&2
bin="$(swift build "${flags[@]}" --show-bin-path)/sempere"

# Static means no dynamic section at all: no interpreter, nothing NEEDED.
if readelf -d "$bin" 2>/dev/null | grep -q 'NEEDED'; then
  echo "error: $bin links shared libraries:" >&2; readelf -d "$bin" | grep NEEDED >&2; exit 1
fi
if readelf -l "$bin" | grep -q 'INTERP'; then echo "error: $bin has a program interpreter (not static)" >&2; exit 1; fi

if [[ -n $out ]]; then mkdir -p "$(dirname "$out")"; cp "$bin" "$out"; bin=$out; fi
echo "$bin"
