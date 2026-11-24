import os, time, json, jwt, requests
env = {}
for l in open(os.path.expanduser("~/.config/sempere/release.env")):
    l = l.strip()
    if l and not l.startswith("#") and "=" in l:
        k, v = l.split("=", 1); env[k] = v.strip().strip('"')
key = open(os.path.expanduser(env["SEMPERE_ASC_KEY_PATH"])).read()
tok = jwt.encode({"iss": env["SEMPERE_ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 1200, "aud": "appstoreconnect-v1"}, key, algorithm="ES256", headers={"kid": env["SEMPERE_ASC_KEY_ID"], "typ": "JWT"})
S = requests.Session(); S.headers["Authorization"] = "Bearer " + tok
B = "https://api.appstoreconnect.apple.com"
def call(m, p, body=None, **q):
    r = S.request(m, B + p if p.startswith("/") else p, json=body, params=q)
    try: j = r.json()
    except Exception: j = {"raw": r.text[:500]}
    return r.status_code, j
