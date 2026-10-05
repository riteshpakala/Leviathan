// swift-tools-version: 6.2
// Leviathon — harvests how models answer and writes Thread corpora RaoLM can train on.
//
// A prompt is sent to a model through any OpenAI-compatible /chat/completions endpoint across
// a temperature spread. Every response lands in dataset/<company>/<model-id>/transcripts.jsonl.
// From those samples Leviathon derives a passage (what every sample kept, and the areas where
// they diverge), measures expectations cut at function words, weighs every token, and exports
// one Thread per model and prompt set in RaoLM's corpus format.
//
// Layout:
//   LeviathonCore   workspace, providers, chat client, transcripts, harvest, passage, expectations,
//                   weights, the RaoLM corpus mirror, measurements, edits     (Foundation only)
//   LeviathonCLI    the `leviathon` executable
//   LeviathonApp    the SwiftUI Mac app on the same core

import PackageDescription

let package = Package(
    name: "Leviathon",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LeviathonCore", targets: ["LeviathonCore"]),
        .executable(name: "leviathon", targets: ["LeviathonCLI"]),
        .executable(name: "LeviathonApp", targets: ["LeviathonApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "LeviathonCore"),
        .executableTarget(
            name: "LeviathonCLI",
            dependencies: ["LeviathonCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .executableTarget(name: "LeviathonApp", dependencies: ["LeviathonCore"]),
        .testTarget(
            name: "LeviathonCoreTests",
            dependencies: ["LeviathonCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
