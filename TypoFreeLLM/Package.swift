// swift-tools-version: 6.2
// Bumped from DESIGN.md §1's literal "6.1" — `.macOS(.v26)` requires
// PackageDescription 6.2 on this toolchain (Xcode 26.4 / Swift 6.3); see
// TypoFreeCore/Package.swift for the same, matching bump. Recorded as an M0
// deviation in tasks.md/notes_for_next.
import PackageDescription

// TypoFreeLLM — isolates the MLX/Metal dependency graph away from
// TypoFreeCore (DESIGN.md §0/§1). FoundationModelsCorrectionProvider lives in
// Core (system framework, zero extra deps); only MLX needs this package.
let package = Package(
    name: "TypoFreeLLM",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TypoFreeLLM", targets: ["TypoFreeLLM"])
    ],
    dependencies: [
        .package(path: "../TypoFreeCore"),
        // Pinned to the 2.x line on purpose — 3.x (HEAD as of 2026-07-17)
        // replaces the built-in HubApi loader with a Downloader/TokenizerLoader
        // protocol pair and has product-name drift in its own README. Re-verify
        // before ever bumping past 2.x (DESIGN.md §1).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "2.31.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.2.0")),
    ],
    targets: [
        .target(
            name: "TypoFreeLLM",
            dependencies: [
                "TypoFreeCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
            ]
        ),
        .testTarget(
            name: "TypoFreeLLMTests",
            dependencies: ["TypoFreeLLM"]
        ),
    ]
)
