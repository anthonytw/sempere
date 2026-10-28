#!/usr/bin/env bash
# The package tests with no network but loopback (offline audit, docs/ci.md "Offline guard"): nothing in Sempere may
# need the network except the WebDAV client, and its tests use servers on this machine (the in-process mock, wsgidav
# on localhost). A test that reaches anything else fails here.
#   scripts/test-offline.sh [swift test options]      e.g. --skip-build --parallel
# Linux: a network namespace of its own with only `lo` up (`unshare -n` as root, as in CI's container with
# CAP_SYS_ADMIN and CAP_NET_ADMIN; else `unshare -rn`, an unprivileged user namespace). Needs iproute2 (`ip`).
# macOS: `sandbox-exec` refusing every outbound connection and bind except to localhost (name lookups stay allowed:
# refusing the resolver's socket breaks URLSession even to 127.0.0.1); SwiftPM's own sandbox cannot nest inside it,
# so `--disable-sandbox` is passed.
set -euo pipefail
cd "$(dirname "$0")/.."

case "$(uname -s)" in
Linux)
    # Once `lo` is up, the tests run without any capability (setpriv, util-linux): code under test can neither rely
    # on root's powers nor step back out of the namespace (review of #90, N4).
    # Without setpriv the tests would keep every capability: refused in CI, a loud warning elsewhere.
    if ! command -v setpriv >/dev/null; then
        if [ -n "${CI:-}" ]; then
            echo "error: setpriv (util-linux) is missing: the tests would run with every capability" >&2
            exit 2
        fi
        echo "WARNING: setpriv (util-linux) is missing: the tests run with every capability of this shell" >&2
    fi
    inner='ip link set lo up && if command -v setpriv >/dev/null; then exec setpriv --inh-caps=-all --ambient-caps=-all --bounding-set=-all swift test "$@"; else exec swift test "$@"; fi'
    if [ "$(id -u)" = 0 ] && unshare -n true 2>/dev/null; then
        exec unshare -n sh -c "$inner" sh "$@"
    elif unshare -rn true 2>/dev/null; then
        exec unshare -rn sh -c "$inner" sh "$@"
    else
        echo "error: cannot make a network namespace here (unshare -n / -rn refused): run as root with CAP_SYS_ADMIN" \
            "and CAP_NET_ADMIN, or allow unprivileged user namespaces" >&2
        exit 2
    fi
    ;;
Darwin)
    profile="$(mktemp -t sempere-offline.XXXXXX)"
    trap 'rm -f "$profile"' EXIT
    cat > "$profile" <<'EOF'
(version 1)
(allow default)
(deny network-outbound (remote ip "*:*"))
(allow network-outbound (remote ip "localhost:*"))
(deny network-bind (local ip "*:*"))
(allow network-bind (local ip "localhost:*"))
EOF
    # The sandbox must really refuse: a guard that lets everything through would pass silently. A numeric address
    # (no name lookup): refused by the sandbox is "Operation not permitted"; any other failure (no network here at
    # all) proves nothing, and says so.
    probe=$(sandbox-exec -f "$profile" /usr/bin/curl -v -m 5 -o /dev/null https://1.1.1.1 2>&1) && {
        echo "error: the sandbox let a connection out" >&2
        exit 2
    }
    case "$probe" in
    *"not permitted"*) ;;
    *) echo "warning: could not show the sandbox refuses connections (no network here?)" >&2 ;;
    esac
    sandbox-exec -f "$profile" swift test --disable-sandbox "$@"
    ;;
*)
    echo "error: unsupported system $(uname -s)" >&2
    exit 2
    ;;
esac
