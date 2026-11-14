#!/usr/bin/env bash
# The Mac package tests (the PR gate's `package` step): build everything, then run `swift test --parallel` on the test
# targets whose hash has not already passed (scripts/ci-hash.py, docs/design/ci-lean.md). Run by scripts/local-ci.sh and
# by the `Mac package tests` job of .github/workflows/ci.yml.
#
#   scripts/ci-mac-package.sh
#
# SEMPERE_CI_PASS_DIR names the folder of pass records (default ~/.cache/sempere-ci-pass); SEMPERE_CI_FORCE_ALL=1 runs every
# target; SEMPERE_CI_MAC_PACKAGE=os-dependent leaves the logic targets to the Linux job (scripts/ci-targets.json).
# The log names each skip's hash and the commit that passed it.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/swiftpm-quarantine.sh   # swiftpm_skips: the quarantined tests, which run alone (docs/ci.md "Quarantine")
export SEMPERE_CI_PASS_DIR=${SEMPERE_CI_PASS_DIR:-$HOME/.cache/sempere-ci-pass}
mkdir -p build
plan=build/ci-mac-package.plan
split=() skips=()
[[ ${SEMPERE_CI_MAC_PACKAGE:-all} == os-dependent ]] && split=(--os-dependent-only)
/usr/bin/python3 -I scripts/ci-hash.py plan --job mac-package --out "$plan" ${split[@]+"${split[@]}"}
while read -r t; do skips+=(--skip "^$t\\."); done < <(/usr/bin/python3 -I scripts/ci-hash.py skips "$plan")
# The build always runs (incremental, cheap when warm): the benchmark targets are never tested but must still compile.
swift build --build-tests
if [[ $(/usr/bin/python3 -I scripts/ci-hash.py runs "$plan" | wc -l) -eq 0 ]]; then
  echo "package: every test target skipped (each passed with its current hash, or is left to Linux)"
  exit 0
fi
/usr/bin/python3 -I scripts/test-runner.py --kind swiftpm -- swift test --parallel --skip 'Benchmarks\.' ${swiftpm_skips[@]+"${swiftpm_skips[@]}"} ${skips[@]+"${skips[@]}"}
/usr/bin/python3 -I scripts/ci-hash.py record --plan "$plan"
