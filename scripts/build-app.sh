#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/kongvox-clang-cache"
source version.env
bash scripts/make-brand-assets.sh
# The on-device engine (MLX) needs Xcode, which compiles its Metal shaders; `swift build` cannot.
# Without a full Xcode, or with KONGVOX_LOCAL_SPEECH=0, build the app without that engine instead.
if [ "${KONGVOX_LOCAL_SPEECH:-1}" != "0" ] && xcodebuild -version >/dev/null 2>&1; then
  LOCAL_SPEECH=1; MIN_MACOS=14.0
  # Xcode 26 ships the Metal compiler as a separate download.
  xcrun -f metal >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain
  DERIVED="$PWD/.build/xcode"; mkdir -p .build
  if ! xcodebuild build -scheme KongVox -configuration Release -destination 'platform=macOS' \
      -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO > .build/xcodebuild.log 2>&1; then
    grep -E "error:|: error" .build/xcodebuild.log | head -40 || true
    tail -30 .build/xcodebuild.log
    echo "xcodebuild failed; full log: .build/xcodebuild.log" >&2; exit 1
  fi
  BIN_DIR="$DERIVED/Build/Products/Release"
else
  LOCAL_SPEECH=0; MIN_MACOS=13.0
  export KONGVOX_LOCAL_SPEECH=0
  echo "Building without the on-device engine (needs a full Xcode; online services are unaffected)."
  swift build -c release --disable-sandbox
  BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox)"
fi
APP="$PWD/dist/KongVox-$KONGVOX_VERSION/KongVox.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/KongVox" "$APP/Contents/MacOS/KongVox"
if [ "$LOCAL_SPEECH" = 1 ]; then
  # Resource bundles of the dependencies, including mlx-swift_Cmlx.bundle with the Metal shader library.
  for bundle in "$BIN_DIR"/*.bundle; do ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"; done
  find "$APP/Contents/Resources" -name default.metallib | grep -q . || { echo "Metal shader library missing from the app bundle." >&2; exit 1; }
fi
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
<key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSSpeechRecognitionUsageDescription</key><string>KongVox 在本机转写已生成的配音，用于发现疑似漏读、重读并对齐字幕；音频不会上传。</string>
</dict></plist>
PLIST
# Ad-hoc by default. Set CODESIGN_IDENTITY to a stable (e.g. self-signed) identity so macOS
# keeps Keychain access across rebuilds instead of asking again after every update.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PWD/dist/KongVox-$KONGVOX_VERSION-Mac.zip"
codesign --verify --deep --strict "$APP"
echo "Built: $APP (on-device engine: $([ "$LOCAL_SPEECH" = 1 ] && echo included || echo not included))"
