#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/KongVox.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Assets/KongVox-icon.png --out ".build/KongVox.iconset/icon_${size}x${size}.png" >/dev/null
  twice=$((size * 2))
  sips -z "$twice" "$twice" Assets/KongVox-icon.png --out ".build/KongVox.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns .build/KongVox.iconset -o .build/KongVox.icns
swift scripts/InstallerArtwork.swift .build/installer-background.png
