// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BenchKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BenchKit", targets: ["BenchKit"]),
    ],
    targets: [
        .target(
            name: "BenchKitC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "BenchKit",
            dependencies: ["BenchKitC"]
        ),
        .testTarget(
            name: "BenchKitTests",
            dependencies: ["BenchKit"]
        ),
    ]
)
