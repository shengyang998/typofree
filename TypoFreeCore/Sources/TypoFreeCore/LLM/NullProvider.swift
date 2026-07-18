// M0 scaffold placeholder.
//
// The real `NullProvider` (DESIGN.md §2.4) conforms to the unified
// `LLMCorrectionProvider` protocol alongside `CorrectionRequest` /
// `CorrectionResult` / `LLMBackendID` / `LLMProviderAvailability` — all of
// that lands in M4 (tasks.md §M4, MF#3) together with the D12 validation
// gate and `CorrectionCoordinator`.
//
// This stub exists only so the `LLM/` module location + async/Sendable
// plumbing compile and are exercised by a green swift test before M4
// replaces it. It already honors the one contract that matters early:
// "no correction" is signaled by `nil`, never by fabricating text — Candidate
// #1 stays `engineBest`.
public struct NullProvider: Sendable {
    public init() {}

    /// Stand-in for the eventual `correct(_:) async -> CorrectionResult?`.
    public func correct() async -> String? { nil }
}
