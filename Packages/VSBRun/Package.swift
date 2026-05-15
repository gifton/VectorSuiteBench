// swift-tools-version: 6.0
import PackageDescription

// Sibling-package layering rationale: BenchKit cannot depend on VSBCore
// (VSBCore already depends on BenchKit; the reverse would cycle). Placing
// the CLI in a third package that depends on *both* avoids the cycle and
// keeps BenchKit / VSBCore free of executable-target ceremony.
let package = Package(
    name: "VSBRun",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "vsb-run", targets: ["vsb-run"]),
    ],
    dependencies: [
        .package(path: "../BenchKit"),
        .package(path: "../VSBCore"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "vsb-run",
            dependencies: [
                "BenchKit",
                "VSBCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "VSBRunTests",
            dependencies: [
                "BenchKit",
                "VSBCore",
            ]
        ),
    ]
)
