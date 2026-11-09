#!/usr/bin/env bash
# Tests for scripts/check-security.sh: the real tree passes, a small clean tree passes, and each planted problem
# (a key, a log call, an unpinned action, a lockfile entry without integrity, ...) makes it fail with the expected text.
# Runs on Linux and macOS (bash, git, python3); CI runs it in "Help and portability checks".
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
check="$here/scripts/check-security.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
sha=0123456789abcdef0123456789abcdef01234567
# Planted in pieces, so that this file does not itself look like a leaked key to the scan.
key="AGE-SECRET-""KEY-PQ-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
pem="-----BEGIN OPENSSH ""PRIVATE KEY-----"
hash_of() { printf '%s' "$1" | python3 -I -c 'import sys, hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }
keyhash="$(hash_of "$key")"

# fresh: a clean one-commit-less git work tree with the files the check reads
fresh() {
  rm -rf "$tmp/root"; mkdir -p "$tmp/root/Sources/Lib" "$tmp/root/Sources/SempereCLI" "$tmp/root/Apps/App" \
    "$tmp/root/.github/workflows" "$tmp/root/.github/actions/local" "$tmp/root/web" "$tmp/root/scripts"
  cd "$tmp/root"
  cp "$here/Package.swift" "$here/Package.resolved" .
  printf '%s\n' '// ok' 'let x = 1' > Sources/Lib/Lib.swift
  printf '%s\n' 'print("hello")' > Sources/SempereCLI/main.swift
  printf '%s\n' 'import os' 'let l = Logger()' 'func f(logger: Logger, n: Int) { logger.info("\(n, privacy: .public)") }' > Apps/App/Log.swift
  printf '%s\n' 'name: Local' 'runs:' '  using: composite' '  steps:' "    - uses: actions/cache/restore@$sha # v4" > .github/actions/local/action.yml
  printf '%s\n' 'name: CI' 'on: push' 'permissions:' '  contents: read' 'jobs:' '  a:' '    runs-on: ubuntu-24.04' '    steps:' \
    "      - uses: actions/checkout@$sha # v4" '      - uses: ./.github/actions/local' > .github/workflows/ci.yml
  python3 -I - <<'PY'
import json
json.dump({"name": "w", "lockfileVersion": 3, "packages": {"": {"name": "w"}, "node_modules/a": {"version": "1.0.0", "integrity": "sha512-x"}}},
          open("web/package-lock.json", "w"))
PY
  : > scripts/security-allow.txt
  git init -q . && git add -A
}

# put FILE CONTENT...: writes a file (relative to the copy) and stages it
put() { local f="$1"; shift; mkdir -p "$(dirname "$f")"; printf '%s\n' "$@" > "$f"; git add -A; }

# expect NAME ok|fail [PATTERN]
expect() {
  local name="$1" want="$2" pattern="${3:-}" out code=0
  out="$("$check" --root "$tmp/root" 2>&1)" || code=$?
  local ok=1
  case "$want" in ok) [ "$code" -eq 0 ] || ok=0 ;; fail) [ "$code" -ne 0 ] || ok=0 ;; esac
  if [ "$ok" -eq 1 ] && [ -n "$pattern" ] && ! grep -qE -- "$pattern" <<<"$out"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name (exit $code, want $want${pattern:+ matching /$pattern/})"; sed 's/^/     /' <<<"$out"; fi
}

# The real tree, with its allow-list.
code=0; out="$("$check" 2>&1)" || code=$?
if [ "$code" -eq 0 ] && ! grep -q '^note ' <<<"$out"; then pass=$((pass + 1)); echo "ok   the real tree passes, and no allow-list entry is stale"
else fail=$((fail + 1)); echo "FAIL the real tree (exit $code)"; sed 's/^/     /' <<<"$out"; fi

fresh; expect "clean tree passes" ok

# Secrets
fresh; put Sources/Lib/K.swift "let k = \"$key\""
expect "planted AGE-SECRET-KEY- fails" fail "secret-looking text: Sources/Lib/K.swift"
fresh; put docs/note.md "Paste ${key%%1QQ*}… here"
expect "a placeholder with an ellipsis passes" ok
fresh; put x/key.pem "$pem"
expect "a PEM private key header fails" fail "secret-looking text: x/key.pem"
fresh; put cfg.json "{\"api_key\": \"abcdefghijklmnopqrstuvwxyz0123456789ABCD\"}"
expect "a long literal next to api_key fails" fail "secret-looking text: cfg.json"
fresh; put Sources/Lib/K.swift "let k = \"$key\""
put scripts/security-allow.txt "secrets | Sources/Lib/ | sha256:$keyhash | test fixture"
expect "an allow-listed key (path and hash) passes" ok
fresh; put Sources/Lib/K.swift "let k = \"$key\"" "let j = \"${key%Q}Z\""
put scripts/security-allow.txt "secrets | Sources/Lib/ | sha256:$keyhash | test fixture"
expect "a NEW key in an allow-listed directory fails" fail "secret-looking text: Sources/Lib/K.swift:2"
fresh; put Sources/Other/K.swift "let k = \"$key\""
put scripts/security-allow.txt "secrets | Sources/Lib/ | sha256:$keyhash | test fixture"
expect "the allowed key in another directory fails" fail "secret-looking text: Sources/Other/K.swift"
fresh; put Sources/Lib/K.swift "let k = \"$(tr 'A-Z' 'a-z' <<<"$key")\""
expect "a lowercase key fails (Bech32 is case-insensitive)" fail "secret-looking text: Sources/Lib/K.swift"
fresh; put Sources/Lib/K.swift "let k = \"$key\""
put scripts/security-allow.txt "secrets | Sources/Lib/ | test fixture"
expect "a secrets entry without a hash fails" fail "secrets entry needs"
fresh; put keys/AuthKey_ABC123.p8 "x"
expect "a tracked AuthKey_*.p8 file fails" fail "secret-looking text: keys/AuthKey_ABC123.p8"
fresh; put Sources/Lib/a.mobileprovision "x"
expect "a tracked .mobileprovision file fails" fail "a.mobileprovision"
fresh; put Sources/Lib/K.swift "let k = \"$key\""
put scripts/security-allow.txt "perf | Sources/Lib/K.swift |"
expect "an allow-list entry without a reason fails" fail "needs 'rule \| path \| reason'"
fresh; put scripts/security-allow.txt "secrets | nowhere/ | sha256:$keyhash | nothing"
expect "a stale allow-list entry is reported" ok "matches nothing"

# Logging
fresh; put Sources/Lib/L.swift "func f() { print(\"x\") }"
expect "print( in Sources/ fails" fail "logging in Sources/: Sources/Lib/L.swift"
fresh; put Sources/Lib/L.swift "func f() { NSLog(\"x\") }"
expect "NSLog in Sources/ fails" fail "logging in Sources/"
fresh; put Sources/Lib/L.swift "let l = Logger(subsystem: \"s\", category: \"c\")"
expect "Logger( in Sources/ fails" fail "logging in Sources/"
fresh; put Sources/Lib/L.swift "func f() {" "#if DEBUG" "    NSLog(\"probe\")" "#endif" "}"
expect "NSLog inside #if DEBUG passes" ok
fresh; put Sources/Lib/L.swift "func f() {" "#if DEBUG" "#if os(macOS)" "#endif" "    NSLog(\"probe\")" "#endif" "    NSLog(\"after\")" "}"
expect "NSLog after a #if DEBUG block fails" fail "logging in Sources/: Sources/Lib/L.swift:7"
fresh; put Sources/Lib/L.swift "func f() {" "#if DEBUG" "    NSLog(\"probe\")" "#else" "    print(\"shipped\")" "#endif" "}"
expect "print in the #else of #if DEBUG fails" fail "logging in Sources/: Sources/Lib/L.swift:5"
fresh; put Sources/Lib/L.swift "func f() {" "#if DEBUG" "#elseif os(iOS)" "    NSLog(\"shipped\")" "#endif" "}"
expect "NSLog in the #elseif of #if DEBUG fails" fail "logging in Sources/: Sources/Lib/L.swift:4"
fresh; put Sources/Lib/L.swift "func f() {" "#if !DEBUG" "    print(\"shipped\")" "#else" "    NSLog(\"debug only\")" "#endif" "}"
expect "#if !DEBUG: the first branch is shipped (fails), the #else is debug (passes)" fail "logging in Sources/: Sources/Lib/L.swift:3"
fresh; put Sources/Lib/L.swift "func f() {" "#if !DEBUG" "#else" "    NSLog(\"debug only\")" "#endif" "}"
expect "NSLog in the #else of #if !DEBUG passes" ok
fresh; put Sources/Lib/L.swift "func f() { Swift.print(1) }"
expect "Swift.print( fails" fail "logging in Sources/"
fresh; put Sources/Lib/L.swift "func f() { debugPrint(1) }"
expect "debugPrint( fails" fail "logging in Sources/"
fresh; put Sources/Lib/L.swift "func f() { print (1) }"
expect "print ( with a space fails" fail "logging in Sources/"
fresh; put Sources/Lib/L.swift "// print(\"in a comment\")" "func f(p: Printer) { p.print(1) }"
expect "a comment and a method named print pass" ok
fresh; put Sources/Lib/P.swift "func f(perf: PerfSink, passphrase: String) {" "    perf.event(\"unlock\"," "               \"with \\(passphrase)\")" "}"
expect "a PerfSink call naming passphrase fails" fail "PerfSink call names a sensitive word: Sources/Lib/P.swift:2"
fresh; put Sources/Lib/P.swift "func f(perf: PerfSink, n: Int) { perf.event(\"list\", \"notes=\\(n)\") }"
expect "a PerfSink call with a count passes" ok
fresh; put Apps/App/Log.swift "func f(logger: Logger, title: String) { logger.info(\"opened \\(title, privacy: .public)\") }"
expect "an Apps log of a title with .public fails" fail "Apps/ log interpolates"
fresh; put Apps/App/Log.swift "func f(logger: Logger, title: String) { logger.info(\"opened \\(title)\") }"
expect "an Apps log of a title with the default (redacted) privacy passes" ok
fresh; put Apps/App/Log.swift "func f(logger: Logger, title: String) { logger.info(\"opened \\(title, privacy: .private)\") }"
expect "an Apps log of a title with .private passes" ok

# Pins
fresh; put .github/workflows/ci.yml "name: CI" "on: push" "permissions:" "  contents: read" "jobs:" "  a:" "    steps:" "      - uses: actions/checkout@v4"
expect "an action pinned to a tag fails" fail "not pinned to a full commit SHA"
fresh; put .github/workflows/ci.yml "name: CI" "on: push" "permissions:" "  contents: read" "jobs:" "  a:" "    steps:" "      - {uses: actions/checkout@v4}"
expect "an action pinned to a tag in flow form fails" fail "not pinned to a full commit SHA"
fresh; put .github/workflows/ci.yml "name: CI" "on: push" "permissions:" "  contents: read" "jobs:" "  a:" "    steps:" "      - uses: docker://alpine@sha256:$(printf 'a%.0s' $(seq 64))"
expect "a docker:// image by digest passes" ok
fresh; put .github/workflows/ci.yml "name: CI" "on: push" "permissions:" "  contents: read" "jobs:" "  a:" "    steps:" "      - uses: docker://alpine:3"
expect "a docker:// image by tag fails" fail "not pinned"
fresh; put .github/workflows/ci.yml "name: CI" "on: push" "permissions: write-all" "jobs:" "  a:" "    steps:" "      - uses: actions/checkout@$sha # v4"
expect "permissions: write-all fails" fail "write-all"
fresh; put .github/workflows/ci.yml "name: CI" "on: push" "permissions:" "  contents: read" "jobs:" "  a:" "    steps:" "      - uses: actions/checkout@main # $sha"
expect "a SHA only in the comment fails" fail "not pinned to a full commit SHA"
fresh; put .github/actions/local/action.yml "runs:" "  steps:" "    - uses: actions/cache/restore@v4"
expect "an unpinned action in a composite action fails" fail "action.yml:3: action not pinned"
fresh; put .github/workflows/ci.yml "name: CI" "on: push" "jobs:" "  a:" "    steps:" "      - uses: actions/checkout@$sha # v4"
expect "a workflow without permissions fails" fail "no top-level 'permissions:'"
fresh; put web/package-lock.json '{"lockfileVersion":3,"packages":{"":{"name":"w"},"node_modules/a":{"version":"1.0.0"}}}'
expect "a lockfile entry without integrity fails" fail "no integrity for node_modules/a"
fresh; python3 -I -c 'import json; d=json.load(open("Package.resolved")); d["pins"][0]["state"]["revision"]="abc"; json.dump(d, open("Package.resolved","w"))'; git add -A
expect "a Package.resolved pin without a revision fails" fail "no 40-hex revision"
fresh; python3 -I -c 'import json; d=json.load(open("Package.resolved")); d["pins"]=[p for p in d["pins"] if p["identity"]!="swift-crypto"]; json.dump(d, open("Package.resolved","w"))'; git add -A
expect "a Package.swift dependency missing from Package.resolved fails" fail "no pin for swift-crypto"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
