// swift-tools-version:5.9
// Package.swift — SnapiExample

import PackageDescription

let package = Package(
    name: "SnapiExample",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    dependencies: [
        .package(path: "../../")
    ],
    targets: [
        .executableTarget(
            name: "SnapiExample",
            dependencies: ["Snapi"],
            path: "Sources"
        )
    ]
)