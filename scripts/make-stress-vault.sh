#!/usr/bin/env bash
# Builds a seeded synthetic vault with the CLI, for the sync stress tests (docs/ci.md "Sync stress").
#   scripts/make-stress-vault.sh OUT_DIR [SEED] [NOTES]      (defaults: seed 1, 640 notes)
# OUT_DIR gets key-a.txt and key-b.txt (two devices' key files: A is the vault's home, B joined by approval),
# state-a/ and state-b/ (each device's XDG_STATE_HOME: device key, trust record, ledger, device id and clock),
# recovery.txt (the vault's recovery key) and Stress.sempere.
# The same seed and count give the same notes (titles, notebooks, tags, texts, image bytes); file
# names differ, since revisions carry the time they were written. About a minute for 640 notes.
# Contents: every note has a title, a notebook (12, nested) and one to three tags; one in four
# gets a text box, one in eight a second edit by the other device, one in sixteen a small image
# (a noise PNG, incompressible) and four notes a 3 MB image (more than one 2 MiB download
# segment, so cut downloads resume midway).
# Reuses OUT_DIR when it holds a finished vault of the same seed and count (OUT_DIR/done).
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:?usage: make-stress-vault.sh OUT_DIR [SEED] [NOTES]}"
seed="${2:-1}"
count="${3:-640}"
if [ -f "$out/done" ] && [ "$(cat "$out/done")" = "$seed $count" ]; then
  echo "$out: seed $seed, $count notes (reused)"
  exit 0
fi
bin="${SEMPERE_BIN:-}"
if [ -z "$bin" ]; then
  swift build --product sempere >/dev/null
  bin="$(swift build --show-bin-path)/sempere"
fi
rm -rf "$out"
mkdir -p "$out/img"
out="$(cd "$out" && pwd)"   # XDG_STATE_HOME must be absolute, or the CLI uses ~/.local/state
vault="$out/Stress.sempere"
export XDG_CACHE_HOME="$out/cache"
# Device A creates the vault (its home); device B joins by approval (format.md §15.12). Each device's key
# file (identity and signing seeds) is copied to key-a.txt / key-b.txt for the tests.
XDG_STATE_HOME="$out/state-a" "$bin" vault init "$vault" --name "device A" --vault-label "Stress $seed" \
  --recovery-out "$out/recovery.txt" >/dev/null
words="$(XDG_STATE_HOME="$out/state-b" "$bin" device init --vault "$vault" --name "device B" --json \
  | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["words"]))')"
# shellcheck disable=SC2086
reply="$(XDG_STATE_HOME="$out/state-a" "$bin" devices approve $words --vault "$vault" --json \
  | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["reply"]))')"
# shellcheck disable=SC2086
XDG_STATE_HOME="$out/state-b" "$bin" device confirm $reply --vault "$vault" >/dev/null
for d in a b; do cp "$(ls "$out/state-$d"/sempere/devices/*/device.key)" "$out/key-$d.txt"; done

# Deterministic image bytes: noise PNGs (stdlib only).
python3 - "$out/img" "$seed" "$count" <<'PY'
import random, struct, sys, zlib
out, seed, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def png(w, h, r):
    raw = b"".join(b"\0" + r.randbytes(w * 3) for _ in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 1)) + chunk(b"IEND", b""))
r = random.Random(seed)
for i in range(count):
    if i % 16 == 5:
        side = r.randrange(48, 160)
        open(f"{out}/{i}.png", "wb").write(png(side, side, r))
    if i in (7, count // 3, count // 2, count - 9):
        open(f"{out}/{i}-large.png", "wb").write(png(1000, 1000, r))
PY

RANDOM="$seed"
words=(ink tide ember quill harbor lattice meadow cipher orbit fern basalt willow prism ledger cobalt)
nb=("Work" "Work/Projects" "Work/Projects/Atlas" "Home" "Home/Recipes" "Reading" "Reading/Papers"
    "Travel" "Travel/2026" "Ideas" "Archive" "Archive/Old")
tags=(todo idea draft review math physics travel family)
run() { # device, args...
  local dev="$1"; shift
  XDG_STATE_HOME="$out/state-$dev" "$bin" "$@" --vault "$vault" -q
}
for i in $(seq 0 $((count - 1))); do
  title="${words[RANDOM % ${#words[@]}]} ${words[RANDOM % ${#words[@]}]} $i"
  args=(notes new "$title" --notebook "${nb[RANDOM % ${#nb[@]}]}")
  for _ in $(seq 0 $((RANDOM % 3))); do args+=(--tag "${tags[RANDOM % ${#tags[@]}]}"); done
  id="$(run a "${args[@]}" | tail -1)"
  if [ $((i % 4)) -eq 1 ]; then
    run a attach text "$id" "note $i: ${words[RANDOM % ${#words[@]}]} $RANDOM" >/dev/null
  fi
  if [ $((i % 8)) -eq 3 ]; then
    run b notes rename "$id" "$title (edited on B)" >/dev/null
  fi
  [ -f "$out/img/$i.png" ] && run a attach image "$id" "$out/img/$i.png" >/dev/null
  [ -f "$out/img/$i-large.png" ] && run b attach image "$id" "$out/img/$i-large.png" >/dev/null
  if [ $((i % 64)) -eq 0 ]; then printf '\r%d of %d notes' "$i" "$count" >&2; fi
done
printf '\r%d notes\n' "$count" >&2
rm -rf "$out/img" "$out/cache"
echo "$seed $count" > "$out/done"
echo "$out: seed $seed, $count notes"
