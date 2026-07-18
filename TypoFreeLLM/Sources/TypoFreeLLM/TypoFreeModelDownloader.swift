import Foundation
import Hub

// TypoFreeModelDownloader — the production `Downloader` (DESIGN.md §2.4,
// DECISIONS.md 2026-07-18). Probe order: app cache → `~/.cache/huggingface/hub`
// → download (HuggingFace, then hf-mirror). Downloads land under Application
// Support (NOT the default ~/Documents) so the `.app` stays small and the weights
// are user-scoped. Never trust a directory's mere presence — verify a real
// `*.safetensors` exists.
public struct TypoFreeModelDownloader: Downloader {
    /// Which files to fetch — the mlx 4-bit set (safetensors weights + all JSON
    /// config/tokenizer + txt vocab/merges + sentencepiece/tiktoken tokenizers).
    static let modelGlobs = ["*.safetensors", "*.json", "*.txt", "tokenizer.model", "*.tiktoken"]

    public init() {}

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
    /// across the app cache (HubApi layout `<base>/models/<org>/<repo>`) and the
    /// standard HF hub cache (`models--<org>--<repo>/snapshots/<hash>/`).
    private func localSnapshot(id: String, cacheDirectory: URL) -> URL? {
        // 1. App cache — the HubApi `downloadBase/models/<id>` layout.
        let appDir = cacheDirectory.appending(path: "models").appending(path: id)
        if directoryHasWeights(appDir) { return appDir }

        // 2. Standard HF CLI cache: hub/models--org--repo/snapshots/<hash>/.
        let hubRoot = MLXModelPaths.huggingFaceHubCache
            .appending(path: "models--" + id.replacingOccurrences(of: "/", with: "--"))
            .appending(path: "snapshots")
        if let snaps = try? FileManager.default.contentsOfDirectory(
            at: hubRoot, includingPropertiesForKeys: nil) {
            for snap in snaps where directoryHasWeights(snap) { return snap }
        }
        return nil
    }

    private func directoryHasWeights(_ dir: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return false }
        return items.contains { $0.pathExtension == "safetensors" }
    }
}
