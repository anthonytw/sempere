#!/usr/bin/env bash
# Runs the WebDAV integration tests against a local wsgidav server.
#   pip install wsgidav cheroot      (once)
#   scripts/test-webdav.sh
# They only run when SEMPERE_WEBDAV_TEST_URL is set; this script sets it, and CI's `webdav` job
# runs this script (a plain `swift test` skips them). It fails if any selected test was skipped.
#   SEMPERE_WEBDAV_LARGE_MB=N   size of the large-blob test (default 300; CI uses 64)
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-8765}"
work="$(mktemp -d)"
trap 'kill "${server_pid:-0}" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/root"
cat > "$work/wsgidav.yaml" <<YAML
host: 127.0.0.1
port: $PORT
provider_mapping:
  "/": "$work/root"
http_authenticator:
  domain_controller: null
  accept_basic: true
  accept_digest: false
  default_to_digest: false
simple_dc:
  user_mapping:
    "*":
      sempere:
        password: "test-password"
verbose: 1
YAML
wsgidav --config "$work/wsgidav.yaml" >"$work/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.2
done
export SEMPERE_WEBDAV_TEST_URL="http://127.0.0.1:$PORT/"
export SEMPERE_WEBDAV_TEST_USER=sempere
export SEMPERE_WEBDAV_TEST_PASSWORD=test-password
log="$work/test.log"
status=0
swift test --filter 'WebDAVIntegrationTests|BlobIntegrationTests|CLIWebDAVTests' "$@" 2>&1 | tee "$log" || status=${PIPESTATUS[0]}
[ "$status" -eq 0 ] || exit "$status"
# XCTest prints "Executed N tests, with M tests skipped and 0 failures" when a test skipped.
if grep -Eq "Executed [0-9]+ tests?, with [0-9]+ tests? skipped" "$log"; then
  echo "error: a WebDAV integration test was skipped (server or credentials not picked up)" >&2
  exit 1
fi
grep -Eq "Executed [1-9][0-9]* tests?" "$log" || { echo "error: no WebDAV integration test ran" >&2; exit 1; }
