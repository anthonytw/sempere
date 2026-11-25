#!/usr/bin/env bash
# Tests the provisioning-profile verification of scripts/release-sign-macos.sh (--check-profile): a real Apple-signed development
# profile passes, and a one-byte change, a CMS signed by a self-made CA, a profile for another App ID, bytes after the signed data and
# a truncated file are each refused. Needs a Mac with the seat's development profiles (SEMPERE_TEST_PROFILES, default
# ~/.config/sempere/profiles: Sempere_CLI_Dev_3.provisionprofile and Sempere_Dev_Catalyst_Mac2.provisionprofile) and an
# "Apple Development" identity in the keychain; elsewhere (GitHub CI) it says so and exits 0.
set -uo pipefail
cd "$(dirname "$0")/.."
dir=${SEMPERE_TEST_PROFILES:-$HOME/.config/sempere/profiles}
good=$dir/Sempere_CLI_Dev_3.provisionprofile catalyst=$dir/Sempere_Dev_Catalyst_Mac2.provisionprofile
if [[ $(uname) != Darwin || ! -f $good || ! -f $catalyst ]] || ! security find-identity -v -p codesigning 2>/dev/null | grep -q '"Apple Development'; then
  echo "skip  no development profiles or Apple Development identity here: profile verification not tested"; exit 0
fi
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail=0
check() { local name=$1 want=$2 file=$3 out rc; out=$(bash scripts/release-sign-macos.sh --dev --check-profile "$file" 2>&1); rc=$?
  if [[ $want == ok ]]; then [[ $rc == 0 ]] || { echo "FAIL  $name: $out"; fail=1; return; }
  else [[ $rc != 0 && $out == *"$want"* ]] || { echo "FAIL  $name (wanted: $want): $out"; fail=1; return; }; fi
  echo "ok    $name"; }
check "a real development profile passes" ok "$good"
python3 - "$good" "$t" <<'PY'
import sys
d=bytearray(open(sys.argv[1],'rb').read()); t=sys.argv[2]
i=d.find(b'io.github.anthonytw.sempere.cli'); x=bytearray(d); x[i+3]^=1
open(t+'/tampered','wb').write(x)
open(t+'/trailing','wb').write(bytes(d)+b'\0\0 extra')
open(t+'/truncated','wb').write(bytes(d[:len(d)//2]))
PY
check "a one-byte change is refused" "not a provisioning profile signed by Apple" "$t/tampered"
check "bytes after the signed data are refused" "not one DER-encoded message" "$t/trailing"
check "a truncated file is refused" "not one DER-encoded message" "$t/truncated"
check "a profile for another App ID is refused" "the profile is for" "$catalyst"
# A CMS with valid content signed by a self-made CA that names itself like Apple's signer.
security cms -D -i "$good" > "$t/content.plist" 2>/dev/null
O=/usr/bin/openssl
$O req -x509 -newkey rsa:2048 -nodes -keyout "$t/ca.key" -out "$t/ca.pem" -subj "/CN=Apple Root CA/O=Apple Inc./C=US" -days 30 >/dev/null 2>&1
$O req -newkey rsa:2048 -nodes -keyout "$t/leaf.key" -out "$t/leaf.csr" -subj "/CN=Mac OS X Provisioning Profile Signing/O=Apple Inc./C=US" >/dev/null 2>&1
$O x509 -req -in "$t/leaf.csr" -CA "$t/ca.pem" -CAkey "$t/ca.key" -CAcreateserial -out "$t/leaf.pem" -days 30 >/dev/null 2>&1
$O smime -sign -binary -in "$t/content.plist" -signer "$t/leaf.pem" -inkey "$t/leaf.key" -certfile "$t/ca.pem" -outform DER -out "$t/selfmade" >/dev/null 2>&1
check "a profile signed under a self-made CA is refused" "not a provisioning profile signed by Apple" "$t/selfmade"
exit $fail
