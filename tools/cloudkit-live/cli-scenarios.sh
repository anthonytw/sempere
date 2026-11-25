#!/bin/bash
# Two devices syncing one vault through the real CloudKit database (development), each a store of the signed `sempere` CLI bundle with
# a state folder of its own (its own device key, trust record and mirror): the end-to-end half of docs/design/1.4-cloudkit.md §10.2.
# It replaces tools/cloudkit-spike/cli-smoke.sh. tools/cloudkit-live/run.sh builds and signs both programs and calls it:
#
#   CKL=<cloudkit-live executable> SEMPERE=<signed sempere> tools/cloudkit-live/cli-scenarios.sh WORKDIR
#
# Scenarios, in order, on one vault (a zone `sempere-<vault id>`, deleted at the end through the adapter):
#   join        device B joins A's vault with nothing but the zone and the typed words (device init, approve, confirm)
#   converge    notes, an image attachment and a setting made on A are on B
#   conflict    both devices change the same setting and rename the same note while apart: after a sync each, they agree
#   delete      a note deleted on A is deleted on B (and listed under --deleted)
#   large       a 70 MiB attachment (a file over the 64 MiB part threshold: it is split into parts) reaches B intact
#   token       a run with nothing to do moves nothing, and the mirror is kept on disk between processes
#   zone        the zone is deleted under B: the run says so and keeps B's notes; removing and adding the target uploads again
# No scenario needs a push. A failed check prints `FAIL`, the logs stay in WORKDIR, and the exit status is 1.
set -uo pipefail
work=${1:?WORKDIR}
CKL=${CKL:?the cloudkit-live executable}
S=${SEMPERE:?the signed sempere}
mkdir -p "$work"; work=$(cd "$work" && pwd)
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
check() { # description, command...
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
a() { XDG_STATE_HOME=$work/state-A "$S" "$@"; }
b() { XDG_STATE_HOME=$work/state-B "$S" "$@"; }
sa() { a store "$@" --store "$work/storeA"; }
sb() { b store "$@" --store "$work/storeB"; }
mkdir -p "$work/storeA" "$work/storeB" "$work/state-A" "$work/state-B"
zone=""
cleanup() { [[ -n $zone ]] && "$CKL" delete-zone "$zone" >/dev/null 2>&1; }
trap cleanup EXIT

# --- join ---------------------------------------------------------------------------------------------------------------------
echo "run join"
sa create Live --recovery-out "$work/recovery.key" >/dev/null || { bad "create"; exit 1; }
VA=$(ls -d "$work"/storeA/*/Live.sempere)
id=$(basename "$(dirname "$VA")")
zone=sempere-$(echo "$id" | tr 'A-Z' 'a-z')
# The marker that lets `run.sh cleanup` find this vault's zone if the trap below never runs (it is the only kind of `sempere-` zone cleanup deletes).
a vault label "cloudkit-live-test Live" --vault "$VA" >/dev/null || { bad "vault label"; exit 1; }
sa target add Live --cloudkit >/dev/null || { bad "target add on A"; exit 1; }
a notes new "First" --vault "$VA" >/dev/null
a notes new "Second" --vault "$VA" >/dev/null
python3 - "$work/big.png" <<'PY'
import os, struct, sys, zlib
w = h = 300
raw = b"".join(b"\x00" + os.urandom(w * 3) for _ in range(h))
def ch(t, d): c = struct.pack(">I", len(d)) + t + d; return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw, 0)) + ch(b"IEND", b""))
PY
a attach image First "$work/big.png" --vault "$VA" >/dev/null || bad "attach image"
a settings set handwriting.recognize false --vault "$VA" >/dev/null
sa sync Live > "$work/a-sync-1.log" 2>&1 && ok "A's first sync" || { bad "A's first sync"; cat "$work/a-sync-1.log"; exit 1; }
# Device B starts from a copy of the vault folder's public files only: the joiner has no key (docs/cli.md "Join a second device").
cp -R "$VA" "$work/seedB.sempere"
sb import "$work/seedB.sempere" --name LiveB >/dev/null || { bad "B import"; exit 1; }
VB=$(ls -d "$work"/storeB/*/LiveB.sempere)
b device init --vault "$VB" --name "Device B" --json > "$work/b-init.json" 2>"$work/b-init.err" || { bad "device init"; cat "$work/b-init.err"; exit 1; }
words_b=$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["words"]))' "$work/b-init.json")
sb target add LiveB --cloudkit >/dev/null || { bad "target add on B"; exit 1; }
sb sync LiveB > "$work/b-sync-0.log" 2>&1 && ok "B's first sync (uploads its join request, a keyless run)" || { bad "B's first sync"; cat "$work/b-sync-0.log"; }
sa sync Live > "$work/a-sync-2.log" 2>&1 && ok "A's sync (receives the request)" || { bad "A's second sync"; cat "$work/a-sync-2.log"; }
# shellcheck disable=SC2086
a devices approve $words_b --vault "$VA" --json > "$work/a-approve.json" 2>"$work/a-approve.err" || { bad "approve"; cat "$work/a-approve.err"; exit 1; }
words_a=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(d.get("reply") or []))' "$work/a-approve.json")
[[ -n $words_a ]] || { bad "approve printed no reply words"; cat "$work/a-approve.json"; exit 1; }
sa sync Live > "$work/a-sync-3.log" 2>&1 && ok "A's sync (uploads the new vault.json)" || bad "A's third sync"
sb sync LiveB > "$work/b-sync-1.log" 2>&1 && ok "B's sync (receives it)" || { bad "B's second sync"; cat "$work/b-sync-1.log"; }
# shellcheck disable=SC2086
b device confirm $words_a --vault "$VB" > "$work/b-confirm.log" 2>&1 && ok "B confirms the six words" || { bad "device confirm"; cat "$work/b-confirm.log"; exit 1; }
sb sync LiveB > "$work/b-sync-2.log" 2>&1 && ok "B's sync as a listed device" || { bad "B's third sync"; cat "$work/b-sync-2.log"; }

# --- converge -----------------------------------------------------------------------------------------------------------------
echo "run converge"
list() { local who=$1 vault=$2; shift 2; "$who" notes list --vault "$vault" "$@" | tail -n +2 | awk '{ $1=""; print }' | sort; }
check "B lists A's notes" test "$(list b "$VB")" = "$(list a "$VA")"
check "B lists two notes" test "$(list b "$VB" | wc -l | tr -d ' ')" = 2
check "A and B verify (every file decrypts, the attachment included)" bash -c "XDG_STATE_HOME='$work/state-B' '$S' vault verify --vault '$VB'"
check "the setting reached B" test "$(b settings get handwriting.recognize --vault "$VB" 2>/dev/null | tail -1)" = false

# --- conflict -----------------------------------------------------------------------------------------------------------------
echo "run conflict"
a settings set handwriting.recognize true --vault "$VA" >/dev/null
b settings set handwriting.recognize false --vault "$VB" >/dev/null
a notes rename First "First (A)" --vault "$VA" >/dev/null
b notes rename First "First (B)" --vault "$VB" >/dev/null
a notes new "Only on A" --vault "$VA" >/dev/null
b notes new "Only on B" --vault "$VB" >/dev/null
sa sync Live >"$work/a-sync-4.log" 2>&1 || bad "A's sync after the edits"
sb sync LiveB >"$work/b-sync-3.log" 2>&1 || bad "B's sync after the edits"
sa sync Live >"$work/a-sync-5.log" 2>&1 || bad "A's second sync after the edits"
check "the devices agree on every note" test "$(list a "$VA")" = "$(list b "$VB")"
check "both new notes are on both" test "$(list a "$VA" | grep -c 'Only on')" = 2
check "the devices agree on the setting" test "$(a settings get handwriting.recognize --vault "$VA" | tail -1)" = "$(b settings get handwriting.recognize --vault "$VB" | tail -1)"
check "the renamed note has one title on both" test "$(list a "$VA" | grep -c '^ First')" = 1

# --- delete -------------------------------------------------------------------------------------------------------------------
echo "run delete"
a notes delete Second --vault "$VA" >/dev/null || bad "notes delete"
sa sync Live >/dev/null 2>&1 || bad "A's sync after the delete"
sb sync LiveB >/dev/null 2>&1 || bad "B's sync after the delete"
check "the deleted note is off B's list" test "$(list b "$VB" | grep -c Second)" = 0
check "it is listed as deleted on B" bash -c "XDG_STATE_HOME='$work/state-B' '$S' notes list --deleted --vault '$VB' | grep -q Second"

# --- large --------------------------------------------------------------------------------------------------------------------
echo "run large"
head -c $((70 * 1024 * 1024)) /dev/urandom > "$work/big.bin"
a attach recording "Only on A" "$work/big.bin" --title big --type audio/mpeg --vault "$VA" >"$work/a-attach-big.log" 2>&1 \
  && ok "A attaches a 70 MiB file" || { bad "A attaches a 70 MiB file"; cat "$work/a-attach-big.log"; }
t0=$(date +%s)
sa sync Live >"$work/a-sync-big.log" 2>&1 && ok "A uploads it ($(( $(date +%s) - t0 )) s)" || { bad "A's sync of the big file"; tail -5 "$work/a-sync-big.log"; }
t0=$(date +%s)
sb sync LiveB >"$work/b-sync-big.log" 2>&1 && ok "B downloads it ($(( $(date +%s) - t0 )) s)" || { bad "B's sync of the big file"; tail -5 "$work/b-sync-big.log"; }
check "B verifies the big file" bash -c "XDG_STATE_HOME='$work/state-B' '$S' vault verify --vault '$VB'"
sizeA=$(find "$VA/notes" -name '*.age' -size +60M -exec stat -f %z {} \; | sort | tr '\n' ' ')
sizeB=$(find "$VB/notes" -name '*.age' -size +60M -exec stat -f %z {} \; | sort | tr '\n' ' ')
check "the big blob has the same size on both ($sizeA)" test -n "$sizeA" -a "$sizeA" = "$sizeB"
rm -f "$work/big.bin"

# --- token --------------------------------------------------------------------------------------------------------------------
echo "run token"
mirror=$(find "$work/storeB" -name 'mirror-2.txt' | head -1)
check "B keeps a mirror (with the change token) on disk" test -s "${mirror:-/nonexistent}"
sb sync LiveB --json >"$work/b-quiet.json" 2>&1
check "a run with nothing to do moves no file" python3 - "$work/b-quiet.json" <<'PY'
import json, sys
t = open(sys.argv[1]).read()
d = json.loads(t[t.index("["):] if "[" in t else t)
r = d[0]["report"]
moved = sum(len(r.get(k) or []) for k in ("uploaded", "downloaded", "deleted")) if isinstance(r.get("uploaded"), list) else sum(int(r.get(k) or 0) for k in ("uploaded", "downloaded", "deleted"))
sys.exit(0 if moved == 0 else 1)
PY
sa sync Live >/dev/null 2>&1
sb sync LiveB >/dev/null 2>&1 && ok "a cold process continues from the saved token"

# --- zone ---------------------------------------------------------------------------------------------------------------------
echo "run zone"
b notes new "Written before the zone went" --vault "$VB" >/dev/null
"$CKL" delete-zone "$zone" || bad "delete-zone"
sb sync LiveB >"$work/b-gone.log" 2>&1; st=$?
check "B's run fails when the zone is gone" test "$st" != 0
check "it says the iCloud data is gone and nothing was deleted" grep -q "nothing here was deleted" "$work/b-gone.log"
check "B still has every note" test "$(list b "$VB" | wc -l | tr -d ' ')" -ge 4
tid=$(sb target list LiveB --json | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d.get("targets", d) if isinstance(d, dict) else d; print(d[0]["id"])')
sb target remove LiveB "$tid" >/dev/null 2>&1 || bad "target remove"
sb target add LiveB --cloudkit >/dev/null 2>&1 || bad "target add again"
sb sync LiveB >"$work/b-again.log" 2>&1 && ok "B uploads the vault again" || { bad "B's sync into a new zone"; tail -5 "$work/b-again.log"; }
tid=$(sa target list Live --json | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d.get("targets", d) if isinstance(d, dict) else d; print(d[0]["id"])')
sa target remove Live "$tid" >/dev/null 2>&1 || bad "A target remove"
sa target add Live --cloudkit >/dev/null 2>&1 || bad "A target add again"
sa sync Live >"$work/a-again.log" 2>&1 && ok "A syncs with the new zone" || { bad "A's sync with the new zone"; tail -5 "$work/a-again.log"; }
sb sync LiveB >/dev/null 2>&1
check "the devices agree again, B's new note included" test "$(list a "$VA")" = "$(list b "$VB")"

[[ $fail == 0 ]] && echo "cli scenarios: all passed" || echo "cli scenarios: FAILED (logs in $work)"
exit $fail
