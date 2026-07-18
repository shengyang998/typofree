// NullProvider — the always-available backend that always declines. DESIGN.md
// §2.4. When it is the active provider, Candidate #1 = `engineBest` and the LLM
// feature is silently inert. Crucially it returns `nil`, never `engineBest`:
// "no correction" is signaled by declining, so the coordinator's one gate + the
// slot#1 state machine (M5) stay uniform across all backends.
public struct NullProvider: LLMCorrectionProvider {
    // A struct has no isolation, so a plain `let` already satisfies the
    // protocol's `nonisolated var id` requirement.
    public let id: LLMBackendID = .null

    public init() {}

    public func availability() async -> LLMProviderAvailability { .ready }
    public func prewarm() async {}
    public func correct(_ request: CorrectionRequest) async -> CorrectionResult? { nil }
    public func releaseResources() async {}
}
