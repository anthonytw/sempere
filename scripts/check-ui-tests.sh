#!/usr/bin/env bash
# Every XCTestCase class in Apps/Sempere/SempereAppUITests is in one of scripts/app.sh's UI lists (ui_mac, ui_mac_smoke,
# ui_ipad, ui_phone, ui_pseudo, ui_tooling), and every name in those lists is such a class (or Class/test of one): a new
# UI test class cannot silently never run, and a renamed or deleted one cannot linger in a list (`KeyShareMacUITests`
# did). Run by local-ci.sh's `help` step.
set -euo pipefail
cd "$(dirname "$0")/.."

dir=Apps/Sempere/SempereAppUITests
classes=$(grep -hoE '^(final )?class [A-Za-z0-9_]+: XCTestCase' "$dir"/*.swift | sed -E 's/^(final )?class ([A-Za-z0-9_]+):.*/\2/' | sort -u)
[[ -n $classes ]] || { echo "check-ui-tests: no UI test classes found in $dir" >&2; exit 1; }

# The lists, as app.sh defines them (between its ui-lists markers).
eval "$(sed -n '/^# ui-lists:begin/,/^# ui-lists:end/p' scripts/app.sh)"
listed=$(printf '%s\n' "${ui_mac[@]}" "${ui_mac_smoke[@]}" "${ui_ipad[@]}" "${ui_phone[@]}" "${ui_pseudo[@]}" "${ui_tooling[@]}" \
  | sed -E 's|/.*||' | sort -u)

status=0
for c in $classes; do
  grep -qx "$c" <<<"$listed" || { echo "check-ui-tests: $c is in no UI list of scripts/app.sh (it would never run)" >&2; status=1; }
done
for c in $listed; do
  grep -qx "$c" <<<"$classes" || { echo "check-ui-tests: scripts/app.sh lists $c, which is no class in $dir" >&2; status=1; }
done
exit $status
