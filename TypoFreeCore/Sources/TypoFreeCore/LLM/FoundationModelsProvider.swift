// FoundationModelsCorrectionProvider — the preferred backend when Apple
// Intelligence is on (≈0 MB in-process). DESIGN.md §2.4. It lives in Core (a
// system framework, zero extra deps); MLX is what gets isolated in TypoFreeLLM.
//
// The whole file is behind `#if canImport(FoundationModels)`. On this dev box
// the framework IS importable (macOS 26.4 SDK), so this MUST compile against the
// real API — but at runtime `SystemLanguageModel.default.availability ==
// .unavailable(.appleIntelligenceNotEnabled)` (region zh_CN), so `correct` short-
// circuits to `nil` and the coordinator silently falls back to `engineBest`.
// This path is therefore compile-covered + availability-smoke-tested only; it is
// never the M4 gate (DESIGN.md §9).

#if canImport(FoundationModels)
import FoundationModels

/// The constrained single-field output — `@Generable` guarantees the model
/// emits exactly this shape (DESIGN.md "LLM output safety").
@available(macOS 26.0, *)
@Generable
struct Correction {
    @Guide(description: "修正后的中文句子: 同长同义, 只改同音/错别字, 只输出句子本身")
    var text: String
}

@available(macOS 26.0, *)
public actor FoundationModelsCorrectionProvider: LLMCorrectionProvider {
    public nonisolated let id: LLMBackendID = .foundationModels
    private let promptBuilder: CorrectionPromptBuilder
    private let timeout: Duration
    /// Set once FM reports `.rateLimited`; surfaced through `availability()` so
    /// M8's menu-bar/Settings can show it (per DECISIONS Q2 the session silently
    /// degrades to engineBest and does NOT auto-load MLX unless the toggle is on —
    /// that toggle is M8; M4 only structures the error surface).
    private var rateLimitedThisSession = false

    public init(promptBuilder: CorrectionPromptBuilder = .init(), timeout: Duration = .seconds(5)) {
        self.promptBuilder = promptBuilder
        self.timeout = timeout
    }

    public static func isSystemAvailable() -> Bool {
        SystemLanguageModel.default.isAvailable
    }

    public func availability() async -> LLMProviderAvailability {
        if rateLimitedThisSession {
            return .unavailable(reason: "rateLimited")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            return .unavailable(reason: String(describing: reason))
        @unknown default:
            return .unavailable(reason: "unknown")
        }
    }

    public func prewarm() async {
        guard SystemLanguageModel.default.isAvailable else { return }
        let session = LanguageModelSession(instructions: promptBuilder.foundationModelsInstructions())
        session.prewarm()
    }

    public func correct(_ req: CorrectionRequest) async -> CorrectionResult? {
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let instructions = promptBuilder.foundationModelsInstructions()
        let userPrompt = promptBuilder.userPrompt(for: req)
        let maxTokens = req.maxNewTokens
        let timeout = self.timeout

        // Race generation against the timeout. The child tasks are @Sendable and
        // capture only Sendable locals (never `self`); the group body resumes on
        // this actor, so it can fold the outcome + record rate-limiting.
        let outcome: FMOutcome = await withTaskGroup(of: FMOutcome.self) { group in
            group.addTask {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    let options = GenerationOptions(temperature: 0, maximumResponseTokens: maxTokens)
                    let response = try await session.respond(
                        to: userPrompt, generating: Correction.self, options: options)
                    return .text(response.content.text)
                } catch let error as LanguageModelSession.GenerationError {
                    if case .rateLimited = error { return .rateLimited }
                    return .failed
                } catch {
                    return .failed
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }

        switch outcome {
        case .text(let t):
            return CorrectionResult(text: t, backend: .foundationModels)
        case .rateLimited:
            rateLimitedThisSession = true
            return nil
        case .failed, .timedOut:
            return nil
        }
    }

    // XPC-backed; nothing heavy in-process to release.
    public func releaseResources() async {}

    private enum FMOutcome: Sendable {
        case text(String)
        case rateLimited
        case failed
        case timedOut
    }
}
#endif
