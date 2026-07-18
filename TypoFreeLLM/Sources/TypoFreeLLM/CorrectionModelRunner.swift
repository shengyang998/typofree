import Foundation
import TypoFreeCore

// The MLX runner PORT (DESIGN.md §2.4). Hiding the real MLX model behind this
// protocol is what lets the provider state machine / idle-unload / debounce be
// unit-tested with a zero-weight `FakeModelRunner` (no Metal, no network); the
// real `MLXQwenRunner` is exercised only by the gated integration test.

/// The lifecycle state of an MLX-backed model, surfaced for UX (M8) + tests.
public enum MLXModelState: Sendable, Equatable {
    case unloaded
    case downloading(fraction: Double)
    case loading
    case ready
    case unloading
    case failed(reason: String)
}

/// The port the provider drives. Implementations own (or fake) the heavy model.
public protocol CorrectionModelRunner: Sendable {
    /// Ensure weights are present + loaded, reporting fractional progress.
    func load(progress: @Sendable @escaping (Double) -> Void) async throws
    /// Run one correction, returning RAW model text (post-processing + the D12
    /// gate happen in the coordinator, not here).
    func run(request: CorrectionRequest, systemInstructions: String, userPrompt: String) async throws -> String
    /// Drop the model + free its memory. Idempotent.
    func unload() async
    var isLoaded: Bool { get async }
    /// Cheap probe (no load) of whether MLX is a viable backend right now.
    func availabilityProbe() async -> LLMProviderAvailability
}

/// The weight-fetching PORT (DESIGN.md §2.4). `TypoFreeModelDownloader` is the
/// production HF→hf-mirror implementation; tests fake it. Kept off the runner
/// protocol so a fake runner needn't fake downloading.
public protocol Downloader: Sendable {
    /// Resolve a local model directory for `id` — probing local caches first,
    /// then downloading (HuggingFace, falling back to `mirrorHost`) into
    /// `cacheDirectory`. Returns the on-disk snapshot directory.
    func ensureModel(id: String, mirrorHost: String, cacheDirectory: URL,
                     progress: @Sendable @escaping (Double) -> Void) async throws -> URL
    /// True iff a complete local snapshot (a `*.safetensors` file) already exists.
    func hasLocalModel(id: String, cacheDirectory: URL) -> Bool
}

public enum DownloaderError: Error, Equatable {
    case allSourcesFailed
    case notFoundLocally
}

/// Canonical on-disk locations (DECISIONS.md 2026-07-18): the app cache lives
/// under Application Support, and existing HuggingFace hub copies are probed for
/// reuse before any download.
public enum MLXModelPaths {
    public static let bundleID = "com.soleilyu.typofree"

    /// `~/Library/Application Support/com.soleilyu.typofree/models`.
    public static var defaultCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: bundleID).appending(path: "models")
    }

    /// `~/.cache/huggingface/hub` — the standard HF CLI cache (probed for reuse).
    public static var huggingFaceHubCache: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".cache").appending(path: "huggingface").appending(path: "hub")
    }
}
