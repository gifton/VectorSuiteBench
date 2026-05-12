// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VSBCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VSBCore", targets: ["VSBCore"]),
    ],
    dependencies: [
        .package(path: "../BenchKit"),
        .package(path: "../../../VSK/VectorCore"),
    ],
    targets: [
        .target(
            name: "VSBCore",
            dependencies: [
                "BenchKit",
                .product(name: "VectorCore", package: "VectorCore"),
            ]
        ),
        .testTarget(
            name: "VSBCoreTests",
            dependencies: ["VSBCore"]
        ),
    ]
)
