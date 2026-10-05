// swift-tools-version: 6.2
// Leviathan — harvests how models answer and writes Thread corpora RaoLM can train on.
//
// A prompt is sent to a model through any OpenAI-compatible /chat/completions endpoint across
// a temperature spread. Every response lands in dataset/<company>/<model-id>/transcripts.jsonl.
// From those samples Leviathan derives a passage (what every sample kept, and the areas where
// they diverge), measures expectations cut at function words, weighs every token, and exports
// one Thread per model and prompt set in RaoLM's corpus format.
//
// Layout:
//   LeviathanCore   workspace, providers, chat client, transcripts, harvest, passage, expectations,
//                   weights, the RaoLM corpus mirror, measurements, edits     (Foundation only)
//   LeviathanCLI    the `leviathan` executable
//   LeviathanApp    the SwiftUI Mac app on the same core

import PackageDescription

let package = Package(
    name: "Leviathan",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LeviathanCore", targets: ["LeviathanCore"]),
        .executable(name: "leviathan", targets: ["LeviathanCLI"]),
        .executable(name: "LeviathanApp", targets: ["LeviathanApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "LeviathanCore"),
        .executableTarget(
            name: "LeviathanCLI",
            dependencies: ["LeviathanCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .executableTarget(name: "LeviathanApp", dependencies: ["LeviathanCore"]),
        .testTarget(
            name: "LeviathanCoreTests",
            dependencies: ["LeviathanCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
