#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/kongvox-clang-cache"
APP="$PWD/dist/KongVox-0.8.1/KongVox.app"
DMG_PYTHON="${DMG_PYTHON:-python3}"
"$DMG_PYTHON" -c 'import ds_store, mac_alias'
VOLUME="KongVox 0.8.1 安装"
STAGE="$(mktemp -d /tmp/kongvox-dmg.XXXXXX)"
MOUNT="$STAGE/mount"
mkdir -p "$STAGE/source/.background" "$MOUNT"
cleanup() { hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rm -rf "$STAGE"; }
trap cleanup EXIT
ditto "$APP" "$STAGE/source/KongVox.app"
ln -s /Applications "$STAGE/source/Applications"
cp .build/installer-background.png "$STAGE/source/.background/installer.png"
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE/source" -ov -format UDRW "$STAGE/writable.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint "$MOUNT" "$STAGE/writable.dmg"
"$DMG_PYTHON" scripts/dmg-layout.py "$MOUNT"
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$STAGE/writable.dmg" -format UDZO -ov -o "$PWD/dist/KongVox-0.8.1-Mac.dmg"
hdiutil verify "$PWD/dist/KongVox-0.8.1-Mac.dmg"
