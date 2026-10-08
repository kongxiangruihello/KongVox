// swift-tools-version: 6.0
// Standalone feasibility probe for on-device transcription (macOS 26 Speech framework).
// Kept outside the app package so KongVox itself still targets macOS 13.
import PackageDescription
let package = Package(
    name: "asr-probe",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "asr-probe", swiftSettings: [.swiftLanguageMode(.v5)])]
)
