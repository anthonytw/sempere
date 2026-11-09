#!/usr/bin/env bash
# Compile the package targets the Apple Watch app links for watchOS (docs/design/1.1-watch.md §5): `Age`, `Sempere` and
# `SempereCapture`, with the device SDK, unsigned, so a watchOS build failure in `Sources/` (CZlib, file APIs,
# CryptoKit availability) shows here and not when the watch app lands. Runs nothing. Needs Xcode with the watchOS SDK
# (`xcodebuild -showsdks` lists it); macOS only. Not part of the PR gate unless the CI image has the SDK
# (docs/ci.md "watchOS compile").
#
#   scripts/build-watchos-package.sh              # all three
#   scripts/build-watchos-package.sh SempereCapture   # one (its dependencies build too)
#
# Run Xcode work through the build lock your environment provides (xc-lock) when other jobs share the Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/run-tmp.sh
derived=${SEMPERE_DERIVED_DATA:-.build/xcode-watchos.noindex}

if ! xcodebuild -showsdks 2>/dev/null | grep -q -- '-sdk watchos'; then
  echo "build-watchos-package: this Xcode has no watchOS SDK (xcodebuild -showsdks); install it with Xcode > Settings > Components" >&2
  exit 2
fi

targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || targets=(Age Sempere SempereCapture)
for t in "${targets[@]}"; do
  echo "== $t for watchOS"
  # A SwiftPM package's targets are schemes of the package folder; the generic destination needs no runtime or signing.
  xcodebuild -scheme "$t" -destination 'generic/platform=watchOS' -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build 2>&1 | { if [[ -n ${VERBOSE:-} ]]; then cat; else grep -E "error:|warning: .*(watchOS|unavailable)|BUILD (SUCCEEDED|FAILED)" || true; fi; }
  [[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "build-watchos-package: $t failed for watchOS" >&2; exit 1; }
done
echo "build-watchos-package: ok (${targets[*]})"
