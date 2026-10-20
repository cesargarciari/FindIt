// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FindItCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "FindItCore", targets: ["FindItCore"]),
        .executable(name: "findit-eval", targets: ["findit-eval"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2")
    ],
    targets: [
        .target(
            name: "FindItCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "findit-eval",
            dependencies: [
                "FindItCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "FindItCoreTests",
            dependencies: [
                "FindItCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
