#!/usr/bin/env bash
# Fail if library/CLI sources import Apple-only frameworks (see CLAUDE.md).
set -euo pipefail
cd "$(dirname "$0")/.."
pattern='^[[:space:]]*import[[:space:]]+(UIKit|AppKit|PencilKit|CoreGraphics|Compression|CommonCrypto|Security|CryptoKit|SwiftUI|Combine|os|OSLog)\b'
if grep -rEn "$pattern" Sources/ --exclude-dir=SempereCloudKit; then
  echo "error: Apple-only import in Sources/ (use 'import Crypto' from swift-crypto, CZlib for gzip)" >&2
  exit 1
fi
# The CloudKit adapter (docs/design/1.4-cloudkit.md §6.3) is Apple-only by design, one file whose body is `#if canImport(CloudKit)`
# (Linux builds an empty module): CloudKit itself, Security for the entitlement check on macOS (a process without the entitlement
# must not create a container), and the packages' own modules. Nothing else Apple-only.
if grep -rEn '^[[:space:]]*(@\w+[[:space:]]+)*import[[:space:]]+' Sources/SempereCloudKit | grep -vE 'import[[:space:]]+(CloudKit|Security|Foundation|Crypto|Sempere|SempereSync)\b'; then
  echo "error: Sources/SempereCloudKit imports something besides CloudKit, Security, Foundation, Crypto, Sempere and SempereSync" >&2
  exit 1
fi
if grep -rLE '^#if canImport\(CloudKit\)' Sources/SempereCloudKit | grep .; then
  echo "error: a file of Sources/SempereCloudKit is not wrapped in #if canImport(CloudKit): Linux builds it too" >&2
  exit 1
fi
# Network code lives in Sources/SempereWebDAV only (CLAUDE.md).
netpattern='(URLSession|FoundationNetworking|NWConnection|CFNetwork|import[[:space:]]+Network\b)'
if grep -rEn "$netpattern" Sources/ --exclude-dir=SempereWebDAV; then
  echo "error: network code outside Sources/SempereWebDAV" >&2
  exit 1
fi
# Note insights (docs/design/1.2-note-insights.md §4, §8): Apple's on-device model and language framework only in
# Sources/SempereInsightsApple (behind #if canImport); the pipeline, SempereInsights, stays Foundation only.
if grep -rEn '^[[:space:]]*import[[:space:]]+(FoundationModels|NaturalLanguage)\b' Sources/ --exclude-dir=SempereInsightsApple; then
  echo "error: FoundationModels or NaturalLanguage outside Sources/SempereInsightsApple" >&2
  exit 1
fi
if grep -rEn '^[[:space:]]*import[[:space:]]+[A-Z]' Sources/SempereInsights | grep -vE 'import[[:space:]]+(Foundation|Sempere)\b'; then
  echo "error: Sources/SempereInsights imports something besides Foundation and Sempere" >&2
  exit 1
fi
# A folder target's provider record (CLAUDE.md "Hard rules"): UniformTypeIdentifiers in UbiquitousFolderHooks.swift only.
if grep -rEn '^[[:space:]]*import[[:space:]]+UniformTypeIdentifiers\b' Sources/ | grep -v '^Sources/SempereSync/UbiquitousFolderHooks.swift:'; then
  echo "error: UniformTypeIdentifiers outside Sources/SempereSync/UbiquitousFolderHooks.swift" >&2
  exit 1
fi
# Subprocesses (Poppler for PDF backgrounds) only in the CLI: Process does not exist on iOS.
if grep -rEn '\bProcess\(\)|: Process\b' Sources/ --exclude-dir=SempereCLI; then
  echo "error: Process outside Sources/SempereCLI" >&2
  exit 1
fi
# Unavailable on iOS and Mac Catalyst, which link Sources/ too (CLAUDE.md).
if grep -rEn 'homeDirectoryForCurrentUser' Sources/; then
  echo "error: FileManager.homeDirectoryForCurrentUser is macOS-only; use NSHomeDirectory()" >&2
  exit 1
fi
echo "portability: ok"
