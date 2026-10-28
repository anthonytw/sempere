#!/usr/bin/env bash
# Takes the Notability importer's package product out of the app's Xcode project and the release check's
# table (docs/import-notability.md "Structure", step 2). Run it after deleting Sources/SempereNotability to build
# the app without the importer:
#
#   rm -rf Sources/SempereNotability Tests/SempereNotabilityTests
#   scripts/remove-notability-from-xcode.sh
#   scripts/app.sh test          # on a Mac
#
# Idempotent. `AppImporters.registry` is then empty: the Import entry disappears, nothing else changes.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import re
p = "Apps/Sempere/Sempere.xcodeproj/project.pbxproj"
s = open(p).read()
before = s
# The build file, its row in the Frameworks phase, the target's product list and the dependency object.
s = re.sub(r"^\t\tA1000000000000000000B009 /\* SempereNotability in Frameworks \*/ = \{[^\n]*\};\n", "", s, flags=re.M)
s = re.sub(r"^\t+A1000000000000000000B009 /\* SempereNotability in Frameworks \*/,\n", "", s, flags=re.M)
s = re.sub(r"^\t+A1000000000000000000D007 /\* SempereNotability \*/,\n", "", s, flags=re.M)
s = re.sub(r"^\t\tA1000000000000000000D007 /\* SempereNotability \*/ = \{\n[^}]*\};\n", "", s, flags=re.M)
if "SempereNotability" in s:
    raise SystemExit("error: a SempereNotability reference is left in the Xcode project")
open(p, "w").write(s)
print("Xcode project:", "unchanged" if s == before else "SempereNotability removed")

p = "scripts/release-check.sh"
s = open(p).read()
t = re.sub(r'^    "SempereNotability": \[[^\n]*\],\n', "", s, flags=re.M)
open(p, "w").write(t)
print("release-check:", "unchanged" if s == t else "SempereNotability row removed")
PY
