#!/bin/bash
# Build the throwaway CloudKit probe (docs/design/1.4-cloudkit.md §12, C0). Run it through the build lock:
#   ~/.claude/scripts/xc-lock.sh tools/cloudkit-spike/build.sh catalyst|sim|cli [OUTDIR]
# catalyst: Mac Catalyst app, signed with the Apple Development cert + a development profile (bundle id of the app)
# sim:      iOS simulator app, ad-hoc signed with the entitlements (the simulator ignores profiles)
# cli:      a plain macOS executable inside sempere.app (the §6.5 shape); CLI_PROFILE=<file> embeds a profile,
#           CLI_BUNDLE_ID=<id> sets the bundle id (default: the app's, to use the app's development profile)
# Team and identity come from ~/.config/sempere/release.env; the profiles are made by the ASC API (see README).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
kind=${1:?catalyst|sim|cli}; out=${2:-${SPIKE_OUT:-$here/build}}
[ -f "$HOME/.config/sempere/release.env" ] && . "$HOME/.config/sempere/release.env"
team=${SEMPERE_TEAM_ID:?}
ident=${SPIKE_IDENTITY:-Apple Development}
profile=${SPIKE_PROFILE:-}
mkdir -p "$out"
ent() { # $1 = extra entitlement XML
  sed "s|@EXTRA@|$1|" "$here/entitlements.plist.in" > "$out/entitlements.plist"
}
sdkmac=$(xcrun --sdk macosx --show-sdk-path)
case $kind in
catalyst)
  app="$out/Spike.app"; rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
  xcrun swiftc -swift-version 5 -O -parse-as-library -sdk "$sdkmac" -target arm64-apple-ios27.0-macabi \
    -F "$sdkmac/System/iOSSupport/System/Library/Frameworks" -framework UIKit -framework CloudKit \
    "$here/Sources/Spike.swift" -o "$app/Contents/MacOS/Spike"
  cp "$here/Info-app.plist" "$app/Contents/Info.plist"
  cp "${profile:?SPIKE_PROFILE=Catalyst development profile}" "$app/Contents/embedded.provisionprofile"
  ent "<key>application-identifier</key><string>$team.io.github.anthonytw.sempere</string><key>com.apple.application-identifier</key><string>$team.io.github.anthonytw.sempere</string><key>com.apple.developer.team-identifier</key><string>$team</string><key>com.apple.developer.aps-environment</key><string>development</string>${SPIKE_SANDBOX:+<key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.network.client</key><true/><key>com.apple.security.application-groups</key><array><string>group.io.github.anthonytw.sempere</string></array>}<key>com.apple.security.get-task-allow</key><true/>"
  codesign --force --sign "$ident" --entitlements "$out/entitlements.plist" --options runtime "$app"
  echo "$app" ;;
sim)
  app="$out/Spike-sim.app"; rm -rf "$app"; mkdir -p "$app"
  sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
  ent "<key>aps-environment</key><string>development</string><key>application-identifier</key><string>$team.io.github.anthonytw.sempere</string>"
  # The simulator reads entitlements from the binary itself (as Xcode does for simulator builds), not from the signature.
  xcrun swiftc -swift-version 5 -O -parse-as-library -sdk "$sdk" -target arm64-apple-ios27.0-simulator -framework UIKit -framework CloudKit \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$out/entitlements.plist" \
    "$here/Sources/Spike.swift" -o "$app/Spike"
  cp "$here/Info-app.plist" "$app/Info.plist"
  plutil -replace CFBundleExecutable -string Spike "$app/Info.plist"
  plutil -insert CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "$app/Info.plist"
  plutil -insert MinimumOSVersion -string 27.0 "$app/Info.plist"
  plutil -insert DTPlatformName -string iphonesimulator "$app/Info.plist"
  codesign --force --sign - "$app"
  echo "$app" ;;
cli)
  id=${CLI_BUNDLE_ID:-io.github.anthonytw.sempere}
  app="$out/sempere.app"; rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
  xcrun swiftc -swift-version 5 -O -parse-as-library -sdk "$sdkmac" -target arm64-apple-macos14.0 -framework CloudKit \
    "$here/Sources/Spike.swift" -o "$app/Contents/MacOS/sempere"
  sed "s|@BUNDLE_ID@|$id|" "$here/Info-cli.plist" > "$app/Contents/Info.plist"
  extra="<key>com.apple.application-identifier</key><string>$team.$id</string><key>com.apple.developer.team-identifier</key><string>$team</string><key>com.apple.security.get-task-allow</key><true/>"
  if [ -n "${CLI_PROFILE:-}" ]; then cp "$CLI_PROFILE" "$app/Contents/embedded.provisionprofile"; fi
  ent "$extra"
  [ -z "${CLI_NO_ENTITLEMENTS:-}" ] || sed -i '' '/icloud/d;/application-identifier/d;/team-identifier/d' "$out/entitlements.plist"
  codesign --force --sign "$ident" --entitlements "$out/entitlements.plist" "$app"
  echo "$app" ;;
esac
