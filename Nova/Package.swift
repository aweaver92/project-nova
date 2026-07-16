// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Nova",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "NovaCore", targets: ["NovaCore"]),
        .library(name: "NovaDomain", targets: ["NovaDomain"]),
        .library(name: "NovaData", targets: ["NovaData"]),
        .library(name: "NovaFeatures", targets: ["NovaFeatures"]),
        .library(name: "NovaComposition", targets: ["NovaComposition"])
    ],
    dependencies: [
        // Meta Wearables Device Access Toolkit (binary XCFrameworks) — real
        // glasses camera capture. NovaData compiles against it behind
        // `#if canImport(MWDATCamera)`.
        .package(url: "https://github.com/facebook/meta-wearables-dat-ios", exact: "0.8.0")
    ],
    targets: [
        .target(
            name: "NovaCore",
            path: "Sources/NovaCore"
        ),
        .target(
            name: "NovaDomain",
            dependencies: ["NovaCore"],
            path: "Sources/NovaDomain"
        ),
        .target(
            name: "NovaData",
            dependencies: [
                "NovaCore",
                "NovaDomain",
                .product(name: "MWDATCore", package: "meta-wearables-dat-ios"),
                .product(name: "MWDATCamera", package: "meta-wearables-dat-ios")
            ],
            path: "Sources/NovaData"
        ),
        .target(
            name: "NovaFeatures",
            dependencies: ["NovaCore", "NovaDomain"],
            path: "Sources/NovaFeatures"
        ),
        .target(
            name: "NovaComposition",
            dependencies: ["NovaCore", "NovaDomain", "NovaData", "NovaFeatures"],
            path: "Sources/NovaComposition"
        ),
        .testTarget(
            name: "NovaDomainTests",
            dependencies: ["NovaDomain", "NovaCore"],
            path: "Tests/NovaDomainTests"
        ),
        .testTarget(
            name: "NovaDataTests",
            dependencies: ["NovaData", "NovaDomain", "NovaCore"],
            path: "Tests/NovaDataTests"
        )
    ]
)
