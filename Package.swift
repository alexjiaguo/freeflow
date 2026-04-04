// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AudioWriterHarness",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "AudioWriterHarness",
            targets: ["AudioWriterHarness"]
        ),
    ],
    targets: [
        .target(
            name: "AudioWriterHarness",
            path: "Sources",
            sources: ["AudioFileWriting.swift"]
        ),
        .testTarget(
            name: "AudioWriterTests",
            dependencies: ["AudioWriterHarness"],
            path: "tests/AudioWriterTests"
        ),
    ]
)
