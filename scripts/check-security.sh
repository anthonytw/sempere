#!/usr/bin/env bash
# Offline security checks with yes/no answers (docs/audits/README.md "Checks and audits"; docs/design/1.1-security-audit.md).
# Portable bash (+ python3 for JSON); runs on Linux and macOS; CI runs it in "Help and portability checks".
# It never opens PRs or issues: it prints what is wrong and exits 1.
#
#   1. secrets   AGE-SECRET-KEY-, PEM private keys, and a long literal next to password/token/secret, in tracked files
#   2. logging   print( NSLog os_log Logger( dump( in Sources/ (not Sources/SempereCLI, whose output is its interface,
#                and not inside #if DEBUG); PerfSink calls whose arguments name a key, secret, passphrase, identity,
#                password or title; Apps/ Logger calls that interpolate those words without `privacy: .private`
#   3. pins      Package.resolved entries have revisions and cover Package.swift; every package in
#                web/package-lock.json has an integrity hash; every `uses:` in .github is a full commit SHA (local
#                ./.github/actions paths excepted); every workflow declares `permissions:`
#
# scripts/security-allow.txt lists the exceptions, one per line: `rule | path | reason`. A path ending in `/` is a
# prefix. A line without a reason is an error; an entry that matches nothing is reported (so the list cannot rot).
#
# Usage: scripts/check-security.sh [--root DIR]     (DIR must be a git work tree; default: this repository)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
cd "$root"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # A CI container runs as another user than the checkout's owner ("dubious ownership"): trust this one directory.
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$root"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: $root is not a git work tree" >&2; exit 2; }
fi

failures=0
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }

# --- The allow-list ---------------------------------------------------------------------------------------------
allow_file="$root/scripts/security-allow.txt"
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
allow_rules=() allow_paths=() allow_used=()
if [ -f "$allow_file" ]; then
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    IFS='|' read -r rule path reason <<<"$line"
    rule="$(trim "$rule")"; path="$(trim "$path")"; reason="$(trim "${reason:-}")"
    case "$rule" in secrets|logging|perf|apps-logging) ;; *) fail "security-allow.txt:$n: unknown rule '$rule'"; continue ;; esac
    [ -n "$path" ] && [ -n "$reason" ] || { fail "security-allow.txt:$n: an entry needs 'rule | path | reason'"; continue; }
    allow_rules+=("$rule"); allow_paths+=("$path"); allow_used+=(0)
  done < "$allow_file"
fi

# allowed RULE FILE: true if an allow-list entry covers FILE (and marks it used)
allowed() {
  local i p
  for i in "${!allow_rules[@]}"; do
    [ "${allow_rules[$i]}" = "$1" ] || continue
    p="${allow_paths[$i]}"
    if [ "$p" = "$2" ] || { [ "${p%/}" != "$p" ] && [ "${2#"$p"}" != "$2" ]; }; then allow_used[$i]=1; return 0; fi
  done
  return 1
}

# report RULE LABEL: reads "file:line:text" lines on stdin, fails on each one that is not allowed
report() {
  local rule="$1" label="$2" line file
  while IFS= read -r line; do
    file="${line%%:*}"
    allowed "$rule" "$file" || fail "$label: ${line:0:200}"
  done
}

# --- 1. Secrets -------------------------------------------------------------------------------------------------
# No third-party scanner: a scanner action is itself supply chain.
report secrets "secret-looking text" < <({
  git grep -InE -e 'AGE-SECRET-KEY-(PQ-)?1[A-Z0-9]{20,}' -- . || true
  git grep -InE -e '-----BEGIN [A-Z ]*PRIVATE KEY' -- . || true
  git grep -InEi -e "(password|passwd|token|secret|api[_-]?key)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][A-Za-z0-9+/_=-]{32,}[\"']" -- . || true
} | sort -u)

# --- 2. Logging -------------------------------------------------------------------------------------------------
# awk: reads Swift files, skips comment lines and #if DEBUG regions (a debug build is not a shipped one).
# mode=bad prints print/NSLog/os_log/Logger/dump lines; mode=perf prints PerfSink calls (joined across lines) that name
# a sensitive word.
swift_scan() {
  awk -v mode="$1" '
    FNR == 1 { depth = 0; dbg = 0; stmt = ""; pdepth = 0 }
    /^[[:space:]]*#if / { depth++; if ($0 ~ /^[[:space:]]*#if DEBUG[[:space:]]*$/ && !dbg) dbg = depth; next }
    /^[[:space:]]*#endif/ { if (dbg && depth == dbg) dbg = 0; depth--; next }
    dbg { next }
    /^[[:space:]]*\/\// { next }
    mode == "bad" {
      if ($0 ~ /(^|[^A-Za-z0-9_.])(print|dump)\(|NSLog\(|os_log\(|Logger\(/) print FILENAME ":" FNR ":" $0
      next
    }
    mode == "perf" {
      if (stmt == "" && $0 ~ /(perf|[lL]og)[A-Za-z]*\??\.(log|event|measure|end)\(/) {
        stmt = $0; startl = FNR; l = $0
        pdepth = gsub(/\(/, "(", l) - gsub(/\)/, ")", l)
      } else if (stmt != "") {
        stmt = stmt " " $0; l = $0
        pdepth += gsub(/\(/, "(", l) - gsub(/\)/, ")", l)
      }
      if (stmt != "" && pdepth <= 0) {
        if (tolower(stmt) ~ /key|secret|passphrase|identity|password|title/) print FILENAME ":" startl ":" stmt
        stmt = ""
      }
    }
  ' "${@:2}"
}
swift_files() { git ls-files -z -- "$@" | { xargs -0 -n 200 sh -c 'for f; do case "$f" in *.swift) echo "$f";; esac; done' sh || true; }; }

src_files=()
while IFS= read -r f; do
  case "$f" in Sources/SempereCLI/*) ;; *) src_files+=("$f") ;; esac
done < <(swift_files Sources)
if [ ${#src_files[@]} -gt 0 ]; then
  report logging "logging in Sources/" < <(swift_scan bad "${src_files[@]}")
  report perf "PerfSink call names a sensitive word" < <(swift_scan perf "${src_files[@]}")
fi
# Apps/: a Logger call interpolating a sensitive word needs privacy: .private (or .sensitive) on that interpolation.
app_files=()
while IFS= read -r f; do app_files+=("$f"); done < <(swift_files Apps)
if [ ${#app_files[@]} -gt 0 ]; then
  report apps-logging "Apps/ log interpolates a sensitive word without privacy: .private" < <(
    { grep -nE '(logger|Log|log)[A-Za-z]*\.(debug|info|notice|error|fault|log|warning)\(|os_log\(' "${app_files[@]}" 2>/dev/null || true; } \
      | { grep -iE '\\\([^)]*(key|secret|passphrase|identity|password|title)[^)]*\)' || true; } \
      | { grep -vE '\\\([^)]*privacy: *\.(private|sensitive)' || true; })
fi

# --- 3. Pins ----------------------------------------------------------------------------------------------------
# Package.resolved: each pin has a 40-hex revision; the root one covers every .package(url:) of Package.swift.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  python3 -I - "$f" <<'PY' || failures=$((failures + 1))
import json, re, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception as e:
    print(f"FAIL  {p}: not valid JSON ({e})"); sys.exit(1)
bad = [x.get("identity", "?") for x in d.get("pins", []) if not re.fullmatch(r"[0-9a-f]{40}", x.get("state", {}).get("revision", ""))]
if bad:
    print(f"FAIL  {p}: no 40-hex revision for {', '.join(bad)}"); sys.exit(1)
PY
done < <(git ls-files | grep -E '(^|/)Package\.resolved$' || true)
if [ -f Package.swift ]; then
  if [ ! -f Package.resolved ]; then
    fail "Package.resolved is not committed"
  else
    for url in $(grep -oE '\.package\(url: *"[^"]+"' Package.swift | sed -E 's/.*"([^"]+)"/\1/'); do
      id="$(basename "$url" .git | tr '[:upper:]' '[:lower:]')"
      grep -qi "\"identity\" *: *\"$id\"" Package.resolved || fail "Package.resolved has no pin for $id (Package.swift names $url)"
    done
  fi
fi

# web/package-lock.json: every installed package has an integrity hash (workspace links have none).
if [ -f web/package-lock.json ]; then
  python3 -I - web/package-lock.json <<'PY' || failures=$((failures + 1))
import json, sys
d = json.load(open(sys.argv[1]))
bad = [k for k, v in d.get("packages", {}).items() if k and not v.get("link") and "integrity" not in v]
if bad:
    print(f"FAIL  web/package-lock.json: no integrity for {', '.join(bad[:10])}{' ...' if len(bad) > 10 else ''}"); sys.exit(1)
PY
fi

# Workflows and composite actions: every `uses:` is a full commit SHA (a tag can move) or a local path.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    ref="$(sed -E 's/^[0-9]+:[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//; s/[[:space:]]*#.*$//; s/["'"'"']//g' <<<"$hit")"
    case "$ref" in ./.github/actions/*) continue ;; esac
    if ! grep -qE '@[0-9a-f]{40}$' <<<"$ref"; then fail "$f: action not pinned to a full commit SHA: ${hit#*:}"; fi
  done < <(grep -nE '^[[:space:]]*-?[[:space:]]*uses:' "$f" || true)
done < <(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml' '.github/actions/*/action.yml' '.github/actions/*/action.yaml')
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qE '^permissions:' "$f" || fail "$f: no top-level 'permissions:' (a workflow declares its token scope)"
done < <(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')

# --- Allow-list upkeep -----------------------------------------------------------------------------------------
for i in "${!allow_rules[@]}"; do
  [ "${allow_used[$i]}" = 1 ] || echo "note  security-allow.txt: '${allow_rules[$i]} | ${allow_paths[$i]}' matches nothing; remove it" >&2
done

if [ "$failures" -gt 0 ]; then echo "check-security: $failures problem(s)" >&2; exit 1; fi
echo "check-security: ok"
