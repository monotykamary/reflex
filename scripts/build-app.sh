#!/bin/sh
# Build reflexd (Bend) and Reflex.app (Swift), then assemble build/Reflex.app.
#
#   scripts/build-app.sh            # daemon + app
#   scripts/build-app.sh --app      # app only (reuse build/reflexd)
#   scripts/build-app.sh --daemon   # daemon only
set -eu
cd "$(dirname "$0")/.."
root=$PWD
mode=${1:-all}

export BEND_NO_TELEMETRY=1
# Bend's code generator runs on Bun's JavaScriptCore. Capping the heap JSC
# assumes it may use keeps its footprint in RAM instead of swap (see
# docs/bend-build-speed.md); output is byte-identical.
export BUN_JSC_forceRAMSize=${BUN_JSC_forceRAMSize:-4294967296}

if [ "$mode" != --app ]; then
  mkdir -p build
  echo "reflexd: checking pure modules"
  for m in Core Route Index Http Model Js; do
    bend "daemon/$m.bend" --check-only >/dev/null
  done
  echo "reflexd: building"
  bend daemon/main.bend -o build/reflexd
fi
[ "$mode" = --daemon ] && exit 0

echo "Reflex.app: building"
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
cp "$icon" "$app/Contents/Resources/AppIcon.icns"
cp build/reflexd "$app/Contents/Resources/reflexd"
cp scripts/reflex-scan.sh scripts/reflex-fork.sh "$app/Contents/Resources/scripts/"
cp web/* "$app/Contents/Resources/web/"
mkdir -p "$app/Contents/Resources/integrations/pi"
cp integrations/pi/reflex-shells.ts "$app/Contents/Resources/integrations/pi/"
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
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>ReflexCommit</key><string>$commit</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$app/Contents/Resources/reflexd"
codesign --force --sign - "$app"
echo "built $app"
