// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tic",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Tic",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "TicTests",
            dependencies: ["Tic"]
        )
    ]
)
