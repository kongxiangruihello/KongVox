#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/kongvox-clang-cache"
source version.env
bash scripts/make-brand-assets.sh
swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox)"
APP="$PWD/dist/KongVox-$KONGVOX_VERSION/KongVox.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/KongVox" "$APP/Contents/MacOS/KongVox"
cp .build/KongVox.icns "$APP/Contents/Resources/KongVox.icns"
cp Assets/KongVox-icon.png "$APP/Contents/Resources/KongVox-icon.png"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KongVox</string>
<key>CFBundleIdentifier</key><string>com.kongvox.studio</string>
<key>CFBundleIconFile</key><string>KongVox.icns</string>
<key>CFBundleName</key><string>KongVox</string>
<key>CFBundleDisplayName</key><string>KongVox</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$KONGVOX_VERSION</string>
<key>CFBundleVersion</key><string>$KONGVOX_BUILD</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Ad-hoc by default. Set CODESIGN_IDENTITY to a stable (e.g. self-signed) identity so macOS
# keeps Keychain access across rebuilds instead of asking again after every update.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PWD/dist/KongVox-$KONGVOX_VERSION-Mac.zip"
echo "Built: $APP"
