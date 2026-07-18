import Foundation
import Hub

// TypoFreeModelDownloader — the production `Downloader` (DESIGN.md §2.4,
// DECISIONS.md 2026-07-18 "MLX bake-off results" / "Local weights reuse").
// Probe order: app cache → `~/.cache/huggingface/hub` → `~/Documents/huggingface`
// → download (HuggingFace, then hf-mirror). Downloads land under Application
// Support (NOT the default ~/Documents) so the `.app` stays small and the weights
// are user-scoped. Never trust a directory's mere presence — verify a real
// `*.safetensors` exists (empty stub dirs are known to exist on the dev machine
// for BOTH the hub cache and `~/Documents/huggingface`).
public struct TypoFreeModelDownloader: Downloader {
    /// Which files to fetch — the mlx 4-bit set (safetensors weights + all JSON
    /// config/tokenizer + txt vocab/merges + sentencepiece/tiktoken tokenizers).
    static let modelGlobs = ["*.safetensors", "*.json", "*.txt", "tokenizer.model", "*.tiktoken"]

    /// Tier-2/3 probe roots. Overridable so tests can point at temp directories
    /// instead of the real home directory — the dev machine's actual caches are
    /// ambient state (already holding real + stub model directories), not
    /// hermetic test fixtures.
    private let hubCacheDirectory: URL
    private let documentsCacheDirectory: URL

    public init(hubCacheDirectory: URL = MLXModelPaths.huggingFaceHubCache,
                documentsCacheDirectory: URL = MLXModelPaths.documentsHuggingFaceCache) {
        self.hubCacheDirectory = hubCacheDirectory
        self.documentsCacheDirectory = documentsCacheDirectory
    }

    public func hasLocalModel(id: String, cacheDirectory: URL) -> Bool {
        localSnapshot(id: id, cacheDirectory: cacheDirectory) != nil
    }

    public func ensureModel(id: String, mirrorHost: String, cacheDirectory: URL,
                            progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        if let local = localSnapshot(id: id, cacheDirectory: cacheDirectory) {
            progress(1.0)
            return local
        }
        let repo = Hub.Repo(id: id)
        var lastError: Error?
        for endpoint in ["https://huggingface.co", "https://\(mirrorHost)"] {
            do {
                let hub = HubApi(downloadBase: cacheDirectory, endpoint: endpoint)
                let url = try await hub.snapshot(from: repo, matching: Self.modelGlobs) { p in
                    progress(p.fractionCompleted)
                }
                return url
            } catch {
                lastError = error
            }
        }
        throw lastError ?? DownloaderError.allSourcesFailed
    }

    // MARK: - Local probing

    /// The first local directory that holds a real `*.safetensors` for `id`,
    /// across three tiers (DECISIONS.md 2026-07-18 probe order): the app cache
    /// (HubApi layout `<base>/models/<org>/<repo>`), the standard HF CLI hub
    /// cache (`models--<org>--<repo>/snapshots/<hash>/`), and mlx-swift-lm's own
    /// `HubApi`-default `~/Documents/huggingface` (same flat `models/<id>` layout
    /// as tier 1, different root — confirmed via the swift-transformers `HubApi`
    /// source: no explicit `downloadBase` defaults to `~/Documents/huggingface`).
    private func localSnapshot(id: String, cacheDirectory: URL) -> URL? {
        // 1. App cache — the HubApi `downloadBase/models/<id>` layout.
        let appDir = cacheDirectory.appending(path: "models").appending(path: id)
        if directoryHasWeights(appDir) { return appDir }

        // 2. Standard HF CLI cache: hub/models--org--repo/snapshots/<hash>/.
        let hubRoot = hubCacheDirectory
            .appending(path: "models--" + id.replacingOccurrences(of: "/", with: "--"))
            .appending(path: "snapshots")
        if let snaps = try? FileManager.default.contentsOfDirectory(
            at: hubRoot, includingPropertiesForKeys: nil) {
            for snap in snaps where directoryHasWeights(snap) { return snap }
        }

        // 3. mlx-swift-lm's own HubApi-default cache: documents/models/<id>.
        let documentsDir = documentsCacheDirectory.appending(path: "models").appending(path: id)
        if directoryHasWeights(documentsDir) { return documentsDir }

        return nil
    }

    private func directoryHasWeights(_ dir: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return false }
        return items.contains { $0.pathExtension == "safetensors" }
    }
}
