import Foundation
import TypoFreeCore

// MLXCorrectionProvider — the PRIMARY, load-bearing local backend (DESIGN.md
// §2.4). An `actor` wrapping a `CorrectionModelRunner`, with: on-demand load
// (coalesced), per-correction timeout race (→ nil silent fallback), and idle
// unload with a double-check (a frozen laptop-sleep timer that fires late won't
// unload a just-used model; and it re-arms on every correction).
//
// It never occupies the MainActor: `correct()` runs on this actor and hops into
// the runner (also off-main) — the §3 hard contract.
public actor MLXCorrectionProvider: LLMCorrectionProvider {
    public nonisolated let id: LLMBackendID = .mlx

    private let runner: any CorrectionModelRunner
    private let promptBuilder: CorrectionPromptBuilder
    private let idleUnload: Duration
    private let perCorrectionTimeout: Duration
    private let clock: any Clock<Duration>

    public private(set) var state: MLXModelState = .unloaded
    private var loadTask: Task<Void, Error>?
    private var idleTask: Task<Void, Never>?
    private var lastUsed: Date?

    public init(runner: any CorrectionModelRunner = MLXQwenRunner(),
                promptBuilder: CorrectionPromptBuilder = .init(),
                idleUnload: Duration = .seconds(12 * 60),
                perCorrectionTimeout: Duration = .seconds(2),
                clock: any Clock<Duration> = ContinuousClock()) {
        self.runner = runner
        self.promptBuilder = promptBuilder
        self.idleUnload = idleUnload
        self.perCorrectionTimeout = perCorrectionTimeout
        self.clock = clock
    }

    public func availability() async -> LLMProviderAvailability {
        await runner.availabilityProbe()
    }

    public func prewarm() async {
        try? await loadIfNeeded()
    }

    public func correct(_ request: CorrectionRequest) async -> CorrectionResult? {
        do {
            try await loadIfNeeded()
        } catch {
            return nil // load failed → decline; coordinator keeps engineBest
        }

        let runner = self.runner
        let system = promptBuilder.systemInstructions
        let user = promptBuilder.userPrompt(for: request)

        // Race inference against the per-correction timeout; the operation is
        // @Sendable and captures only Sendable locals (never `self`).
        let text: String? = await raceWithTimeout(perCorrectionTimeout, clock: clock) {
            try? await runner.run(request: request, systemInstructions: system, userPrompt: user)
        }

        lastUsed = Date()
        armIdleUnload()

        guard let text else { return nil }
        return CorrectionResult(text: text, backend: .mlx)
    }

    public func releaseResources() async {
        await unloadNow()
    }

    /// The public idle-unload double-check (also callable on memory pressure):
    /// unload only if real elapsed idle time actually exceeded `idleUnload`.
    public func unloadIfIdle() async {
        guard state == .ready, let lastUsed else { return }
        if Date().timeIntervalSince(lastUsed) >= idleSeconds {
            await unloadNow()
        }
    }

    // MARK: - Internals

    private func loadIfNeeded() async throws {
        if state == .ready, await runner.isLoaded { return }
        if let loadTask { try await loadTask.value; return }

        let runner = self.runner
        let task = Task { try await runner.load(progress: { _ in }) }
        loadTask = task
        state = .loading
        do {
            try await task.value
            state = .ready
            loadTask = nil
        } catch {
            state = .failed(reason: String(describing: error))
            loadTask = nil
            throw error
        }
    }

    /// (Re)arm the idle-unload timer. On fire it re-checks `lastUsed` so a timer
    /// that was frozen by laptop sleep and fires late cannot unload a fresh model.
    private func armIdleUnload() {
        idleTask?.cancel()
        let idle = idleUnload
        let clock = self.clock
        idleTask = Task { [weak self] in
            try? await clock.sleep(for: idle)
            if Task.isCancelled { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadNow() async {
        idleTask?.cancel()
        idleTask = nil
        loadTask?.cancel()
        loadTask = nil
        state = .unloading
        await runner.unload()
        state = .unloaded
        lastUsed = nil
    }

    private var idleSeconds: Double {
        let c = idleUnload.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
