#!/bin/sh
# Build reflexd (TypeScript, one native binary by Bun) and Reflex.app (Swift),
# then assemble build/Reflex.app.
#
#   scripts/build-app.sh            # daemon + app
#   scripts/build-app.sh --app      # app and reflex-keys (reuse build/reflexd)
#   scripts/build-app.sh --daemon   # daemon only
set -eu
cd "$(dirname "$0")/.."
root=$PWD
mode=${1:-all}

if [ "$mode" != --app ]; then
  bun=$(command -v bun || echo "$HOME/.bun/bin/bun")
  [ -x "$bun" ] || { echo "reflexd needs Bun: curl -fsSL https://bun.sh/install | bash"; exit 1; }
  mkdir -p build
  (
    cd daemon
    PATH="$(dirname "$bun"):$PATH"
    "$bun" install --frozen-lockfile >/dev/null
    echo "reflexd: types, laws and tests"
    "$bun" run check >/dev/null 2>&1 || { "$bun" run check; exit 1; }
    echo "reflexd: building"
    "$bun" run build >/dev/null
  )
fi
[ "$mode" = --daemon ] && exit 0

# reflex-keys (keys/): this Mac's own, and as one script for boxes, run with their Bun.
# Always built (seconds): --app reuses only reflexd, and a reused reflex-keys once
# shipped an app whose Settings asked it for a command it didn't have yet.
echo "reflex-keys: building"
(cd keys && bun install --frozen-lockfile >/dev/null &&
  bun build --compile --minify --target=bun-darwin-arm64 src/cli.ts --outfile ../build/reflex-keys >/dev/null &&
  bun build --minify --target=bun src/cli.ts --outfile ../build/reflex-keys.js >/dev/null)

echo "Reflex.app: building"
scripts/prepare-swiftterm.sh
swift build -c release --package-path app
bin=$(swift build -c release --package-path app --show-bin-path)/Reflex

# App icon, drawn by code (scripts/make-icon.swift) into an .icns.
icon=build/AppIcon.icns
if [ ! -f "$icon" ] || [ scripts/make-icon.swift -nt "$icon" ]; then
  set_dir=build/AppIcon.iconset
  rm -rf "$set_dir" && mkdir -p "$set_dir"
  swift scripts/make-icon.swift build/AppIcon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/AppIcon-1024.png --out "$set_dir/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/AppIcon-1024.png --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$set_dir" -o "$icon"
fi

app=build/Reflex.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/scripts" "$app/Contents/Resources/web"
cp "$bin" "$app/Contents/MacOS/Reflex"
# Sparkle (updates), without its XPC services: Reflex isn't sandboxed.
mkdir -p "$app/Contents/Frameworks"
ditto "$(dirname "$bin")/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
cp "$icon" "$app/Contents/Resources/AppIcon.icns"
cp build/reflexd "$app/Contents/Resources/reflexd"
cp build/reflex-keys "$app/Contents/Resources/reflex-keys"
cp build/reflex-keys.js "$app/Contents/Resources/scripts/reflex-keys.js"
cp scripts/reflex-scan.sh scripts/reflex-fork.sh scripts/reflex-remote.sh scripts/reflex.sh "$app/Contents/Resources/scripts/"
cp web/* "$app/Contents/Resources/web/"
mkdir -p "$app/Contents/Resources/logos"
cp app/Resources/logos/*.png "$app/Contents/Resources/logos/"
mkdir -p "$app/Contents/Resources/integrations/pi"
cp integrations/pi/reflex-shells.ts "$app/Contents/Resources/integrations/pi/"
mkdir -p "$app/Contents/Resources/integrations/skills/reflex"
cp integrations/skills/reflex/SKILL.md "$app/Contents/Resources/integrations/skills/reflex/"
# CFBundleVersion must be numeric (updaters compare it): the commit count.
# The commit itself is kept in ReflexCommit.
build_number=$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)
commit=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.reflex.app</string>
  <key>CFBundleName</key><string>Reflex</string>
  <key>CFBundleDisplayName</key><string>Reflex</string>
  <key>CFBundleExecutable</key><string>Reflex</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(cat "$root/VERSION")</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>ReflexCommit</key><string>$commit</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>https://reflex.farm/appcast.xml</string>
  <key>SUPublicEDKey</key><string>nZ4HvEpyNprzUA/CbKoJfrxbQYhE35SU3UGC0YPDD3Y=</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --entitlements scripts/bun.entitlements "$app/Contents/Resources/reflexd"
codesign --force --sign - --entitlements scripts/bun.entitlements "$app/Contents/Resources/reflex-keys"
codesign --force --sign - "$app"
echo "built $app"
