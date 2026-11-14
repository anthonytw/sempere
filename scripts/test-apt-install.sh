#!/usr/bin/env bash
# Tests for scripts/apt-install.sh (docs/design/1.2-audit-followups.md F-14): with a fake `apt-get` that fails a set number
# of `update` calls, check the mirror the sources are rewritten to per architecture (amd64: Azure over HTTPS, or HTTP
# without ca-certificates; arm64: none) and that the exit status follows apt-get's. Runs on Linux and macOS (bash, sed).
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
script="$here/scripts/apt-install.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
pass=0 fail=0

# A fake apt-get: `update` fails while the counter is below $FAKE_FAILS; `install ca-certificates` creates $FAKE_CA when
# $FAKE_CA_INSTALLABLE is 1; any other install succeeds.
cat > "$tmp/bin/apt-get" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_LOG"
case " $* " in
  *" install -y -q ca-certificates"*)
    [ "${FAKE_CA_INSTALLABLE:-0}" = 1 ] || exit 100
    : > "$FAKE_CA"; exit 0 ;;
  *" update "*)
    n=$(cat "$FAKE_COUNT" 2>/dev/null || echo 0); echo $((n + 1)) > "$FAKE_COUNT"
    [ "$n" -lt "$FAKE_FAILS" ] || exit 0
    exit 100 ;;
esac
exit "${FAKE_INSTALL_STATUS:-0}"
EOF
printf '#!/bin/sh\necho "${FAKE_DPKG_ARCH:-amd64}"\n' > "$tmp/bin/dpkg"
chmod +x "$tmp/bin/apt-get" "$tmp/bin/dpkg"

orig='URIs: http://archive.ubuntu.com/ubuntu/ http://security.ubuntu.com/ubuntu'

# run NAME ARCH FAILS CA(have|installable|none) WANT_STATUS WANT_SOURCES_PATTERN|unchanged [extra env...]
run() {
  local name="$1" arch="$2" fails="$3" ca="$4" want="$5" pat="$6" code=0
  shift 6
  rm -f "$tmp/count" "$tmp/log" "$tmp/ca"
  printf '%s\n' "$orig" > "$tmp/ubuntu.sources"
  [ "$ca" = have ] && : > "$tmp/ca"
  env "$@" PATH="$tmp/bin:$PATH" APT_INSTALL_ARCH="$arch" APT_INSTALL_SLEEP=0 APT_INSTALL_SOURCES="$tmp/ubuntu.sources" \
    APT_INSTALL_CA_FILE="$tmp/ca" FAKE_FAILS="$fails" FAKE_COUNT="$tmp/count" FAKE_LOG="$tmp/log" FAKE_CA="$tmp/ca" \
    FAKE_CA_INSTALLABLE="$([ "$ca" = installable ] && echo 1 || echo 0)" \
    "$script" somepkg >"$tmp/out" 2>&1 || code=$?
  local ok=1 got; got="$(cat "$tmp/ubuntu.sources")"
  [ "$code" -eq "$want" ] || ok=0
  if [ "$pat" = unchanged ]; then [ "$got" = "$orig" ] || ok=0
  else grep -qE -- "$pat" <<<"$got" || ok=0; fi
  if [ "$ok" -eq 1 ]; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name (exit $code, want $want; sources: $got)"; sed 's/^/     /' "$tmp/out"; fi
}

run "the image's own archive working: no rewrite, exit 0" amd64 0 have 0 unchanged
run "one failed update is retried against the same sources" amd64 1 have 0 unchanged
run "amd64, two failures: Azure over HTTPS" amd64 2 have 0 '^URIs: https://azure\.archive\.ubuntu\.com/ubuntu/ https://azure\.archive\.ubuntu\.com/ubuntu/$'
run "amd64 without ca-certificates but installable: HTTPS" amd64 2 installable 0 'https://azure\.archive\.ubuntu\.com/ubuntu/'
run "amd64 without ca-certificates, not installable: plain HTTP" amd64 2 none 0 '^URIs: http://azure\.archive\.ubuntu\.com/ubuntu/ http://azure'
run "arm64, two failures: no mirror switch" arm64 2 have 0 unchanged
run "arm64, ports sources are not touched either" arm64 3 have 0 unchanged
run "amd64, apt always failing: exit 1" amd64 99 have 1 'https://azure'
run "arm64, apt always failing: exit 1, sources unchanged" arm64 99 have 1 unchanged
run "an install that keeps failing: exit 1, after the mirror switch" amd64 0 have 1 "https://azure" FAKE_INSTALL_STATUS=100

# The explicit Check-Valid-Until option goes to every apt-get call.
rm -f "$tmp/count" "$tmp/log"
env PATH="$tmp/bin:$PATH" APT_INSTALL_ARCH=amd64 APT_INSTALL_SLEEP=0 FAKE_FAILS=0 FAKE_COUNT="$tmp/count" FAKE_LOG="$tmp/log" "$script" somepkg >/dev/null 2>&1
if [ "$(grep -vc 'Acquire::Check-Valid-Until=true' "$tmp/log")" -eq 0 ]; then pass=$((pass + 1)); echo "ok   every apt-get call sets Check-Valid-Until=true"
else fail=$((fail + 1)); echo "FAIL Check-Valid-Until missing"; cat "$tmp/log"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
