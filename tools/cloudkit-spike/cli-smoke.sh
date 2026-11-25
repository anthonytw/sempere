#!/bin/bash
# A signed end-to-end smoke of the CloudKit adapter through the real CLI bundle, against the DEVELOPMENT environment (docs/design/1.4-cloudkit.md §14).
# Builds `sempere`, makes the release-shaped bundle, signs it with the development identity and the CLI App ID's development profile
# (scripts/release-sign-macos.sh --dev), links it from a bin/ folder as Homebrew does, then: creates a store vault with notes, an image attachment
# and a setting, adds a CloudKit target, syncs, copies the vault into a second store, syncs that and compares the notes. Run it through the build lock:
#   CLI_PROFILE=<"Sempere CLI Dev 3" provisioning profile> ~/.claude/scripts/xc-lock.sh tools/cloudkit-spike/cli-smoke.sh [WORKDIR]
# The vault's zone is left in the development database (cktool cannot delete private zones): `xcrun cktool reset-schema` (development
# only; it deletes development data) cleans up, then import tools/cloudkit-spike/schema.ckdb again.
set -euo pipefail
cd "$(dirname "$0")/../.."
work=${1:-$(mktemp -d)}; mkdir -p "$work"
profile=${CLI_PROFILE:?CLI_PROFILE=the development provisioning profile of io.github.anthonytw.sempere.cli}
swift build -c release --product sempere >/dev/null 2>&1 || { swift build -c release --product sempere 2>&1 | tail -20; exit 1; }
bin=$(swift build -c release --product sempere --show-bin-path)/sempere
version=$("$bin" --version | head -1 | cut -d' ' -f2)
scripts/cli-bundle.sh "$bin" "$version" "$work/bundle" Sources/SempereFonts/Fonts >/dev/null
SEMPERE_CLI_BUNDLE="$work/bundle" scripts/package-cli.sh "$bin" "$version" macos-universal "$work/dist" >/dev/null
SEMPERE_RELEASE_ENV=/dev/null SEMPERE_CLI_PROFILE=$profile scripts/release-sign-macos.sh --dev --version "$version" \
  "$work/dist/sempere-$version-macos-universal.tar.gz" "$work/signed.tar.gz" >/dev/null
mkdir -p "$work/x/bin" && tar -xzf "$work/signed.tar.gz" -C "$work/x"
ln -sf "../sempere-$version-macos-universal/sempere.app/Contents/MacOS/sempere" "$work/x/bin/sempere"
S=$work/x/bin/sempere
export XDG_STATE_HOME=$work/state
mkdir -p "$work/store" "$work/store2"
"$S" store create Smoke --store "$work/store" --recovery-out "$work/recovery.key" >/dev/null
V=$(ls -d "$work"/store/*/Smoke.sempere)
python3 - "$work/big.png" <<'PY'
import os, struct, sys, zlib
w = h = 300
raw = b"".join(b"\x00" + os.urandom(w * 3) for _ in range(h))
def ch(t, d): c = struct.pack(">I", len(d)) + t + d; return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw, 0)) + ch(b"IEND", b""))
PY
"$S" store target add Smoke --cloudkit --store "$work/store"
"$S" store sync Smoke --store "$work/store" | tail -1
cp -R "$V" "$work/copy.sempere"                      # what a second device starts from
n1=$("$S" notes new "First" --vault "$V" | tail -1); "$S" notes new "Second" --vault "$V" >/dev/null
"$S" attach image "$n1" "$work/big.png" --vault "$V" >/dev/null
"$S" store sync Smoke --store "$work/store" | tail -1
"$S" settings set handwriting.recognize false --vault "$V" >/dev/null; "$S" store sync Smoke --store "$work/store" | tail -1   # a create ...
"$S" settings set handwriting.recognize true --vault "$V" >/dev/null; "$S" store sync Smoke --store "$work/store" | tail -1    # ... then a replace under its tag
"$S" store import "$work/copy.sempere" --name Smoke2 --store "$work/store2" >/dev/null
"$S" store target add Smoke2 --cloudkit --store "$work/store2" >/dev/null
"$S" store sync Smoke2 --store "$work/store2" | tail -1
V2=$(ls -d "$work"/store2/*/Smoke2.sempere)
diff <("$S" notes list --vault "$V" | awk '{print $1, $2}') <("$S" notes list --vault "$V2" | awk '{print $1, $2}') && echo "ok: the second device has the same notes"
# C3: the vaults in the account (sempere cloudkit): the vault is listed by its name, opened into a third store, and the notes match.
"$S" cloudkit list --store "$work/store2" --json | python3 -c 'import json,sys; v=json.load(sys.stdin); assert any(x["inStore"] and x["hasCloudKitTarget"] for x in v), v; print("ok: cloudkit list names", [x["name"] for x in v][:3])'
id=$("$S" store list --store "$work/store2" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["vaultId"])')
mkdir -p "$work/store3"
"$S" cloudkit open "$id" --store "$work/store3" >/dev/null
V3=$(ls -d "$work"/store3/*/*.sempere)
diff <("$S" notes list --vault "$V" | awk '{print $1, $2}') <("$S" notes list --vault "$V3" | awk '{print $1, $2}') && echo "ok: cloudkit open copied the same notes"
"$S" store target list "$id" --store "$work/store3" | grep -q cloudkit && echo "ok: the opened vault has its iCloud target"
echo "work folder: $work"
