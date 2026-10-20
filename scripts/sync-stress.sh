#!/usr/bin/env bash
# The heavy WebDAV sync stress run (docs/ci.md "Sync stress"); not part of CI or the PR gate.
#   scripts/sync-stress.sh [swift test options]
# Builds (once per seed and size, kept in build/sync-stress/) a seeded synthetic vault with the CLI
# (scripts/make-stress-vault.sh), then runs, against wsgidav behind scripts/dav-fault-proxy.py
# (both started by scripts/test-webdav.sh, which also checks that nothing skipped):
#   SyncStressTests       the vault between two devices: upload and pull through resets and 5xx,
#                         concurrent edits, idle request counts, canceled pulls, merge-copy round trip
#   SyncTimingTests       wall time, requests and connections of a first upload, a first pull, idle runs and
#                         a push, without faults, at SEMPERE_STRESS_LATENCIES ms per request (0,20)
#   SyncFaultProxyTests   the fast proxy scenarios (also in the CI webdav job)
#   TwoDeviceStressTests  the in-memory random interleavings, with SEMPERE_STRESS_SEEDS seeds
#   NDeviceStressTests    3 to 5 devices on one or two remotes (MemoryRemote, the WebDAV mock) through
#                         transport and hostile-server faults, several bridges (SEMPERE_SYNC_STRESS_BRIDGES=one:
#                         one remote each), SEMPERE_SYNC_STRESS_SEEDS seeds (long mode)
#   WsgidavConformanceTests, EngineOverWsgidavTests   the transport suites over wsgidav
# Environment: SEMPERE_STRESS_SEED (1), SEMPERE_STRESS_NOTES (640), SEMPERE_STRESS_SEEDS (60),
# SEMPERE_SYNC_STRESS_SEEDS (60).
# Needs wsgidav (scripts/webdav-server-requirements.txt) and python3. About five minutes on a laptop.
set -euo pipefail
cd "$(dirname "$0")/.."
seed="${SEMPERE_STRESS_SEED:-1}"
notes="${SEMPERE_STRESS_NOTES:-640}"
swift build --build-tests >/dev/null
out="build/sync-stress/seed-$seed-$notes"
SEMPERE_BIN="$(swift build --show-bin-path)/sempere" scripts/make-stress-vault.sh "$out" "$seed" "$notes"
export SEMPERE_STRESS_VAULT="$PWD/$out"
export SEMPERE_STRESS_SEEDS="${SEMPERE_STRESS_SEEDS:-60}"
export SEMPERE_SYNC_STRESS_LONG=1
export SEMPERE_SYNC_STRESS_SEEDS="${SEMPERE_SYNC_STRESS_SEEDS:-60}"
export SEMPERE_WEBDAV_TESTS='SyncStressTests|SyncTimingTests|SyncFaultProxyTests|TwoDeviceStressTests|NDeviceStressTests|WsgidavConformanceTests|EngineOverWsgidavTests'
exec scripts/test-webdav.sh --skip-build "$@"
