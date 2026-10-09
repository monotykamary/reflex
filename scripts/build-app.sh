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

app=build/Reflex.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/scripts" "$app/Contents/Resources/web"
cp "$bin" "$app/Contents/MacOS/Reflex"
cp build/reflexd "$app/Contents/Resources/reflexd"
cp scripts/reflex-scan.sh scripts/reflex-fork.sh "$app/Contents/Resources/scripts/"
cp web/* "$app/Contents/Resources/web/"
version=$(git -C "$root" describe --tags --always 2>/dev/null || echo 0.1.0)
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
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$app/Contents/Resources/reflexd"
codesign --force --sign - "$app"
echo "built $app"
