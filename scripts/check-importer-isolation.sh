#!/usr/bin/env bash
# The Notability importer is a removable module (docs/import-notability.md "Structure"): outside
# Sources/SempereNotability and Tests/SempereNotabilityTests, no code may name one of its types or import
# its module, except the two registries (the CLI's and the app's), which are gated by
# `#if canImport(SempereNotability)`. Comments and help text may say "Notability"; identifiers may not.
set -euo pipefail
cd "$(dirname "$0")/.."

allowed=(
  "Sources/SempereCLI/ImportRegistry.swift"
  "Apps/Sempere/SempereApp/AppImporters.swift"
)

# Swift identifiers that begin with Notability (NotabilityNote, NotabilityImporter, NotabilityVaultImporter, ...),
# the module name, and the old per-importer symbols the hosts had.
pattern='\bNotability[A-Z][A-Za-z0-9]*\b|\bSempereNotability\b|\bImportNotability\b|\bimportNotability\b'

fail=0
while IFS= read -r file; do
  skip=0
  for a in "${allowed[@]}"; do [ "$file" = "$a" ] && skip=1; done
  [ "$skip" = 1 ] && continue
  # Only code: drop // comments, /// docs and string literals' contents are not worth parsing; a hit inside a
  # comment is still reported when the identifier is spelled out, so write "the Notability importer" in prose.
  hits="$(grep -nE "$pattern" "$file" | grep -vE '^[0-9]+:[[:space:]]*(//|\*|/\*)' || true)"
  if [ -n "$hits" ]; then
    echo "error: $file names the Notability module (only the registries may):" >&2
    echo "$hits" | sed 's/^/  /' >&2
    fail=1
  fi
done < <(git ls-files 'Sources/*.swift' 'Apps/*.swift' 'Tests/*.swift' 'Package.swift' \
  | grep -vE '^(Sources/SempereNotability/|Tests/SempereNotabilityTests/)' | grep -v '^Package.swift$')

if [ "$fail" != 0 ]; then exit 1; fi
echo "importer isolation: ok"
