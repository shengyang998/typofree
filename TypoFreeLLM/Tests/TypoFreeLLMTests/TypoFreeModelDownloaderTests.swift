import XCTest
@testable import TypoFreeLLM

/// A tiny lock-protected recorder — the `progress` callback in `Downloader` is
/// `@Sendable`, so a plain captured `var` can't be mutated from inside it under
/// Swift 6 strict concurrency.
private final class ProgressRecorder: @unchecked Sendable {
    private var values: [Double] = []
    private let lock = NSLock()
    func append(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    func snapshot() -> [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

/// M8 (tasks.md §M8, DECISIONS.md "Local weights reuse") — the three-tier local
/// cache probe: app cache → HF CLI hub cache → `~/Documents/huggingface`. All
/// three tiers are exercised against TEMP directories (never the real home
/// directory — the dev machine's actual caches are ambient state, not hermetic
/// fixtures) so these tests are independent of whatever happens to be already
/// downloaded on the box. The critical, correctness-motivated case (DECISIONS:
/// "empty stub dirs exist on this machine — do not trust dir presence") is that
/// a directory existing with NO `*.safetensors` file must never be trusted.
/// Real network downloads stay gated behind `TYPOFREE_MLX_LIVE_TEST=1`
/// (`MLXModelManagerLiveTests`) — nothing here touches the network.
final class TypoFreeModelDownloaderTests: XCTestCase {
    private let modelID = "mlx-community/Fake-Test-Model-4bit"

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "typofree-downloader-test-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// `<root>/models/<id>/` — the app-cache (tier 1) AND `~/Documents/huggingface`
    /// (tier 3) layout, both mlx-swift-lm `HubApi`'s own `downloadBase/models/<id>`.
    @discardableResult
    private func makeFlatModelDir(root: URL, id: String, withWeights: Bool) throws -> URL {
        let dir = root.appending(path: "models").appending(path: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if withWeights {
            try Data("fake-weights".utf8).write(to: dir.appending(path: "model.safetensors"))
        } else {
            // The "empty stub" case DECISIONS warns about: config present, no weights.
            try Data("{}".utf8).write(to: dir.appending(path: "config.json"))
        }
        return dir
    }

    /// `<root>/models--org--repo/snapshots/<hash>/` — the standard HF CLI cache
    /// (tier 2) layout.
    @discardableResult
    private func makeHubModelDir(root: URL, id: String, withWeights: Bool) throws -> URL {
        let repoDir = root.appending(path: "models--" + id.replacingOccurrences(of: "/", with: "--"))
        let snapDir = repoDir.appending(path: "snapshots").appending(path: "deadbeef1234")
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        if withWeights {
            try Data("fake-weights".utf8).write(to: snapDir.appending(path: "model.safetensors"))
        } else {
            try Data("{}".utf8).write(to: snapDir.appending(path: "config.json"))
        }
        return snapDir
    }

    // MARK: nothing anywhere → not local

    func testHasLocalModelFalseWhenAllThreeTiersEmpty() throws {
        let downloader = TypoFreeModelDownloader(hubCacheDirectory: tempDir(), documentsCacheDirectory: tempDir())
        XCTAssertFalse(downloader.hasLocalModel(id: modelID, cacheDirectory: tempDir()))
    }

    // MARK: stub dirs (present but no *.safetensors) must never be trusted

    func testEmptyStubDirectoriesAreNotTrustedAtAnyTier() throws {
        let appRoot = tempDir()
        let hubRoot = tempDir()
        let docsRoot = tempDir()
        try makeFlatModelDir(root: appRoot, id: modelID, withWeights: false)
        try makeHubModelDir(root: hubRoot, id: modelID, withWeights: false)
        try makeFlatModelDir(root: docsRoot, id: modelID, withWeights: false)

        let downloader = TypoFreeModelDownloader(hubCacheDirectory: hubRoot, documentsCacheDirectory: docsRoot)
        XCTAssertFalse(downloader.hasLocalModel(id: modelID, cacheDirectory: appRoot),
                       "directory presence alone must not be trusted — no *.safetensors exists")
    }

    // MARK: tier 1 — app cache

    func testTier1AppCacheHitWhenSafetensorsPresent() throws {
        let appRoot = tempDir()
        try makeFlatModelDir(root: appRoot, id: modelID, withWeights: true)
        let downloader = TypoFreeModelDownloader(hubCacheDirectory: tempDir(), documentsCacheDirectory: tempDir())
        XCTAssertTrue(downloader.hasLocalModel(id: modelID, cacheDirectory: appRoot))
    }

    // MARK: tier 2 — standard HF CLI hub cache

    func testTier2HubCacheHitWhenSafetensorsPresent() throws {
        let hubRoot = tempDir()
        try makeHubModelDir(root: hubRoot, id: modelID, withWeights: true)
        let downloader = TypoFreeModelDownloader(hubCacheDirectory: hubRoot, documentsCacheDirectory: tempDir())
        XCTAssertTrue(downloader.hasLocalModel(id: modelID, cacheDirectory: tempDir()))
    }

    // MARK: tier 3 — ~/Documents/huggingface (mlx-swift-lm's own HubApi default)

    func testTier3DocumentsHuggingFaceHitWhenSafetensorsPresent() throws {
        let docsRoot = tempDir()
        try makeFlatModelDir(root: docsRoot, id: modelID, withWeights: true)
        let downloader = TypoFreeModelDownloader(hubCacheDirectory: tempDir(), documentsCacheDirectory: docsRoot)
        XCTAssertTrue(downloader.hasLocalModel(id: modelID, cacheDirectory: tempDir()))
    }

    // MARK: ensureModel short-circuits (no network) on any tier hit

    func testEnsureModelReturnsLocalSnapshotWithoutNetworkOnTier1Hit() async throws {
        let appRoot = tempDir()
        let expected = try makeFlatModelDir(root: appRoot, id: modelID, withWeights: true)
        let downloader = TypoFreeModelDownloader(hubCacheDirectory: tempDir(), documentsCacheDirectory: tempDir())

        let recorder = ProgressRecorder()
        let resolved = try await downloader.ensureModel(
            id: modelID, mirrorHost: "hf-mirror.com", cacheDirectory: appRoot,
            progress: { recorder.append($0) })

        XCTAssertEqual(resolved.standardizedFileURL, expected.standardizedFileURL)
        XCTAssertEqual(recorder.snapshot(), [1.0], "a local hit reports immediate completion, never partial progress")
    }

    func testEnsureModelReturnsLocalSnapshotWithoutNetworkOnTier3Hit() async throws {
        let docsRoot = tempDir()
        let expected = try makeFlatModelDir(root: docsRoot, id: modelID, withWeights: true)
        let downloader = TypoFreeModelDownloader(hubCacheDirectory: tempDir(), documentsCacheDirectory: docsRoot)

        let resolved = try await downloader.ensureModel(
            id: modelID, mirrorHost: "hf-mirror.com", cacheDirectory: tempDir(),
            progress: { _ in })

        XCTAssertEqual(resolved.standardizedFileURL, expected.standardizedFileURL)
    }

    // MARK: tier order — app cache wins over hub cache when both have weights

    func testTier1PreferredOverTier2WhenBothPresent() async throws {
        let appRoot = tempDir()
        let hubRoot = tempDir()
        let appHit = try makeFlatModelDir(root: appRoot, id: modelID, withWeights: true)
        let hubHit = try makeHubModelDir(root: hubRoot, id: modelID, withWeights: true)
        let downloader = TypoFreeModelDownloader(hubCacheDirectory: hubRoot, documentsCacheDirectory: tempDir())

        let resolved = try await downloader.ensureModel(
            id: modelID, mirrorHost: "hf-mirror.com", cacheDirectory: appRoot, progress: { _ in })

        XCTAssertEqual(resolved.standardizedFileURL, appHit.standardizedFileURL,
                       "tier 1 (app cache) must win when tier 2 (hub cache) also has weights")
        XCTAssertNotEqual(resolved.standardizedFileURL, hubHit.standardizedFileURL)
    }
}
