// The single `LLMCorrectionProvider` protocol (four drafts converged) — DESIGN.md
// §2.4, MF#3. Every backend conforms; the contract is:
//   • return RAW/unvalidated text, `nil` = declined (unavailable/timeout/
//     cancelled/failed). NullProvider returns nil, never `engineBest`.
//   • the D12 gate runs ONCE in the coordinator, not per-provider.
//   • provider must be `nonisolated`/`actor` and do NO heavy work before its
//     first `await` (concurrency contract §3: `correct()` must never occupy the
//     MainActor).

public protocol LLMCorrectionProvider: Sendable {
    /// Stable backend identity — readable without hopping onto the provider's
    /// executor (so the coordinator can tag events without an `await`).
    nonisolated var id: LLMBackendID { get }
    /// Current readiness, for Settings' backend list.
    func availability() async -> LLMProviderAvailability
    /// Best-effort warm-up (load weights / prewarm a session). Never throws.
    func prewarm() async
    /// Produce a RAW correction, or `nil` to decline. MUST run off the MainActor.
    func correct(_ request: CorrectionRequest) async -> CorrectionResult?
    /// Release any heavy resources (e.g. MLX unloads ~500 MB). Idempotent.
    func releaseResources() async
}

/// Whether the system FoundationModels backend is usable right now. Always
/// present — returns `false` when FoundationModels can't even be imported — so
/// the backend resolver (in TypoFreeLLM) can gate on FM without itself importing
/// the framework or duplicating the `#if canImport` dance.
public enum FoundationModelsSystemAvailability {
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return FoundationModelsCorrectionProvider.isSystemAvailable()
        }
        return false
        #else
        return false
        #endif
    }
}

/// Races an async operation against a timeout. Returns the operation's value if
/// it finishes first, or `nil` if the timeout wins (and cancels the operation).
/// Shared by the timeout-race providers (FM in Core, MLX in TypoFreeLLM) so the
/// "wispr-style silent fallback" lives in exactly one place.
///
/// - Note: relies on the operation honoring cooperative cancellation; a truly
///   uncancellable operation would keep the enclosing task group alive until it
///   returns (structured concurrency awaits all children). Both real backends'
///   inference paths are cancellation-aware.
public func raceWithTimeout<T: Sendable>(
    _ timeout: Duration,
    clock: any Clock<Duration> = ContinuousClock(),
    operation: @Sendable @escaping () async -> T?
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await clock.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
