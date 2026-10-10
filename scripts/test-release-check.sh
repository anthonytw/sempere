#!/usr/bin/env bash
# Tests for scripts/release-check.sh: the real tree passes, and each mutation of a
# copy of the files it reads makes it fail (or warn) with the expected message.
# Runs on Linux and macOS (bash + python3); CI runs it in the `release` job.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
check="$here/scripts/release-check.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

# A copy of what release-check reads: Apps/Sempere (sources, plists, project) and the
# Sources/ targets the app links, plus the two privacy policy copies.
fresh() {
  rm -rf "$tmp/root" && mkdir -p "$tmp/root/Apps" "$tmp/root/Sources" "$tmp/root/docs/appstore" "$tmp/root/docs/privacy"
  cp -R "$here/Apps/Sempere" "$tmp/root/Apps/"
  for t in Age Sempere SempereRender SemperePDF SempereSpeech SempereWebDAV CZlib; do cp -R "$here/Sources/$t" "$tmp/root/Sources/"; done
  cp "$here/docs/appstore/privacy-policy.md" "$tmp/root/docs/appstore/"
  cp "$here/docs/privacy/index.html" "$tmp/root/docs/privacy/"
}
pbx="Apps/Sempere/Sempere.xcodeproj/project.pbxproj"

# edit FILE PYTHON-EXPR: rewrites FILE (relative to the copy) as expr(s).
edit() { python3 -I -c 'import sys; p=sys.argv[1]; s=open(p).read(); exec("s="+sys.argv[2]); open(p,"w").write(s)' "$tmp/root/$1" "$2"; }

# expect NAME ok|fail|warn [PATTERN]: runs the check on the copy (with the arguments in $extra, if any).
extra=()
expect() {
  local name="$1" want="$2" pattern="${3:-}" out code=0
  out="$("$check" --root "$tmp/root" ${extra[@]+"${extra[@]}"} 2>&1)" || code=$?
  local ok=1
  case "$want" in
    ok) [ "$code" -eq 0 ] || ok=0 ;;
    fail) [ "$code" -ne 0 ] || ok=0 ;;
    warn) { [ "$code" -eq 0 ] && grep -q '^warning:' <<<"$out"; } || ok=0 ;;
  esac
  if [ "$ok" -eq 1 ] && [ -n "$pattern" ] && ! grep -qE -- "$pattern" <<<"$out"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name (exit $code, want $want${pattern:+ matching /$pattern/})"; sed 's/^/     /' <<<"$out"; fi
}

fresh; expect "the committed tree passes" ok "release-check: ok"
"$check" --root "$tmp/root" --list | grep -q $'^FileTimestamp\tSources/Sempere/FileIO.swift:' \
  && { pass=$((pass + 1)); echo "ok   --list names file:line"; } \
  || { fail=$((fail + 1)); echo "FAIL --list names file:line"; }

fresh; edit "$pbx" 's.replace("A1000000000000000000B008 /* SempereImport in Frameworks */ = {", "A1000000000000000000B008 /* Other in Frameworks */ = {isa = PBXBuildFile; };\n\t\tA1000000000000000000B008 /* SempereImport in Frameworks */ = {", 1)'
expect "an object id defined twice (two merged branches)" fail "object id A1000000000000000000B008 is defined more than once"

fresh; edit "$pbx" 's.replace("MARKETING_VERSION = 0.1;", "MARKETING_VERSION = 0.2;", 1)'
expect "marketing version mismatch" fail "MARKETING_VERSION differs"

fresh; edit "$pbx" 's[::-1].replace(";1 = NOISREV_TCEJORP_TNERRUC", ";2 = NOISREV_TCEJORP_TNERRUC", 1)[::-1]'
expect "build number mismatch (the widget's)" fail "CURRENT_PROJECT_VERSION differs"

fresh; edit "$pbx" 's.replace("MARKETING_VERSION = 0.1;", "MARKETING_VERSION = beta;")'
expect "non-numeric version" fail "not 1 to 3 dot-separated integers"

fresh; edit "Apps/Sempere/SempereWidgetsInfo.plist" 's.replace("<dict>\n", "<dict>\n\t<key>CFBundleVersion</key>\n\t<string>7</string>\n", 1)'
expect "Info.plist hard-codes another build number" fail "CFBundleVersion = '7'"

fresh; edit "$pbx" 's.replace("CURRENT_PROJECT_VERSION = 1;", "CURRENT_PROJECT_VERSION = 1;\n\t\t\t\tDEVELOPMENT_TEAM = ABCDE12345;", 1)'
expect "DEVELOPMENT_TEAM set" fail "signing team is set"

fresh; edit "$pbx" 's.replace("CreatedOnToolsVersion = 26.0;", "CreatedOnToolsVersion = 26.0;\n\t\t\t\t\t\tDevelopmentTeam = ABCDE12345;", 1)'
expect "DevelopmentTeam target attribute set" fail "signing team is set"

fresh; edit "$pbx" 's.replace("CURRENT_PROJECT_VERSION = 1;", "CURRENT_PROJECT_VERSION = 1;\n\t\t\t\tDEVELOPMENT_TEAM = \"\";", 1)'
expect "empty DEVELOPMENT_TEAM is fine" ok

fresh; rm "$tmp/root/Apps/Sempere/SempereWidgets/PrivacyInfo.xcprivacy"
expect "widget privacy manifest missing" fail "SempereWidgets/PrivacyInfo.xcprivacy is missing"

fresh; rm "$tmp/root/Apps/Sempere/SempereApp/PrivacyInfo.xcprivacy"
expect "app privacy manifest missing" fail "SempereApp/PrivacyInfo.xcprivacy is missing"

fresh; edit "Apps/Sempere/SempereApp/PrivacyInfo.xcprivacy" 's.replace("<string>CA92.1</string>", "<string>CA92.2</string>")'
expect "unknown reason code" fail "reason 'CA92.2' is not one of Apple's"

fresh; edit "Apps/Sempere/SempereApp/PrivacyInfo.xcprivacy" 's.replace("<key>NSPrivacyTracking</key>\n\t<false/>", "<key>NSPrivacyTracking</key>\n\t<true/>")'
expect "tracking on" fail "NSPrivacyTracking must be false"

fresh; edit "Apps/Sempere/SempereApp/PrivacyInfo.xcprivacy" 's.replace("NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPICategoryDiskSpace").replace("<string>CA92.1</string>", "<string>E174.1</string>")'
expect "used category undeclared (UserDefaults)" fail "uses NSPrivacyAccessedAPICategoryUserDefaults .* does not declare it"

fresh; printf 'import Foundation\nlet up = ProcessInfo.processInfo.systemUptime\n' > "$tmp/root/Apps/Sempere/SempereWidgets/Uptime.swift"
expect "widget starts using boot time" fail "SempereWidgets uses NSPrivacyAccessedAPICategorySystemBootTime"

fresh; printf 'import Foundation\n// mach_absolute_time() in a comment does not count\n' > "$tmp/root/Sources/Sempere/Note.swift"
expect "API names in comments are ignored" ok

fresh; printf 'import Foundation\nlet t = mach_absolute_time()\n' > "$tmp/root/Sources/SempereRender/Clock.swift"
expect "a linked package target counts for the app" fail "SempereApp uses NSPrivacyAccessedAPICategorySystemBootTime"

fresh; edit "$pbx" 's.replace("productName = SwiftMath;", "productName = Mystery;")'
expect "unknown package product" fail "package product Mystery is linked but not in PRODUCT_SOURCES"

fresh; edit "Apps/Sempere/Sempere.entitlements" 's.replace("</dict>", "\t<key>com.apple.security.device.camera</key>\n\t<true/>\n</dict>")'
expect "entitlement outside the allow-list" fail "com.apple.security.device.camera is not in the allow-list"

fresh; edit "Apps/Sempere/SempereWidgets.entitlements" 's.replace("group.io.github.anthonytw.sempere", "group.io.github.other")'
expect "App Group other than the app's own" fail "application-groups must be exactly"

fresh; edit "Apps/Sempere/SempereiOS.entitlements" 's.replace("<string>group.io.github.anthonytw.sempere</string>", "<string>group.io.github.anthonytw.sempere</string>\n\t\t<string>group.io.github.anthonytw.extra</string>")'
expect "a second App Group" fail "application-groups must be exactly"

fresh; edit "Apps/Sempere/Sempere.entitlements" 's.replace("<key>com.apple.security.app-sandbox</key>\n\t<true/>", "<key>com.apple.security.app-sandbox</key>\n\t<false/>")'
expect "Mac build not sandboxed" fail "must set com.apple.security.app-sandbox to true"

fresh; printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>com.apple.developer.icloud-services</key><array/></dict></plist>\n' > "$tmp/root/Apps/Sempere/SempereWidgets/Extra.entitlements"
expect "stray entitlements file is checked too" fail "Extra.entitlements: entitlement com.apple.developer.icloud-services"

fresh; edit "$pbx" 's.replace("Sempere.entitlements;", "Missing.entitlements;", 1)'
expect "referenced entitlements file missing" fail "names Missing.entitlements, which does not exist"

fresh; edit "$pbx" 's.replace("SUPPORTS_MACCATALYST = YES;", "SUPPORTS_MACCATALYST = YES;\n\t\t\t\tDERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = YES;", 1)'
expect "derived Mac bundle id" fail "breaks universal purchase"

fresh; edit "$pbx" 's.replace("PRODUCT_BUNDLE_IDENTIFIER = io.github.anthonytw.sempere.widgets;", "PRODUCT_BUNDLE_IDENTIFIER = io.github.other.widgets;")'
expect "extension id not under the app's" fail "is not under io.github.anthonytw.sempere"

fresh; edit "Apps/Sempere/SempereInfo.plist" 's.replace("<key>ITSAppUsesNonExemptEncryption</key>\n\t<false/>", "")'
expect "encryption key missing" fail "ITSAppUsesNonExemptEncryption must be a boolean"

fresh; edit "Apps/Sempere/SempereInfo.plist" 's.replace("<key>ITSAppUsesNonExemptEncryption</key>\n\t<false/>", "<key>ITSAppUsesNonExemptEncryption</key>\n\t<true/>")'
expect "YES without a compliance code warns" warn "without ITSEncryptionExportComplianceCode"

fresh; edit "docs/privacy/index.html" 're.sub(r"\d{4}-\d{2}-\d{2}</span>", "2099-01-01</span>", s) if (re:=__import__("re")) else s'
expect "privacy policy copies out of date" fail "privacy policy copies differ in date"

# Networking: only the allow-listed model downloader, and only while its catalogue is empty.
fresh; printf 'import Foundation\nfunc ping() { URLSession.shared.dataTask(with: URL(fileURLWithPath: "/")).resume() }\n' > "$tmp/root/Apps/Sempere/SempereApp/Ping.swift"
expect "URLSession outside the allow-list" fail "SempereApp/Ping.swift:2: networking in the shipping app"

fresh; printf 'import Network\n' > "$tmp/root/Apps/Sempere/SempereShared/Reach.swift"
expect "Network.framework in the shared intents" fail "SempereShared/Reach.swift:1: networking"

fresh; printf 'import WebKit\n' > "$tmp/root/Apps/Sempere/SempereWidgets/Web.swift"
expect "WebKit in the widget" fail "SempereWidgets/Web.swift:1: networking"

fresh; mkdir -p "$tmp/root/Apps/Sempere/NewFolder" && printf 'let fd = socket(2, 1, 0)\n' > "$tmp/root/Apps/Sempere/NewFolder/Raw.c"
expect "a new app folder is scanned too" fail "NewFolder/Raw.c:1: networking"

fresh; printf 'import Foundation\nlet r = URLRequest(url: URL(fileURLWithPath: "/"))\n' > "$tmp/root/Sources/SempereRender/Fetch.swift"
expect "a linked package target counts for networking" fail "Sources/SempereRender/Fetch.swift:2: networking"

fresh; printf 'import Foundation\n// URLSession in a comment\nlet s = "x".connect\nfunc f() { open(URL(string: "https://example.com")!) }\n' > "$tmp/root/Apps/Sempere/SempereApp/Words.swift"
expect "comments, methods named connect and handing a URL to the system are not networking" ok

fresh; printf 'import Foundation\nlet s = URLSession.shared\n' > "$tmp/root/Apps/Sempere/SempereAppTests/Stub.swift"
expect "test targets may use URLSession" ok

fresh; edit "Apps/Sempere/SempereApp/MathModels.swift" '__import__("re").sub(r"\bURL(Session|Request)", r"Plain\1", s)'
expect "an allow-listed file without networking warns" warn "MathModels.swift is in NETWORK_ALLOWED but has no networking"

fresh; edit "Sources/SempereRender/MathModel.swift" 's.replace("entries: [MathModelCatalogEntry] = []", "entries: [MathModelCatalogEntry] = [MathModelCatalogEntry(id: \"m\", name: \"M\", manifestURL: \"https://example.com/m/manifest.json\", manifestSHA256: \"00\", downloadBytes: 1, licence: \"x\")]")'
expect "a model in the catalogue turns the downloader on" fail "MathModelCatalog.entries is not"

# The app's package pins.
fresh; edit "Apps/Sempere/Sempere.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" 's.replace("\"version\" : \"1.7.3\"", "\"version\" : \"1.7.4\"", 1)'
expect "exact version resolved to another" fail "pinned to exactly 1.7.3 in project.pbxproj but .* resolves 1.7.4"

fresh; rm "$tmp/root/Apps/Sempere/Sempere.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
expect "the app's Package.resolved missing" fail "Package.resolved is missing"

# Third-party checkouts (--checkouts): a fake SwiftMath.
checkout() {
  rm -rf "$tmp/co" && mkdir -p "$tmp/co/SwiftMath/Sources/SwiftMath" "$tmp/co/SwiftMath/Tests/SwiftMathTests"
  printf 'import Foundation\nlet d = UserDefaults.standard\n' > "$tmp/co/SwiftMath/Sources/SwiftMath/Fonts.swift"
  printf 'import Foundation\nlet s = URLSession.shared\nlet t = mach_absolute_time()\n' > "$tmp/co/SwiftMath/Tests/SwiftMathTests/T.swift"
}
fresh; checkout; extra=(--checkouts "$tmp/co")
expect "a checkout whose API use the app declares, tests ignored" ok "SwiftMath \(1.7.3, revision unknown\): privacy manifest absent; required-reason APIs: UserDefaults; networking: none"

fresh; checkout; printf 'import Foundation\nlet t = ProcessInfo.processInfo.systemUptime\n' > "$tmp/co/SwiftMath/Sources/SwiftMath/Clock.swift"
expect "a checkout using an undeclared category" fail "SwiftMath uses NSPrivacyAccessedAPICategorySystemBootTime"

fresh; checkout; printf 'import Foundation\nlet t = ProcessInfo.processInfo.systemUptime\n' > "$tmp/co/SwiftMath/Sources/SwiftMath/Clock.swift"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>NSPrivacyTracking</key><false/><key>NSPrivacyCollectedDataTypes</key><array/><key>NSPrivacyAccessedAPITypes</key><array><dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategorySystemBootTime</string><key>NSPrivacyAccessedAPITypeReasons</key><array><string>35F9.1</string></array></dict></array></dict></plist>\n' > "$tmp/co/SwiftMath/Sources/SwiftMath/PrivacyInfo.xcprivacy"
expect "a checkout declaring its own category" ok "privacy manifest present: Sources/SwiftMath/PrivacyInfo.xcprivacy"

fresh; checkout; printf 'import Foundation\nlet s = URLSession.shared\n' > "$tmp/co/SwiftMath/Sources/SwiftMath/Net.swift"
expect "a checkout with networking" fail "SwiftMath: SwiftMath/Sources/SwiftMath/Net.swift:2: networking"

fresh; rm -rf "$tmp/co" && mkdir -p "$tmp/co"
expect "no SwiftMath checkout" fail "no SwiftMath checkout"
extra=()

echo "release-check tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
