#!/usr/bin/env bash
# The quarantine of the SwiftPM tests (docs/ci.md "Quarantine"): a known flaky test leaves every normal run and runs only on its own.
# One list, `swiftpm_quarantine`, entries `Class/testName`. Sourced by scripts/ci-mac-package.sh, scripts/ci-linux.sh (job_test)
# and scripts/test-linux.sh, which skip every entry (`swiftpm_skips`: `--skip` arguments for `swift test`); run directly (or as
# `scripts/ci-linux.sh docker quarantine`) it runs the entries alone, after a build, and fails if one fails. Not a gate.
#
#   scripts/swiftpm-quarantine.sh
# Empty now (the one entry, ConcurrentTransferTests/testCancelledMidwayWithSeveralInFlightResumes, was deleted after review: its
# behavior is covered by testReviewProgressMonotoneWhenResumeGets200, BlobResumeTests and testACutDownloadAmongConcurrentOnesResumes).
# The machinery stays for the next one. Every expansion of an array here uses ${a[@]+"${a[@]}"}: macOS bash 3.2 with `set -u`
# fails on a bare "${a[@]}" of an empty array.
swiftpm_quarantine=()
swiftpm_skips=()
for _q in ${swiftpm_quarantine[@]+"${swiftpm_quarantine[@]}"}; do swiftpm_skips+=(--skip "$_q"); done
unset _q

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  cd "$(dirname "$0")/.."
  if [[ ${#swiftpm_quarantine[@]} -eq 0 ]]; then echo "swiftpm-quarantine: no quarantined SwiftPM tests"; exit 0; fi
  swift build --build-tests
  status=0
  for q in ${swiftpm_quarantine[@]+"${swiftpm_quarantine[@]}"}; do
    swift test --skip-build --filter "$q" || status=$?
  done
  exit $status
fi
