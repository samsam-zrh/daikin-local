// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MonClimat",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "DaikinCore", targets: ["DaikinCore"])],
    targets: [
        .target(name: "DaikinCore", path: "Core"),
        .testTarget(name: "DaikinCoreTests", dependencies: ["DaikinCore"], path: "Tests")
    ]
)
