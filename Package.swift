// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "KongVox", platforms: [.macOS(.v13)], products: [.executable(name: "KongVox", targets: ["KongVox"])], targets: [.executableTarget(name: "KongVox"), .testTarget(name: "KongVoxTests", dependencies: ["KongVox"])])
