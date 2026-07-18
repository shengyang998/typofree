import Foundation
import TypoFreeCore

// MLXQwenRunner — the production `CorrectionModelRunner`, a thin adapter over an
// `MLXModelManager` (DESIGN.md §2.4). Qwen3-0.6B-4bit, `enable_thinking:false`,
// temperature 0 — all owned by the manager (the single MLX-touching type). The
// runner is a value type; its mutable model state lives in the manager actor.
//
// DESIGN's literal init is `init(downloader:gpuCacheLimitBytes:)`; the extra
// (defaulted) params — `modelID`, `promptBuilder`, `cacheDirectory`,
// `mirrorHost` — are additive so `MLXQwenRunner()` still works, and so the
// factory can share ONE manager with the provider (recorded in notes_for_next).
public struct MLXQwenRunner: CorrectionModelRunner {
    private let manager: MLXModelManager

    public init(downloader: any Downloader = TypoFreeModelDownloader(),
                gpuCacheLimitBytes: Int = 32 * 1024 * 1024,
                modelID: String = "mlx-community/Qwen3-0.6B-4bit",
                promptBuilder: CorrectionPromptBuilder = .init(),
                cacheDirectory: URL = MLXModelPaths.defaultCacheDirectory,
                mirrorHost: String = "hf-mirror.com") {
        self.manager = MLXModelManager(
            modelID: modelID, cacheDirectory: cacheDirectory, mirrorHost: mirrorHost,
            downloader: downloader, promptBuilder: promptBuilder,
            gpuCacheLimitBytes: gpuCacheLimitBytes)
    }

    /// Share an existing manager (used by `LLMProviderFactory` so the resolver's
    /// availability probe and the provider's runner reference the same weights).
    public init(manager: MLXModelManager) {
        self.manager = manager
    }

    public func load(progress: @Sendable @escaping (Double) -> Void) async throws {
        _ = try await manager.loadIfNeeded(progress: progress)
    }

    public func run(request: CorrectionRequest, systemInstructions: String, userPrompt: String) async throws -> String {
        try await manager.run(request: request, systemInstructions: systemInstructions, userPrompt: userPrompt)
    }

    public func unload() async {
        await manager.unload()
    }

    public var isLoaded: Bool {
        get async { await manager.isLoaded }
    }

    public func availabilityProbe() async -> LLMProviderAvailability {
        await manager.availabilityProbe()
    }
}
