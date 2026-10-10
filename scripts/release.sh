#!/bin/sh
# Release: build, sign with the hardened runtime, notarize, and package a DMG.
#
#   scripts/release.sh            # ad-hoc signed: runs on this Mac only; checks
#                                 # the app works under the hardened runtime
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=reflex scripts/release.sh
#
# NOTARY_PROFILE is a notarytool keychain profile, stored once with:
#   xcrun notarytool store-credentials reflex --apple-id you@example.com --team-id TEAMID
# REFLEX_SKIP_DAEMON=1 reuses build/reflexd (the Bend build takes minutes).
set -eu
cd "$(dirname "$0")/.."

identity=${DEVELOPER_ID:--}
if [ -n "${REFLEX_SKIP_DAEMON:-}" ]; then scripts/build-app.sh --app; else scripts/build-app.sh; fi

app=build/Reflex.app
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
stamp=""
[ "$identity" != "-" ] && stamp="--timestamp"

echo "signing ($identity)"
codesign --force --options runtime $stamp --sign "$identity" "$app/Contents/Resources/reflexd"
codesign --force --options runtime $stamp --entitlements scripts/Reflex.entitlements --sign "$identity" "$app"
codesign --verify --deep --strict "$app"

dmg=build/Reflex-$version.dmg
stage=$(mktemp -d)
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname "Reflex" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
rm -rf "$stage"
[ "$identity" != "-" ] && codesign --force $stamp --sign "$identity" "$dmg"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  [ "$identity" = "-" ] && { echo "notarizing needs DEVELOPER_ID"; exit 1; }
  echo "notarizing (a few minutes)"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature -v "$dmg"
fi
echo "released $dmg"
