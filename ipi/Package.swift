// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "IPI",
    platforms: [
        .iOS(.v17),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "IPI",
            targets: ["IPI"]
        ),
    ],
    targets: [
        .target(
            name: "IPI"
        ),
        .testTarget(
            name: "IPITests",
            dependencies: ["IPI"]
        ),
    ]
)
