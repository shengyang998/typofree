import Foundation

// CorrectionCoordinator — the single async orchestrator (DESIGN.md §2.4/§3,
// MF#4). Owns debounce, cancellation, the trigger gate (≥ N hanzi / clause
// boundary / debounce), the one D12 gate, and staleness. `InputSession` no
// longer holds a gen-token + Task.sleep; the sole staleness token is
// `requestID`, re-checked once more on the MainActor apply hop (M5).

/// The composition state handed to the coordinator on every change. Built
/// synchronously on the MainActor (fast IMKTextInput context path, §3/§4).
public struct CompositionSnapshot: Sendable {
    public let requestID: UInt64
    public let precedingContext: String
    public let rawPinyin: String
    public let engineBest: String
    /// `engineBest` ends at a clause boundary → fire immediately (skip debounce).
    public let endedClause: Bool
    /// Non-fallback hanzi count → the ≥ `minCharsForLLM` trigger gate.
    public let hanziCount: Int

    public init(requestID: UInt64, precedingContext: String, rawPinyin: String,
                engineBest: String, endedClause: Bool, hanziCount: Int) {
        self.requestID = requestID
        self.precedingContext = precedingContext
        self.rawPinyin = rawPinyin
        self.engineBest = engineBest
        self.endedClause = endedClause
        self.hanziCount = hanziCount
    }
}

/// What slot#1 subscribes to. `corrected == nil` ⇒ slot#1 keeps `engineBest`
/// (declined or gate-rejected — both NORMAL). Only the latest `requestID` is
/// ever emitted; M5 re-checks it again on the MainActor apply hop.
public struct CorrectionEvent: Sendable {
    public let requestID: UInt64
    public let engineBest: String
    public let corrected: String?
    public let backend: LLMBackendID

    public init(requestID: UInt64, engineBest: String, corrected: String?, backend: LLMBackendID) {
        self.requestID = requestID
        self.engineBest = engineBest
        self.corrected = corrected
        self.backend = backend
    }
}

/// Post-processing applied to a provider's RAW output before the D12 gate
/// (DECISIONS.md 2026-07-18): take the first line only, then strip trailing
/// punctuation the model ADDED (`。！？!?`) that `engineBest` didn't already end
/// with. Kept separate + testable.
public enum CorrectionPostProcessor {
    static let strippableTrailingPunctuation: Set<Character> = ["。", "！", "？", "!", "?"]

    public static func normalize(_ raw: String, engineBest: String) -> String {
        let firstLine = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? raw
        var s = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.last, strippableTrailingPunctuation.contains(last), last != engineBest.last {
            s.removeLast()
        }
        return s
    }
}

public actor CorrectionCoordinator {
    private var provider: any LLMCorrectionProvider
    private let validator: CorrectionValidator
    private let config: LatticeConfig
    private let correctionConfig: CorrectionConfig
    private let debounce: Duration
    private let clock: any Clock<Duration>

    private var inFlight: Task<Void, Never>?
    /// The newest requestID seen — the sole staleness token. `nil` after a
    /// `cancelPending()` so no outstanding result can match.
    private var latestRequestID: UInt64?

    private nonisolated let eventStream: AsyncStream<CorrectionEvent>
    private let eventContinuation: AsyncStream<CorrectionEvent>.Continuation

    public init(provider: any LLMCorrectionProvider, validator: CorrectionValidator,
                config: LatticeConfig = .init(),
                debounce: Duration = .milliseconds(500),
                clock: any Clock<Duration> = ContinuousClock()) {
        self.provider = provider
        self.validator = validator
        self.config = config
        self.correctionConfig = CorrectionConfig()
        self.debounce = debounce
        self.clock = clock
        let (stream, continuation) = AsyncStream<CorrectionEvent>.makeStream()
        self.eventStream = stream
        self.eventContinuation = continuation
    }

    /// slot#1's single-consumer subscription.
    public nonisolated var events: AsyncStream<CorrectionEvent> { eventStream }

    /// Every composition change: cancel the in-flight attempt, record the newest
    /// requestID, and — only if the ≥ `minCharsForLLM` gate passes — schedule a
    /// (possibly debounced) correction. Below the gate: no provider call, no event.
    public func onCompositionChanged(_ s: CompositionSnapshot) {
        inFlight?.cancel()
        latestRequestID = s.requestID
        guard s.hanziCount >= config.minCharsForLLM else {
            inFlight = nil
            return
        }
        inFlight = Task { [weak self] in
            await self?.runCorrection(s)
        }
    }

    /// Cancel any in-flight attempt and invalidate every outstanding result.
    public func cancelPending() {
        inFlight?.cancel()
        inFlight = nil
        latestRequestID = nil
    }

    public func prewarm() async {
        await provider.prewarm()
    }

    /// Hot-swap the backend: cancel pending, install the new provider (so new
    /// requests use it immediately), then release the old one's resources.
    public func setProvider(_ p: any LLMCorrectionProvider) async {
        cancelPending()
        let old = provider
        provider = p
        await old.releaseResources()
    }

    // MARK: - Internals

    private func runCorrection(_ s: CompositionSnapshot) async {
        // Debounce unless a clause boundary demands immediate firing.
        if !s.endedClause {
            do {
                try await clock.sleep(for: debounce)
            } catch {
                return // cancelled during debounce
            }
        }
        if Task.isCancelled { return }

        let request = CorrectionRequest(id: s.requestID, precedingContext: s.precedingContext,
                                        rawPinyin: s.rawPinyin, engineBest: s.engineBest)
        let activeProvider = provider
        let raw = await activeProvider.correct(request)

        // Staleness: a newer change (or a cancel) supersedes this result.
        if Task.isCancelled { return }
        guard latestRequestID == s.requestID else { return }

        guard let raw else {
            emit(requestID: s.requestID, engineBest: s.engineBest, corrected: nil, backend: activeProvider.id)
            return
        }
        let normalized = CorrectionPostProcessor.normalize(raw.text, engineBest: s.engineBest)
        let accepted = validator.validate(CorrectionResult(text: normalized, backend: raw.backend),
                                          against: request, config: correctionConfig)
        emit(requestID: s.requestID, engineBest: s.engineBest, corrected: accepted, backend: raw.backend)
    }

    private func emit(requestID: UInt64, engineBest: String, corrected: String?, backend: LLMBackendID) {
        eventContinuation.yield(CorrectionEvent(requestID: requestID, engineBest: engineBest,
                                                corrected: corrected, backend: backend))
    }
}
