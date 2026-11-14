#!/usr/bin/env bash
# The quarantine of the SwiftPM tests (docs/ci.md "Quarantine"): a known flaky test leaves every normal run and runs only on its own.
# One list, `swiftpm_quarantine`, entries `Class/testName`. Sourced by scripts/ci-mac-package.sh, scripts/ci-linux.sh (job_test)
# and scripts/test-linux.sh, which skip every entry (`swiftpm_skips`: `--skip` arguments for `swift test`); run directly (or as
# `scripts/ci-linux.sh docker quarantine`) it runs the entries alone, after a build, and fails if one fails. Not a gate.
#
#   scripts/swiftpm-quarantine.sh
swiftpm_quarantine=(
  # ConcurrentTransferTests (SempereWebDAVTests, in the `test` jobs: MockDAV, no wsgidav): timing; the cancel can land before the
  # blobs reach their second segment on a loaded runner. Keep-or-delete decision pending.
  ConcurrentTransferTests/testCancelledMidwayWithSeveralInFlightResumes
)
swiftpm_skips=()
for _q in "${swiftpm_quarantine[@]}"; do swiftpm_skips+=(--skip "$_q"); done
unset _q

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  cd "$(dirname "$0")/.."
  swift build --build-tests
  status=0
  for q in "${swiftpm_quarantine[@]}"; do
    swift test --skip-build --filter "$q" || status=$?
  done
  exit $status
fi
