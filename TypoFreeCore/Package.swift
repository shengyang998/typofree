// swift-tools-version: 6.2
import PackageDescription

// TypoFreeCore — zero external dependencies (DESIGN.md §0/§1). Pure Swift +
// CSQLite system-library shim only. Must `swift test` standalone: no network,
// no MLX/Metal, no login session. All real AppKit/IMKit/ApplicationServices
// calls live in the app shell, never here.
let package = Package(
    name: "TypoFreeCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TypoFreeCore", targets: ["TypoFreeCore"])
    ],
    dependencies: [],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(
            name: "TypoFreeCore",
            dependencies: ["CSQLite"],
            resources: [
                .copy("Resources/lexicon.bin")
                // Resources/readings.bin (TFXR v1 multi-reading sidecar) is
                // symlinked + added here in M2, once build_lexicon.py produces it.
            ]
        ),
        .testTarget(
            name: "TypoFreeCoreTests",
            dependencies: ["TypoFreeCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
