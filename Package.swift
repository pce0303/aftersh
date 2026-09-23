// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "aftersh",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "af", targets: ["af"]),
        .executable(name: "aftersh", targets: ["aftersh"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "AftershCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .executableTarget(
            name: "af",
            dependencies: ["AftershCore"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .executableTarget(
            name: "aftersh",
            dependencies: ["AftershCore"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "aftershTests",
            dependencies: ["AftershCore"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ]
)
