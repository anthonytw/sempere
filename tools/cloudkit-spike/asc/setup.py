# /// script
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""Design §11 steps 4, 6, 8 through the App Store Connect API (additive only: nothing is deleted or revoked).
   uv run tools/cloudkit-spike/asc/setup.py [--profiles-dir DIR]
Reads credentials from ~/.config/sempere/release.env (see lib.py); prints no key material."""
import base64, os, re, subprocess, sys
from lib import call, json

APP, CLI_ID = "io.github.anthonytw.sempere", "io.github.anthonytw.sempere.cli"
out = sys.argv[sys.argv.index("--profiles-dir") + 1] if "--profiles-dir" in sys.argv else "."

def bundle(identifier):
    c, j = call("GET", "/v1/bundleIds", limit=200, **{"filter[identifier]": identifier})
    for d in j["data"]:
        if d["attributes"]["identifier"] == identifier: return d["id"]

def capability(bid, kind, settings=None):
    c, j = call("GET", f"/v1/bundleIds/{bid}/bundleIdCapabilities")
    if kind in [x["attributes"]["capabilityType"] for x in j["data"]]: return "present"
    attrs = {"capabilityType": kind}
    if settings: attrs["settings"] = settings
    c, j = call("POST", "/v1/bundleIdCapabilities", {"data": {"type": "bundleIdCapabilities", "attributes": attrs,
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid}}}}})
    return c if c == 201 else j.get("errors")

# Step 4: the app's App ID gets Push Notifications (iCloud was ticked in the portal by the owner).
app = bundle(APP)
print("app push:", capability(app, "PUSH_NOTIFICATIONS"))

# Step 8: the CLI App ID, iCloud on. The container assignment is NOT in the API: portal (see the design doc).
cli = bundle(CLI_ID)
if not cli:
    c, j = call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {"identifier": CLI_ID, "name": "Sempere CLI", "platform": "MAC_OS"}}})
    cli = j["data"]["id"]; print("cli id created", c)
print("cli icloud:", capability(cli, "ICLOUD", [{"key": "ICLOUD_VERSION", "options": [{"key": "XCODE_6", "enabled": True}]}]))

# Step 6: this Mac. Apple silicon Macs register with the PROVISIONING UDID, not the hardware UUID
# (a profile for the hardware UUID is accepted by the API and the signed app is then killed with SIGKILL, no message).
hw = subprocess.run(["system_profiler", "SPHardwareDataType"], capture_output=True, text=True).stdout
udid = re.search(r"Provisioning UDID: (\S+)", hw).group(1)
c, j = call("GET", "/v1/devices", limit=200)
mac = [d for d in j["data"] if d["attributes"]["udid"].upper() == udid.upper()]
if not mac:
    c, j = call("POST", "/v1/devices", {"data": {"type": "devices", "attributes": {"name": "claude-mac", "platform": "MAC_OS", "udid": udid}}})
    mac = [j["data"]]
dev = mac[0]["id"]
c, j = call("GET", "/v1/certificates", limit=200)
dev_cert = [d["id"] for d in j["data"] if d["attributes"]["certificateType"] == "DEVELOPMENT"]
ios_dev = [d["id"] for d in call("GET", "/v1/devices", limit=200)[1]["data"] if d["attributes"]["platform"] == "IOS"]

def profile(name, ptype, bid, certs, devices=None):
    rel = {"bundleId": {"data": {"type": "bundleIds", "id": bid}}, "certificates": {"data": [{"type": "certificates", "id": x} for x in certs]}}
    if devices: rel["devices"] = {"data": [{"type": "devices", "id": x} for x in devices]}
    c, j = call("POST", "/v1/profiles", {"data": {"type": "profiles", "attributes": {"name": name, "profileType": ptype}, "relationships": rel}})
    print(name, c, j.get("errors") or j["data"]["id"])
    if c == 201:
        open(os.path.join(out, name.replace(" ", "_") + ".provisionprofile"), "wb").write(base64.b64decode(j["data"]["attributes"]["profileContent"]))

profile("Sempere Dev Catalyst", "MAC_CATALYST_APP_DEVELOPMENT", app, dev_cert, [dev])
profile("Sempere Dev iOS", "IOS_APP_DEVELOPMENT", app, dev_cert, ios_dev)
profile("Sempere CLI Dev", "MAC_APP_DEVELOPMENT", cli, dev_cert, [dev])
dev_id = [d["id"] for d in call("GET", "/v1/certificates", limit=200)[1]["data"] if d["attributes"]["certificateType"] == "DEVELOPER_ID_APPLICATION_G2"]
profile("Sempere CLI Developer ID", "MAC_APP_DIRECT", cli, dev_id[:1])
