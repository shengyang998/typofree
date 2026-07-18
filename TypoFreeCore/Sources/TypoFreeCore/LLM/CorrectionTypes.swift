// The unified LLM-correction value types — DESIGN.md §2.4, MF#3.
//
// These are the single request/result/identity types every backend (FM, MLX,
// Null) and the coordinator speak. Providers return RAW (unvalidated) text; the
// one D12 gate (`CorrectionValidator`) runs once, in the coordinator, backend-
// agnostically. `nil` from `correct` means "declined" — never fabricated text.

/// Which on-device backend produced (or would produce) a correction.
public enum LLMBackendID: String, Sendable, CaseIterable {
    /// Apple FoundationModels (system framework, ~0 MB in-process, preferred).
    case foundationModels
    /// MLX Qwen (on-demand load + idle unload; the load-bearing local backend).
    case mlx
    /// No LLM — Candidate #1 stays `engineBest` (feature silently inert).
    case null
}

/// A backend's runtime readiness, as surfaced to Settings (§2.4 / §7).
public enum LLMProviderAvailability: Sendable, Equatable {
    /// FM available, or MLX already loaded — a `correct` can run immediately.
    case ready
    /// MLX weights are cached but not loaded; the first `correct` loads them.
    case availableOnDemand
    /// MLX weights are missing; first enable downloads them (`bytes` if known).
    case needsDownload(bytes: Int64?)
    /// The backend cannot be used at all (unsupported / not enabled / errored).
    case unavailable(reason: String)
}

/// One correction request. `rawPinyin` (the concatenated 小鹤 keystroke codes of
/// the complete syllables) is the D12 gate anchor: exactly `2 * syllableCount`
/// characters, so `PinyinReadingIndex.canRead` can re-pinyinize the model's
/// output against what the user actually typed.
public struct CorrectionRequest: Sendable, Equatable {
    /// Monotonic id — doubles as cancellation + ordering + staleness token.
    public let id: UInt64
    /// Preceding sentence context (already secure-field-excluded + truncated).
    public let precedingContext: String
    /// The user's actual concatenated 小鹤 codes (the D12 gate anchor).
    public let rawPinyin: String
    /// The deterministic 1-best conversion (fallback + the thing being corrected).
    public let engineBest: String
    /// Generation budget: `min(80, engineBest.count * 2 + 8)`.
    public let maxNewTokens: Int

    public init(id: UInt64, precedingContext: String, rawPinyin: String, engineBest: String, maxNewTokens: Int) {
        self.id = id
        self.precedingContext = precedingContext
        self.rawPinyin = rawPinyin
        self.engineBest = engineBest
        self.maxNewTokens = maxNewTokens
    }

    /// Convenience initializer that derives `maxNewTokens` from `engineBest` per
    /// DESIGN.md §2.4 (`min(80, engineBest.count * 2 + 8)`), so the one formula
    /// lives in one place (the coordinator uses this).
    public init(id: UInt64, precedingContext: String, rawPinyin: String, engineBest: String) {
        self.init(id: id, precedingContext: precedingContext, rawPinyin: rawPinyin,
                  engineBest: engineBest, maxNewTokens: min(80, engineBest.count * 2 + 8))
    }
}

/// A backend's RAW (unvalidated) output. The coordinator post-processes + gates
/// this before it can become Candidate #1; a failing gate is NORMAL operation.
public struct CorrectionResult: Sendable, Equatable {
    /// The raw model string — NOT yet passed through the D12 gate.
    public let text: String
    /// Which backend produced it.
    public let backend: LLMBackendID

    public init(text: String, backend: LLMBackendID) {
        self.text = text
        self.backend = backend
    }
}
