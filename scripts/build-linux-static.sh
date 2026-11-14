#!/usr/bin/env bash
# Build the fully static Linux `sempere` with Swift's Static Linux SDK (musl): no glibc, libcurl or
# libxml2 needed at run time, so one binary runs on any Linux distribution of its architecture.
#
#   scripts/build-linux-static.sh ARCH [OUT]     ARCH: x86_64 or aarch64; prints the binary's path
#                                                (copied to OUT if given)
#
# Runs in the `swift:$SWIFT_VERSION-noble` image (scripts/ci-linux.sh static, scripts/release-build.sh): the SDK must
# be exactly the compiler's version, so the pins (scripts/static-sdk-pin.sh) go with STATIC_IMAGE in ci-linux.sh. With
# SEMPERE_SDK_ARCHIVE=FILE (set by `ci-linux.sh docker`, which mounts the host's cached archive,
# scripts/static-sdk-cache.sh) the SDK is installed from that file after its SHA-256 is checked here; without it, it is
# downloaded with `--checksum`.
# The binary is stripped (-Xlinker -s): about 80 MB instead of 240 MB.
set -euo pipefail

source "$(dirname "$0")/static-sdk-pin.sh"   # SWIFT_VERSION, SDK_URL, SDK_SHA256, sha256_of

arch=${1:?usage: $0 x86_64|aarch64 [OUT]}
out=${2:-}
case $arch in x86_64|aarch64) ;; *) echo "unknown arch '$arch'" >&2; exit 2 ;; esac
cd "$(dirname "$0")/.."

have=$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -1)
if [[ $have != "$SWIFT_VERSION" ]]; then
  echo "error: the compiler is Swift $have; the pinned Static Linux SDK needs exactly $SWIFT_VERSION (use swift:$SWIFT_VERSION-noble)" >&2
  exit 1
fi
# An SDK already installed is never trusted (its files are writable, and a checksum is only checked on install):
# it is removed and installed again from the checksummed archive, so the SDK of every build is the pinned one.
name="swift-$SWIFT_VERSION-RELEASE_static-linux-0.1.0"
if swift sdk list 2>/dev/null | grep -qx "$name"; then swift sdk remove "$name" >&2; fi
if [[ -n ${SEMPERE_SDK_ARCHIVE:-} ]]; then
  # The host's cache of the archive (scripts/static-sdk-cache.sh, mounted read-only): copied here, checked against the pin HERE
  # (never trusted because the host checked it), and installed from that copy, so the file that was checked is the file that is
  # installed. A file that does not match is an error, not a fallback to the network.
  [[ -f $SEMPERE_SDK_ARCHIVE ]] || { echo "error: SEMPERE_SDK_ARCHIVE=$SEMPERE_SDK_ARCHIVE is not a file" >&2; exit 1; }
  sdk_tmp=$(mktemp -d); trap 'rm -rf "$sdk_tmp"' EXIT
  sdk_file=$sdk_tmp/${SDK_URL##*/}
  cp "$SEMPERE_SDK_ARCHIVE" "$sdk_file"
  got=$(sha256_of "$sdk_file")
  [[ $got == "$SDK_SHA256" ]] || { echo "error: the cached SDK archive has SHA-256 $got, expected $SDK_SHA256" >&2; exit 1; }
  swift sdk install "$sdk_file" >&2
else
  swift sdk install "$SDK_URL" --checksum "$SDK_SHA256" >&2
fi
swift sdk list 2>/dev/null | grep -qx "$name" || { echo "error: the Static Linux SDK $name is not installed" >&2; exit 1; }

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
