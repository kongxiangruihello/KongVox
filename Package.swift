// swift-tools-version: 5.9
import Foundation
import PackageDescription

// On-device speech (Qwen3-TTS through MLX) needs macOS 14 and a full Xcode build, because only Xcode
// compiles MLX's Metal shaders. Set KONGVOX_LOCAL_SPEECH=0 to leave it out: the app then builds with
// `swift build` and Command Line Tools alone, and every online service works as before.
let localSpeech = ProcessInfo.processInfo.environment["KONGVOX_LOCAL_SPEECH"] != "0"

// mlx-audio-swift is pinned to the commit whose Mandarin output was listened to and accepted.
let packageDependencies: [Package.Dependency] = localSpeech ? [
    .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "e0de9e79d69c24a1277982bb3d8fafc4da5ce035"),
    .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.33.0"),
    .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.8.1"),
] : []
let appDependencies: [Target.Dependency] = localSpeech ? [
    .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
    .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
    .product(name: "MLX", package: "mlx-swift"),
    .product(name: "HuggingFace", package: "swift-huggingface"),
] : []

let package = Package(
    name: "KongVox",
    platforms: [localSpeech ? .macOS(.v14) : .macOS(.v13)],
    products: [.executable(name: "KongVox", targets: ["KongVox"])],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(name: "KongVox", dependencies: appDependencies),
        .testTarget(name: "KongVoxTests", dependencies: ["KongVox"]),
    ]
)
