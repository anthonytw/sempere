#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""Fetches the macOS CLI's Developer ID provisioning profile through the App Store Connect API and writes it to a file.

    scripts/release-cli-profile.py OUT [NAME]        (NAME default: "Sempere CLI Developer ID 3", or $SEMPERE_CLI_PROFILE_NAME)

Runs on the BUILD account (scripts/release-build.sh), whose release.env holds the App Store Connect key; the maintainer's
account has none. The file is data for the maintainer's signing: scripts/release-sign-macos.sh verifies it whole (Apple's CMS
signature and chain, the App ID, the team, the container, the Developer ID type, the expiry, and that it lists the maintainer's
signing certificate) before one byte of it is used, so nothing about it is taken on this account's word. Reads
$SEMPERE_RELEASE_ENV (default ~/.config/sempere/release.env): SEMPERE_ASC_KEY_PATH, SEMPERE_ASC_KEY_ID and SEMPERE_ASC_ISSUER_ID.
Prints no key material. Exit 1 with a sentence on any failure.
"""
import base64, os, sys, time

def die(msg):
    print(f"error: {msg}", file=sys.stderr); sys.exit(1)

if len(sys.argv) < 2: die("usage: release-cli-profile.py OUT [NAME]")
out = sys.argv[1]
name = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("SEMPERE_CLI_PROFILE_NAME", "Sempere CLI Developer ID 3")
import jwt, requests

env = {}
path = os.path.expanduser(os.environ.get("SEMPERE_RELEASE_ENV", "~/.config/sempere/release.env"))
try:
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1); env[k] = v.strip().strip('"')
except OSError as e:
    die(f"cannot read {path}: {e}")
for k in ("SEMPERE_ASC_KEY_PATH", "SEMPERE_ASC_KEY_ID", "SEMPERE_ASC_ISSUER_ID"):
    env[k] = os.environ.get(k) or env.get(k, "")
    if not env[k] or env[k].startswith("TODO"): die(f"{k} is not set in {path}")
try:
    key = open(os.path.expanduser(env["SEMPERE_ASC_KEY_PATH"])).read()
except OSError as e:
    die(f"cannot read the App Store Connect key: {e}")
now = int(time.time())
token = jwt.encode({"iss": env["SEMPERE_ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}, key,
                   algorithm="ES256", headers={"kid": env["SEMPERE_ASC_KEY_ID"], "typ": "JWT"})
r = requests.get("https://api.appstoreconnect.apple.com/v1/profiles", params={"filter[name]": name, "limit": 50},
                 headers={"Authorization": "Bearer " + token}, timeout=60)
if r.status_code != 200: die(f"App Store Connect answered {r.status_code} for the profile list")
found = [d for d in r.json().get("data", []) if d["attributes"].get("name") == name]
if len(found) != 1: die(f"expected exactly one profile named \"{name}\", found {len(found)}")
a = found[0]["attributes"]
if a.get("profileType") != "MAC_APP_DIRECT": die(f"\"{name}\" is a {a.get('profileType')} profile, not a Developer ID (MAC_APP_DIRECT) one")
if a.get("profileState") != "ACTIVE": die(f"\"{name}\" is {a.get('profileState')}, not ACTIVE: make it again on developer.apple.com")
try:
    data = base64.b64decode(a["profileContent"], validate=True)
except Exception:
    die("the profile's content is not base64")
if not data or len(data) > 1 << 20: die("the profile's size is not plausible")
tmp = out + ".part"
with open(tmp, "wb") as f: f.write(data)
os.replace(tmp, out)
print(f"ok    profile \"{name}\" ({len(data)} bytes, expires {a.get('expirationDate', '?')}) written to {out}")
