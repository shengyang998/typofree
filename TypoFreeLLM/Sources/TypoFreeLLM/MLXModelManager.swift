import Foundation
import TypoFreeCore
import MLX
import MLXLLM
import MLXLMCommon

// MLXModelManager — the single real MLX model owner (DESIGN.md §2.4). Downloads
// (via `Downloader`) + loads the container, hands out configured `ChatSession`s,
// and can drop the ~500 MB weights on demand. This is the ONLY type that touches
// `ModelContainer`/`ChatSession`/`LLMModelFactory`; `MLXQwenRunner` is a thin
// `CorrectionModelRunner` adapter over it.
//
// The idle-unload TIMER + double-check live in `MLXCorrectionProvider` (per
// DESIGN); this manager exposes an explicit `unloadIfIdle()` + `unload()` and
// tracks `lastUsed`, so both the provider's timer and a memory-pressure handler
// can drive unloading without a second timer here.
public actor MLXModelManager {
    public private(set) var state: MLXModelState = .unloaded

    /// Which model this manager is configured for — `nonisolated` (a `let`, set
    /// once at init) so Settings' picker / menu-bar status can read it without an
    /// `await`, and so display names can derive from it instead of a hardcoded
    /// literal (tasks.md §M8: "displayName 不再硬编码 0.6B"). Switching preset
    /// means building a NEW manager (`AppEnvironment.applyModelPreset`), not
    /// mutating this one — one manager, one model, for its whole lifetime.
    public nonisolated let modelID: String
    private let cacheDirectory: URL
    private let mirrorHost: String
    private let idleTimeout: Duration
    private let downloader: any Downloader
    private let promptBuilder: CorrectionPromptBuilder
    private let gpuCacheLimitBytes: Int

    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    private var lastUsed: Date?

    public init(modelID: String = ModelPreset.light.modelID,
                cacheDirectory: URL,
                mirrorHost: String = "hf-mirror.com",
                idleTimeout: Duration = .seconds(12 * 60),
                downloader: any Downloader = TypoFreeModelDownloader(),
                promptBuilder: CorrectionPromptBuilder = .init(),
                gpuCacheLimitBytes: Int = 32 * 1024 * 1024) {
        self.modelID = modelID
        self.cacheDirectory = cacheDirectory
        self.mirrorHost = mirrorHost
        self.idleTimeout = idleTimeout
        self.downloader = downloader
        self.promptBuilder = promptBuilder
        self.gpuCacheLimitBytes = gpuCacheLimitBytes
    }

    /// MLX is a viable backend unless a prior load hard-failed. (Apple Silicon is
    /// the deployment floor; weights are downloadable on first enable.)
    public var isUsable: Bool {
        if case .failed = state { return false }
        return true
    }

    public var isLoaded: Bool { container != nil }

    public func availabilityProbe() -> LLMProviderAvailability {
        if container != nil { return .ready }
        if wouldHitLocalCache() { return .availableOnDemand }
        return .needsDownload(bytes: nil)
    }

    /// Whether the NEXT `loadIfNeeded` would be satisfied entirely from a local
    /// cache (app cache / HF hub cache / `~/Documents/huggingface`) with no
    /// network — the honest "local-cache-hit state" `ModelDownloadView` shows
    /// (tasks.md §M8) without threading a live source signal through the
    /// `Downloader` protocol.
    public func wouldHitLocalCache() -> Bool {
        downloader.hasLocalModel(id: modelID, cacheDirectory: cacheDirectory)
    }

    /// Load the container if needed, coalescing concurrent callers onto one task.
    @discardableResult
    public func loadIfNeeded(progress: (@Sendable (Double) -> Void)? = nil) async throws -> ModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }

        let modelID = self.modelID
        let mirror = self.mirrorHost
        let cacheDir = self.cacheDirectory
        let downloader = self.downloader
        let gpuLimit = self.gpuCacheLimitBytes
        let task = Task { () throws -> ModelContainer in
            let dir = try await downloader.ensureModel(
                id: modelID, mirrorHost: mirror, cacheDirectory: cacheDir,
                progress: { f in progress?(f) })
            // Constrain the Metal buffer cache so a long IME session doesn't grow
            // GPU memory unbounded on the 8 GB target.
            Memory.cacheLimit = gpuLimit
            return try await LLMModelFactory.shared.loadContainer(
                configuration: ModelConfiguration(directory: dir),
                progressHandler: { p in progress?(p.fractionCompleted) })
        }
        loadTask = task
        state = .loading
        do {
            let loaded = try await task.value
            container = loaded
            state = .ready
            loadTask = nil
            lastUsed = Date()
            return loaded
        } catch {
            state = .failed(reason: String(describing: error))
            loadTask = nil
            throw error
        }
    }

    /// A bare `ChatSession` over the loaded container (DESIGN signature). Callers
    /// that want few-shot priming should use `run(...)`.
    public func acquireSession(progress: (@Sendable (Double) -> Void)?) async throws -> ChatSession {
        let container = try await loadIfNeeded(progress: progress)
        lastUsed = Date()
        return ChatSession(container)
    }

    /// One correction turn: a fresh few-shot-primed session (temperature 0,
    /// thinking OFF), so repeated corrections never accumulate history. The
    /// `ChatSession` (not Sendable) is built + consumed inside a `nonisolated`
    /// helper that takes only Sendable args, so it never crosses this actor's
    /// boundary (Swift 6 strict-concurrency safe).
    public func run(request: CorrectionRequest, systemInstructions: String, userPrompt: String) async throws -> String {
        let container = try await loadIfNeeded()
        lastUsed = Date()
        return try await Self.generate(
            container: container, instructions: systemInstructions,
            fewShots: promptBuilder.fewShots, maxTokens: request.maxNewTokens, userPrompt: userPrompt)
    }

    /// The chat-template context that disables Qwen3 thinking (DECISIONS.md:
    /// NEVER enable thinking). Exposed for the live test's assertion.
    public nonisolated static let thinkingDisabledContext: [String: any Sendable] = ["enable_thinking": false]

    private nonisolated static func generate(
        container: ModelContainer, instructions: String,
        fewShots: [CorrectionPromptBuilder.Shot], maxTokens: Int, userPrompt: String
    ) async throws -> String {
        var params = GenerateParameters(temperature: 0)
        params.maxTokens = maxTokens
        let history = fewShots.flatMap { shot in
            [Chat.Message.user(shot.user), Chat.Message.assistant(shot.assistant)]
        }
        let session = ChatSession(
            container, instructions: instructions, history: history,
            generateParameters: params, additionalContext: thinkingDisabledContext)
        return try await session.respond(to: userPrompt)
    }

    /// Unload only if genuinely idle (guards a frozen-then-late idle timer by
    /// re-checking real elapsed wall time via `lastUsed`).
    public func unloadIfIdle() async {
        guard container != nil, let lastUsed else { return }
        if Date().timeIntervalSince(lastUsed) >= idleSeconds {
            await unload()
        }
    }

    public func unload() async {
        loadTask?.cancel()
        loadTask = nil
        guard container != nil else { state = .unloaded; return }
        state = .unloading
        container = nil
        lastUsed = nil
        MLX.Memory.clearCache()
        state = .unloaded
    }

    // MARK: - Internals

    private var idleSeconds: Double {
        let c = idleTimeout.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
