// swift-tools-version:5.9
// Package.swift — Snapi

import PackageDescription

let package = Package(
    name: "Snapi",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        // Main SDK — import Snapi
        .library(
            name: "Snapi",
            targets: ["Snapi"]
        ),
        // Test helpers — import SnapiTestSupport (test targets only)
        .library(
            name: "SnapiTestSupport",
            targets: ["SnapiTestSupport"]
        )
    ],
    targets: [
        .target(
            name: "Snapi",
            path: "Sources/Snapi",
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("Combine")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "SnapiTestSupport",
            dependencies: ["Snapi"],
            path: "Sources/SnapiTestSupport"
        ),
        .testTarget(
            name: "SnapiTests",
            dependencies: ["Snapi", "SnapiTestSupport"],
            path: "Tests/SnapiTests"
        )
    ]
)
