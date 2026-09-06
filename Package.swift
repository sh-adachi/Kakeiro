// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KakeiroCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "KakeiroCore", targets: ["KakeiroCore"])],
    targets: [
        .target(name: "KakeiroCore", path: "Core"),
        .testTarget(name: "KakeiroCoreTests", dependencies: ["KakeiroCore"], path: "Tests/KakeiroCoreTests")
    ]
)
