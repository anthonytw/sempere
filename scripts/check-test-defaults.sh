#!/usr/bin/env bash
# Fails when an app test makes a UserDefaults suite without TestDefaults.
#
# `UserDefaults(suiteName:)` leaves `<suite>.plist` in the app container's Library/Preferences for ever; 21,000 of
# them once piled up. Tests call `TestDefaults.suite(name)` (Apps/Sempere/SempereAppTests/TestDefaults.swift), which
# removes the domain and the file at process exit. docs/ci.md "Temp-folder guard".
set -euo pipefail
cd "$(dirname "$0")/.."
bad=$(grep -rnE '(UserDefaults|\.init)\(suiteName:' Apps/Sempere/SempereAppTests Apps/Sempere/SempereAppUITests \
  --include='*.swift' 2>/dev/null | grep -v '/TestDefaults\.swift:' || true)
if [[ -n $bad ]]; then
  echo "check-test-defaults: use TestDefaults.suite(_:) instead of UserDefaults(suiteName:) in tests:" >&2
  echo "$bad" >&2
  exit 1
fi
echo "check-test-defaults: ok"
