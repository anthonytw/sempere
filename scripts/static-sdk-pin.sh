# The Static Linux SDK pin, sourced by scripts/build-linux-static.sh (in the container) and scripts/static-sdk-cache.sh (on the
# host): one place for the Swift version, the archive's URL and its SHA-256. The SDK must be exactly the compiler's version; bump
# the version here together with STATIC_IMAGE in scripts/ci-linux.sh. The checksum is the "Static SDK" entry for that release in
# https://www.swift.org/api/v1/install/releases.json.
SWIFT_VERSION=6.4.2
SDK_SHA256=3786b179936d9cc9e266dd506bd1654176358d7b25288e243359f4d17cc4dc5a
SDK_URL="https://download.swift.org/swift-$SWIFT_VERSION-release/static-sdk/swift-$SWIFT_VERSION-RELEASE/swift-$SWIFT_VERSION-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"

sha256_of() {   # file -> hex digest (macOS has shasum, the Linux images sha256sum)
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
