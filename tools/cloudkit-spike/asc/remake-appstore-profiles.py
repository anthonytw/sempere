# /// script
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""Design §11 step 5: make the App Store profiles again after the App ID gained iCloud and Push.
NOT RUN by the C0 spike. Names match scripts/testflight.sh's defaults ('Sempere iOS App Store', ...), so the old INVALID
profile of a name is replaced by a new one under the same name only after the old one is deleted; this script creates
'<name> 2' beside it and prints the SEMPERE_PROFILE_* values to export. Run it when 1.4's first CloudKit build starts
(or earlier if a TestFlight build is needed while the App Store profiles are INVALID: they have been since iCloud was added)."""
import base64, os, sys
from lib import call

want = {"Sempere iOS App Store": ("IOS_APP_STORE", "io.github.anthonytw.sempere"),
        "Sempere Mac App Store": ("MAC_CATALYST_APP_STORE", "io.github.anthonytw.sempere")}
c, j = call("GET", "/v1/profiles", limit=200)
for d in j["data"]:
    n = d["attributes"]["name"]
    if n in want and d["attributes"]["profileState"] == "INVALID":
        ptype, ident = want[n]
        bid = call("GET", f"/v1/profiles/{d['id']}/bundleId")[1]["data"]["id"]
        certs = [x["id"] for x in call("GET", f"/v1/profiles/{d['id']}/certificates")[1]["data"]]
        c, r = call("POST", "/v1/profiles", {"data": {"type": "profiles", "attributes": {"name": n + " 2", "profileType": ptype},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid}}, "certificates": {"data": [{"type": "certificates", "id": x} for x in certs]}}}})
        print(n + " 2", c, r.get("errors") or r["data"]["id"])
        if c == 201:
            open((n + " 2").replace(" ", "_") + ".provisionprofile", "wb").write(base64.b64decode(r["data"]["attributes"]["profileContent"]))
