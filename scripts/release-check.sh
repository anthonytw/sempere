#!/usr/bin/env bash
# App Store release checks for the Xcode project (docs/release/app-store.md).
# Runs on Linux and macOS (bash + python3 only, no Xcode). Fails if:
#   - MARKETING_VERSION or CURRENT_PROJECT_VERSION differ between targets or
#     configurations (an extension's versions must equal its app's), or an
#     Info.plist hard-codes a different one;
#   - DEVELOPMENT_TEAM (or a TargetAttributes DevelopmentTeam) is set anywhere
#     under Apps/ (never commit the signing team);
#   - the app's or the widget extension's PrivacyInfo.xcprivacy is missing or
#     invalid, declares tracking or collected data, uses an unknown reason code,
#     or misses a required-reason API category its sources call;
#   - an entitlements file has a key outside the allow-list below, a referenced
#     entitlements file is missing, or the Mac build is not sandboxed;
#   - the Mac build would get its own bundle id (no universal purchase);
#   - ITSAppUsesNonExemptEncryption is missing from the app's Info.plist;
#   - the two copies of the privacy policy (docs/privacy, docs/appstore) differ in date;
#   - networking (URLSession, Network.framework, sockets, web views, CloudKit, …)
#     appears in a shipping app folder (every folder of Apps/Sempere but the test
#     targets) or a Sources/ target the app links, outside NETWORK_ALLOWED below
#     (the privacy policy names the only connections: a WebDAV server the user sets up);
#   - MathModelCatalog.entries is not empty: that turns the allowed model
#     downloader on, which the privacy documents say is inert;
#   - an object id is defined twice in project.pbxproj (two branches that each
#     picked the next free id merge cleanly into a project Xcode reads wrongly);
#   - a package pinned with an exact version in project.pbxproj resolves to
#     another version in the project's Package.resolved;
#   - with --checkouts: a third-party package (SwiftMath) uses networking, or a
#     required-reason API that neither its own manifest nor the app's declares.
#
# Usage: scripts/release-check.sh [--root DIR] [--list] [--checkouts DIR]
#   --root DIR       check another checkout (scripts/test-release-check.sh uses copies)
#   --list           also print every required-reason API use as file:line
#   --checkouts DIR  also scan the resolved third-party packages in DIR (Xcode's
#                    SourcePackages/checkouts; CI's app job passes it)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
list=0
checkouts=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="$(cd "$2" && pwd)"; shift 2 ;;
    --list) list=1; shift ;;
    --checkouts) checkouts="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

exec python3 -I - "$root" "$list" "$checkouts" <<'PY'
import os, plistlib, re, subprocess, sys, json

root, list_uses, checkouts = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
app_dir = os.path.join(root, "Apps", "Sempere")
pbxproj_path = os.path.join(app_dir, "Sempere.xcodeproj", "project.pbxproj")
errors, warnings = [], []

def rel(p):
    return os.path.relpath(p, root)

def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

# --- Policy -----------------------------------------------------------------

# Every entitlement the project may ship, and why (docs/release/app-store.md,
# "Entitlements"). Adding one is a deliberate change: update this list and the doc.
ENTITLEMENTS_ALLOWED = {
    "com.apple.security.app-sandbox",                    # required on the Mac App Store
    "com.apple.security.files.user-selected.read-write", # vault folders picked in the open panel
    "com.apple.security.files.bookmarks.app-scope",      # recent vaults across launches
    "com.apple.security.print",                          # printing the recovery kit
    "com.apple.security.device.audio-input",             # recording audio into notes
    "com.apple.security.application-groups",             # quick voice status for the widgets (iOS app + widget)
    "com.apple.security.network.client",                 # WebDAV vaults: connections to the user's own server (Mac)
}

# The only value an entitlement on the allow-list may take, where it has one.
ENTITLEMENT_VALUES = {
    "com.apple.security.application-groups": ["group.io.github.anthonytw.sempere"],
}

# Apple's approved reasons per required-reason API category (TN3183 /
# "Describing use of required reason API"). A code outside this table is a typo.
APPLE_REASONS = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {"3EC4.1", "54BD.1"},
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
}

# Calls that put a source file in a category (Swift and C spellings of the APIs
# Apple lists). Comment lines are skipped.
API_PATTERNS = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": re.compile(
        r"FileAttributeKey\.(creationDate|modificationDate)\b"
        r"|\[\s*\.(creationDate|modificationDate)\s*\]"
        r"|\.(creationDate|modificationDate)\s*:"
        r"|NSFile(Creation|Modification)Date"
        r"|\b(contentModificationDate|creationDate|contentAccessDate|attributeModificationDate)Key\b"
        r"|\.contentModificationDate\b|\bfileModificationDate\b"
        r"|(?<![.\w])[fl]?stat(at)?\s*\(|\b[fs]?(get|set)attrlist(bulk|at)?\s*\("),
    "NSPrivacyAccessedAPICategorySystemBootTime": re.compile(
        r"\bsystemUptime\b|\bmach_absolute_time\b|kern\.boottime"),
    "NSPrivacyAccessedAPICategoryDiskSpace": re.compile(
        r"\bvolume(Available|Total)Capacity\w*Key\b|NSFileSystem(Free|Size)\b|\.systemFreeSize\b"
        r"|\.systemSize\b|(?<![.\w])f?statv?fs\s*\(|attributesOfFileSystem"),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": re.compile(r"\bactiveInputModes\b"),
    "NSPrivacyAccessedAPICategoryUserDefaults": re.compile(r"\bUserDefaults\b|@AppStorage\b|NSUserDefaults"),
}

# Package products the app links, mapped to the Sources/ targets they compile
# (transitively, from Package.swift). A product missing here fails the check, so
# a new dependency cannot slip past the privacy scan.
PRODUCT_SOURCES = {
    "Age": ["Age"],
    "Sempere": ["Sempere", "Age", "CZlib"],
    "SempereRender": ["SempereRender", "Sempere", "SemperePDF", "Age", "CZlib"],
    "SempereSpeech": ["SempereSpeech", "Sempere", "Age", "CZlib"],
    # The app's import from other apps (`AppModel+Import`): the generic readers, and the Notability
    # importer (optional: docs/import-notability.md "Structure").
    "SempereImport": ["SempereImport", "Sempere", "SemperePDF", "SempereRender", "Age", "CZlib"],
    "SempereNotability": ["SempereNotability", "SempereImport", "Sempere", "SemperePDF", "SempereRender", "Age", "CZlib"],
    # WebDAV vaults (`AppModel+WebDAV`, docs/io.md "WebDAV vaults in the app").
    "SempereWebDAV": ["SempereWebDAV", "Sempere", "Age", "CZlib"],
    # Third-party (app only, never in Sources/): ships its own manifest if it needs one;
    # check the archive's privacy report (docs/release/app-store.md).
    "SwiftMath": [],
}

# Third-party packages: product -> checkout folder name under Xcode's SourcePackages/checkouts.
THIRD_PARTY = {"SwiftMath": "SwiftMath"}

# Networking in code (Swift and C spellings). The app connects only to a WebDAV server the
# user sets up (docs/appstore/privacy-policy.md, docs/release/app-store.md section 3); the
# files that may do so are NETWORK_ALLOWED below. Handing a URL to the
# system (openURL, Link) is not the app connecting, and is not matched.
NETWORK_PATTERN = re.compile(
    r"\bURLSession\w*\b|\bNSURLSession\w*\b|\bNSURLConnection\b|\bURLRequest\b|\bNSURLRequest\b"
    r"|^\s*(@\w+\s+)*import\s+(Network|CloudKit|MultipeerConnectivity|WebKit|SafariServices|AuthenticationServices"
    r"|NetworkExtension|FoundationNetworking)\b"
    r"|\bNW(Connection|Listener|Browser|PathMonitor|Endpoint|Parameters)\b|\bnw_\w+\s*\("
    r"|\bCK(Container|Database)\b|\bWKWebView\b|\bSFSafariViewController\b|\bASWebAuthenticationSession\b"
    r"|\bCF\w*Stream\w*Socket\w*\b|\bCFSocket\w*\b|\bCFNetwork\b"
    r"|(?<![.\w])(socket|getaddrinfo|gethostbyname|connect)\s*\(")

# The only shipping files that may contain networking, and why. Each is described in the
# privacy policy (both copies), docs/release/app-store.md and DESIGN.md "Network"; adding one
# means updating them in the same PR.
NETWORK_ALLOWED = {
    # WebDAV vaults (docs/io.md "WebDAV vaults in the app"): connections only to the server the user
    # enters, uploading the already encrypted vault (push-only); the privacy policy says so.
    "Apps/Sempere/SempereApp/WebDAVRemote.swift",
    "Sources/SempereWebDAV/Transport.swift",
    "Sources/SempereWebDAV/WebDAVClient.swift",
    # The handwritten-math model downloader (URLSessionModelFetcher): runs only when the user
    # taps Download on a MathModelCatalog entry, and the catalogue is empty (checked below).
    "Apps/Sempere/SempereApp/MathModels.swift",
}

# Where the downloader's catalogue lives; it must stay empty while the documents say the
# downloader is inert (docs/release/app-store.md section 3).
MATH_CATALOG = ("Sources/SempereRender/MathModel.swift",
                re.compile(r"public\s+static\s+let\s+entries\s*:\s*\[MathModelCatalogEntry\]\s*=\s*\[\s*\]"))

# Targets that ship (the bundle the user installs), their source folders and privacy manifest.
SHIPPING = {
    "SempereApp": {"dirs": ["SempereApp", "SempereShared"],
                   "manifest": "SempereApp/PrivacyInfo.xcprivacy"},
    "SempereWidgets": {"dirs": ["SempereWidgets", "SempereShared"],
                       "manifest": "SempereWidgets/PrivacyInfo.xcprivacy"},
}

# --- Project file --------------------------------------------------------------

if not os.path.isfile(pbxproj_path):
    print(f"error: {rel(pbxproj_path)} not found", file=sys.stderr)
    sys.exit(1)
pbx = read(pbxproj_path)

def setting_values(name):
    # `NAME = value;` and `"NAME[sdk=...]" = value;`
    pat = re.compile(r'^\s*"?' + re.escape(name) + r'(\[[^\]]*\])?"?\s*=\s*(.*?);\s*$', re.M)
    return [m.group(2).strip().strip('"') for m in pat.finditer(pbx)]

# Objects are the entries two tabs deep (`\t\tID /* name */ = {`); a duplicate is a silent clash (one
# definition wins, the other's references now point at it), which plutil does not report.
object_ids = re.findall(r'^\t\t([0-9A-F]{24})\b[^\n]*= \{', pbx, re.M)
for dup in sorted({i for i in object_ids if object_ids.count(i) > 1}):
    errors.append(f"object id {dup} is defined more than once in project.pbxproj; give one of them a new id")

for name in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
    vals = setting_values(name)
    if not vals:
        errors.append(f"{name} is not set in project.pbxproj")
    elif len(set(vals)) != 1:
        errors.append(f"{name} differs between targets/configurations: {sorted(set(vals))} "
                      "(an extension's version must equal its app's)")
marketing = (setting_values("MARKETING_VERSION") or [None])[0]
build = (setting_values("CURRENT_PROJECT_VERSION") or [None])[0]
if marketing and not re.fullmatch(r"\d+(\.\d+){0,2}", marketing):
    errors.append(f"MARKETING_VERSION {marketing!r} is not 1 to 3 dot-separated integers")
if build and not re.fullmatch(r"\d+(\.\d+){0,2}", build):
    errors.append(f"CURRENT_PROJECT_VERSION {build!r} is not 1 to 3 dot-separated integers")

# Signing team: never committed (docs/HANDOFF.md). Scan every text file under Apps/.
team_pat = re.compile(r'(DEVELOPMENT_TEAM(\[[^\]]*\])?"?\s*=\s*"?([^";\s]+)|DevelopmentTeam\s*=\s*"?([^";\s]+))')
for dirpath, dirnames, filenames in os.walk(app_dir):
    dirnames[:] = [d for d in dirnames if d not in ("xcuserdata", ".build", "build", "DerivedData")]
    for fn in filenames:
        if not fn.endswith((".pbxproj", ".xcconfig", ".xcscheme", ".plist", ".entitlements", ".xcworkspacedata")):
            continue
        p = os.path.join(dirpath, fn)
        try:
            text = read(p)
        except UnicodeDecodeError:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            m = team_pat.search(line)
            if m and (m.group(3) or m.group(4)) not in ('""', ""):
                errors.append(f"{rel(p)}:{i}: signing team is set ({line.strip()}); never commit DEVELOPMENT_TEAM")

# Universal purchase: the Catalyst build must keep the iOS bundle id.
for v in setting_values("DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER"):
    if v.upper() == "YES":
        errors.append("DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = YES gives the Mac build its own "
                      "bundle id (maccatalyst.…), which breaks universal purchase")
ids = set(setting_values("PRODUCT_BUNDLE_IDENTIFIER"))
app_id = "io.github.anthonytw.sempere"
if app_id not in ids:
    errors.append(f"the app's PRODUCT_BUNDLE_IDENTIFIER {app_id} is gone (it cannot change after the first upload)")
for v in setting_values("PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*]"):
    if v != app_id:
        errors.append(f"the Mac build overrides the bundle id ({v}); universal purchase needs {app_id}")
for i in ids:
    if i != app_id and not i.startswith(app_id + "."):
        errors.append(f"bundle id {i} is not under {app_id} (extensions must be prefixed by the app's id)")

# Package products linked by any target.
products = set(re.findall(r"isa = XCSwiftPackageProductDependency;[^}]*?productName = (\w+);", pbx, re.S))
for p in sorted(products - set(PRODUCT_SOURCES)):
    errors.append(f"package product {p} is linked but not in PRODUCT_SOURCES of scripts/release-check.sh: "
                  "add it (and check its privacy manifest)")

def target_products(target):
    m = re.search(r"/\* " + re.escape(target) + r" \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};", pbx, re.S)
    if not m:
        return None
    block = m.group(1)
    deps = re.search(r"packageProductDependencies = \((.*?)\);", block, re.S)
    return set(re.findall(r"/\* (\w+) \*/", deps.group(1))) if deps else set()

# --- Info.plist ------------------------------------------------------------------

info_path = os.path.join(app_dir, "SempereInfo.plist")
for path in (info_path, os.path.join(app_dir, "SempereWidgetsInfo.plist")):
    try:
        with open(path, "rb") as f:
            info = plistlib.load(f)
    except Exception as e:
        errors.append(f"{rel(path)}: not a valid plist ({e})")
        continue
    for key, want in (("CFBundleShortVersionString", marketing), ("CFBundleVersion", build)):
        v = info.get(key)
        if v is not None and v not in ("$(MARKETING_VERSION)", "$(CURRENT_PROJECT_VERSION)") and v != want:
            errors.append(f"{rel(path)}: {key} = {v!r} disagrees with the build setting ({want!r})")
    if path == info_path:
        enc = info.get("ITSAppUsesNonExemptEncryption")
        if not isinstance(enc, bool):
            errors.append(f"{rel(path)}: ITSAppUsesNonExemptEncryption must be a boolean "
                          "(docs/release/export-compliance.md)")
        if enc is True and "ITSEncryptionExportComplianceCode" not in info:
            warnings.append(f"{rel(path)}: ITSAppUsesNonExemptEncryption is YES without "
                            "ITSEncryptionExportComplianceCode: every build will ask the encryption questions")

# --- Entitlements ---------------------------------------------------------------

ent_files = set()
for dirpath, dirnames, filenames in os.walk(app_dir):
    for fn in filenames:
        if fn.endswith(".entitlements"):
            ent_files.add(os.path.join(dirpath, fn))
for v in setting_values("CODE_SIGN_ENTITLEMENTS"):
    p = os.path.join(app_dir, v)
    if not os.path.isfile(p):
        errors.append(f"CODE_SIGN_ENTITLEMENTS names {v}, which does not exist")
    ent_files.add(p)
mac_ents = set(setting_values("CODE_SIGN_ENTITLEMENTS[sdk=macosx*]"))
for p in sorted(ent_files):
    if not os.path.isfile(p):
        continue
    try:
        with open(p, "rb") as f:
            ents = plistlib.load(f)
    except Exception as e:
        errors.append(f"{rel(p)}: not a valid plist ({e})")
        continue
    for k, want in ENTITLEMENT_VALUES.items():
        if k in ents and ents[k] != want:
            errors.append(f"{rel(p)}: {k} must be exactly {want} (docs/release/app-store.md \"Entitlements\")")
    for k in sorted(set(ents) - ENTITLEMENTS_ALLOWED):
        errors.append(f"{rel(p)}: entitlement {k} is not in the allow-list (scripts/release-check.sh, "
                      "docs/release/app-store.md \"Entitlements\")")
    if os.path.relpath(p, app_dir) in mac_ents and ents.get("com.apple.security.app-sandbox") is not True:
        errors.append(f"{rel(p)}: the Mac build must set com.apple.security.app-sandbox to true")
if not mac_ents:
    errors.append("no CODE_SIGN_ENTITLEMENTS[sdk=macosx*]: the Mac Catalyst build would not be sandboxed")

# --- Privacy manifests and required-reason APIs ------------------------------------

def scan(dirs):
    uses = {c: [] for c in API_PATTERNS}
    for d in dirs:
        for dirpath, dirnames, filenames in os.walk(d):
            dirnames.sort()
            for fn in sorted(filenames):
                if not fn.endswith((".swift", ".c", ".h", ".m")):
                    continue
                p = os.path.join(dirpath, fn)
                for i, line in enumerate(read(p).splitlines(), 1):
                    code = line.split("//", 1)[0]
                    if not code.strip() or code.lstrip().startswith("*"):
                        continue
                    for c, pat in API_PATTERNS.items():
                        if pat.search(code):
                            uses[c].append(f"{rel(p)}:{i}")
    return uses

declared_by_target = {}
for target, spec in SHIPPING.items():
    linked = target_products(target)
    if linked is None:
        errors.append(f"target {target} not found in project.pbxproj")
        continue
    dirs = [os.path.join(app_dir, d) for d in spec["dirs"]]
    for prod in sorted(linked):
        dirs += [os.path.join(root, "Sources", s) for s in PRODUCT_SOURCES.get(prod, [])]
    uses = scan(sorted(set(dirs)))
    mpath = os.path.join(app_dir, spec["manifest"])
    if not os.path.isfile(mpath):
        errors.append(f"{rel(mpath)} is missing (privacy manifest of {target})")
        continue
    try:
        with open(mpath, "rb") as f:
            man = plistlib.load(f)
    except Exception as e:
        errors.append(f"{rel(mpath)}: not a valid plist ({e})")
        continue
    if man.get("NSPrivacyTracking") is not False:
        errors.append(f"{rel(mpath)}: NSPrivacyTracking must be false")
    if man.get("NSPrivacyTrackingDomains", []) != []:
        errors.append(f"{rel(mpath)}: NSPrivacyTrackingDomains must be empty")
    if man.get("NSPrivacyCollectedDataTypes") != []:
        errors.append(f"{rel(mpath)}: NSPrivacyCollectedDataTypes must be an empty array (\"Data Not Collected\")")
    declared = {}
    for entry in man.get("NSPrivacyAccessedAPITypes", []):
        cat = entry.get("NSPrivacyAccessedAPIType")
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons", [])
        if cat not in APPLE_REASONS:
            errors.append(f"{rel(mpath)}: unknown API category {cat!r}")
            continue
        if not reasons:
            errors.append(f"{rel(mpath)}: {cat} has no reason")
        for r in reasons:
            if r not in APPLE_REASONS[cat]:
                errors.append(f"{rel(mpath)}: {cat} reason {r!r} is not one of Apple's ({sorted(APPLE_REASONS[cat])})")
        declared[cat] = reasons
    declared_by_target[target] = declared
    for cat, where in uses.items():
        if where and cat not in declared:
            errors.append(f"{target} uses {cat} ({where[0]}{' and %d more' % (len(where) - 1) if len(where) > 1 else ''}) "
                          f"but {rel(mpath)} does not declare it")
        if not where and cat in declared:
            warnings.append(f"{rel(mpath)} declares {cat}, but no use was found in {target}'s sources "
                            "(dependencies and Apple frameworks are not scanned)")
    if list_uses:
        print(f"== {target} ({', '.join(rel(d) for d in sorted(set(dirs)))})")
        for cat, where in uses.items():
            for w in where:
                print(f"{cat.replace('NSPrivacyAccessedAPICategory', '')}\t{w}")

# --- Networking ------------------------------------------------------------------------

def code_lines(p):
    for i, line in enumerate(read(p).splitlines(), 1):
        code = line.split("//", 1)[0]
        if code.strip() and not code.lstrip().startswith("*"):
            yield i, code

def network_uses(dirs):
    found = []
    for d in dirs:
        for dirpath, dirnames, filenames in os.walk(d):
            dirnames.sort()
            for fn in sorted(filenames):
                if fn.endswith((".swift", ".c", ".h", ".m", ".mm", ".cpp")):
                    p = os.path.join(dirpath, fn)
                    found += [(p, i) for i, code in code_lines(p) if NETWORK_PATTERN.search(code)]
    return found

# Every folder of Apps/Sempere except the test targets ships or may ship: a new folder is
# scanned without anyone remembering to add it. Plus the Sources/ targets any target links.
shipping_dirs = [os.path.join(app_dir, d) for d in sorted(os.listdir(app_dir))
                 if os.path.isdir(os.path.join(app_dir, d)) and not d.endswith(("Tests", ".xcodeproj"))]
for prod in sorted(products):
    shipping_dirs += [os.path.join(root, "Sources", s) for s in PRODUCT_SOURCES.get(prod, [])]
net = network_uses(sorted(set(shipping_dirs)))
for p, i in net:
    if rel(p) not in NETWORK_ALLOWED:
        errors.append(f"{rel(p)}:{i}: networking in the shipping app; the privacy policy names the only "
                      "connections the app makes (NETWORK_ALLOWED in scripts/release-check.sh, docs/release/app-store.md "
                      "section 3)")
for allowed in sorted(NETWORK_ALLOWED - {rel(p) for p, _ in net}):
    warnings.append(f"{allowed} is in NETWORK_ALLOWED but has no networking (left over? update the privacy documents)")

cat_path = os.path.join(root, MATH_CATALOG[0])
if not os.path.isfile(cat_path) or not MATH_CATALOG[1].search(read(cat_path)):
    errors.append(f"{MATH_CATALOG[0]}: MathModelCatalog.entries is not `[]`: that makes the model downloader reachable, "
                  "which the privacy policy (both copies), docs/release/app-store.md and DESIGN.md call inert. Update "
                  "them, add com.apple.security.network.client to the Mac entitlements and its allow-list, then this rule")

# --- Package pins: an exact version in the project resolves to that version -------------

resolved_path = os.path.join(app_dir, "Sempere.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm",
                             "Package.resolved")
def repo_key(url):
    return re.sub(r"(\.git)?/?$", "", url.strip().lower())
pins = {}
try:
    for pin in json.loads(read(resolved_path)).get("pins", []):
        pins[repo_key(pin.get("location", ""))] = pin
except FileNotFoundError:
    errors.append(f"{rel(resolved_path)} is missing: the app's package versions are not pinned")
except Exception as e:
    errors.append(f"{rel(resolved_path)}: not valid JSON ({e})")
remote_refs = re.findall(r"isa = XCRemoteSwiftPackageReference;\s*repositoryURL = \"([^\"]+)\";\s*"
                         r"requirement = \{(.*?)\};", pbx, re.S)
for url, req in remote_refs:
    kind = re.search(r"kind = (\w+);", req)
    version = re.search(r"version = ([\w.\-]+);", req)
    if not kind or kind.group(1) != "exactVersion" or not version:
        continue
    pin = pins.get(repo_key(url))
    got = (pin or {}).get("state", {}).get("version")
    if pins and got != version.group(1):
        errors.append(f"{url} is pinned to exactly {version.group(1)} in project.pbxproj but "
                      f"{rel(resolved_path)} resolves {got or 'nothing'}")

# --- Third-party checkouts (--checkouts): no networking, required-reason APIs declared ---

if checkouts:
    app_declared = declared_by_target.get("SempereApp", {})
    for prod, folder in sorted(THIRD_PARTY.items()):
        if prod not in products:
            continue
        match = [d for d in os.listdir(checkouts) if d.lower() == folder.lower()]
        if not match:
            errors.append(f"--checkouts {checkouts}: no {folder} checkout (resolve the app's packages first)")
            continue
        base = os.path.join(checkouts, match[0])
        src = [os.path.join(base, d) for d in sorted(os.listdir(base))
               if os.path.isdir(os.path.join(base, d)) and not d.startswith(".") and "test" not in d.lower()]
        for p, i in network_uses(src):
            errors.append(f"{prod}: {os.path.relpath(p, checkouts)}:{i}: networking in a third-party package the app links")
        manifests = []
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            manifests += [os.path.join(dirpath, f) for f in filenames if f.endswith(".xcprivacy")]
        own = {}
        for m in manifests:
            try:
                with open(m, "rb") as f:
                    man = plistlib.load(f)
            except Exception as e:
                errors.append(f"{prod}: {os.path.relpath(m, checkouts)} is not a valid plist ({e})")
                continue
            if man.get("NSPrivacyTracking") is True or man.get("NSPrivacyCollectedDataTypes"):
                errors.append(f"{prod}: {os.path.relpath(m, checkouts)} declares tracking or collected data")
            for entry in man.get("NSPrivacyAccessedAPITypes", []):
                own[entry.get("NSPrivacyAccessedAPIType")] = entry.get("NSPrivacyAccessedAPITypeReasons", [])
        used = scan(src)
        for cat, where in used.items():
            # Linked statically into the app binary, so the app's manifest covers it too.
            if where and cat not in own and cat not in app_declared:
                errors.append(f"{prod} uses {cat} ({os.path.relpath(where[0], root) if where[0].startswith(root) else where[0]}) "
                              "and neither its manifest nor SempereApp/PrivacyInfo.xcprivacy declares it")
        pin = pins.get(repo_key(next((u for u, _ in remote_refs if repo_key(u).endswith("/" + folder.lower())), "")), {})
        want = pin.get("state", {}).get("revision")
        head = None
        try:
            head = subprocess.run(["git", "-C", base, "rev-parse", "HEAD"], capture_output=True, text=True,
                                  timeout=30).stdout.strip() or None
        except Exception:
            pass
        if want and head and head != want:
            errors.append(f"{prod}: checkout is at {head}, Package.resolved pins {want}")
        uses_list = sorted(c.replace("NSPrivacyAccessedAPICategory", "") for c, w in used.items() if w)
        print(f"{prod} ({pin.get('state', {}).get('version', '?')}, {head or 'revision unknown'}): "
              f"privacy manifest {'present: ' + ', '.join(os.path.relpath(m, base) for m in manifests) if manifests else 'absent'}; "
              f"required-reason APIs: {', '.join(uses_list) or 'none'}; networking: "
              f"{'see errors' if network_uses(src) else 'none'}")

# --- Privacy policy: the Pages copy and the Markdown copy carry the same date ----------

policy_dates = {}
for p in ("docs/privacy/index.html", "docs/appstore/privacy-policy.md"):
    path = os.path.join(root, p)
    if not os.path.isfile(path):
        errors.append(f"{p} is missing (the privacy policy, docs/release/app-store.md section 5)")
        continue
    m = re.search(r"Last updated:\s*(?:<[^>]*>)?\s*(\d{4}-\d{2}-\d{2})", read(path))
    if not m:
        errors.append(f"{p}: no \"Last updated: YYYY-MM-DD\"")
        continue
    policy_dates[p] = m.group(1)
if len(set(policy_dates.values())) > 1:
    errors.append(f"the two privacy policy copies differ in date ({policy_dates}): edit both")

for w in warnings:
    print(f"warning: {w}", file=sys.stderr)
for e in errors:
    print(f"error: {e}", file=sys.stderr)
if errors:
    print(f"release-check: {len(errors)} problem(s)", file=sys.stderr)
    sys.exit(1)
print(f"release-check: ok (version {marketing}, build {build})")
PY
