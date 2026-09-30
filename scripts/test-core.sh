#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/kongvox-clang-cache"
mkdir -p .build
swiftc -parse-as-library -swift-version 5 -D STANDALONE_TESTS Sources/KongVox/ServiceProfile.swift Sources/KongVox/Models.swift Sources/KongVox/Services.swift Sources/KongVox/Store.swift Tests/KongVoxTests/CoreTests.swift Tests/KongVoxTests/ServiceTests.swift Tests/KongVoxTests/CosyVoiceTests.swift -o .build/core-tests
.build/core-tests
