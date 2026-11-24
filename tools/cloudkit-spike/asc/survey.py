# /// script
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
from lib import *
c,j = call("GET","/v1/bundleIds",limit=200,**{"filter[identifier]":"io.github.anthonytw.sempere"})
print(c,[(d["id"],d["attributes"]["identifier"],d["attributes"]["platform"]) for d in j.get("data",[])])
c,j = call("GET","/v1/bundleIds",limit=200)
for d in j["data"]: print(d["id"],d["attributes"]["identifier"],d["attributes"]["platform"])
for d in j["data"]:
    c,k = call("GET",f"/v1/bundleIds/{d['id']}/bundleIdCapabilities")
    print(d["attributes"]["identifier"],[x["attributes"]["capabilityType"] for x in k.get("data",[])])
c,j = call("GET","/v1/certificates",limit=200)
for d in j["data"]: a=d["attributes"]; print("cert",d["id"],a["certificateType"],a["displayName"],a["expirationDate"],a.get("platform"))
c,j = call("GET","/v1/devices",limit=200)
for d in j.get("data",[]): a=d["attributes"]; print("dev",d["id"],a["name"],a["platform"],a["deviceClass"],a["status"],a["udid"][:8])
c,j = call("GET","/v1/profiles",limit=200)
for d in j["data"]: a=d["attributes"]; print("prof",d["id"],a["name"],a["profileType"],a["profileState"],a["expirationDate"][:10])
