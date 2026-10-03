#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/kongvox-clang-cache"
mkdir -p .build
swiftc -parse-as-library -swift-version 5 -D STANDALONE_TESTS Sources/KongVox/VolcengineAudio.swift Sources/KongVox/DocumentImport.swift Sources/KongVox/BatchTools.swift Sources/KongVox/ServiceProfile.swift Sources/KongVox/Models.swift Sources/KongVox/LongFormTools.swift Sources/KongVox/WAVDecoder.swift Sources/KongVox/Recovery.swift Sources/KongVox/Subtitles.swift Sources/KongVox/Services.swift Sources/KongVox/AudioAssembly.swift Sources/KongVox/CompletionNotice.swift Sources/KongVox/Store.swift Sources/KongVox/PlaybackTimeline.swift Sources/KongVox/ProjectBackup.swift Sources/KongVox/BackupActions.swift Tests/KongVoxTests/CoreTests.swift Tests/KongVoxTests/ServiceTests.swift Tests/KongVoxTests/CosyVoiceTests.swift Tests/KongVoxTests/WAVDecoderTests.swift Tests/KongVoxTests/Version03Tests.swift Tests/KongVoxTests/LongDocumentTests.swift Tests/KongVoxTests/Version05Tests.swift Tests/KongVoxTests/Version06Tests.swift Tests/KongVoxTests/Version07Tests.swift Tests/KongVoxTests/Version08Tests.swift -o .build/core-tests
.build/core-tests
