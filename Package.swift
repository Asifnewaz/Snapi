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
        .library(
            name: "Snapi",
            targets: ["Snapi"]
        ),
        .library(
            name: "SnapiTestSupport",
            targets: ["SnapiTestSupport"]
        )
    ],
    targets: [
        .target(
            name: "Snapi",
            path: "Sources/Snapi"
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
