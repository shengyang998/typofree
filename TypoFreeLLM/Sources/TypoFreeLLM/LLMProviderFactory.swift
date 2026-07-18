import Foundation
import TypoFreeCore

// Backend resolution + factory + hot-swap (DESIGN.md §2.4/§7). This is the one
// place that sees both the FM side (via Core's always-present availability
// shim) and the MLX side, and turns a user preference into a concrete
// `LLMCorrectionProvider`. The pure `decide(...)` split keeps the FM→MLX→Null
// order unit-testable with faked availability (zero network).

public enum LLMBackendPreference: String, Sendable, Codable, CaseIterable {
    case auto, foundationModels, mlx, off
}

public struct LLMBackendStatus: Sendable, Identifiable {
    public let id: LLMBackendID
    public let availability: LLMProviderAvailability
    public let displayName: String
    public let detail: String

    public init(id: LLMBackendID, availability: LLMProviderAvailability, displayName: String, detail: String) {
        self.id = id
        self.availability = availability
        self.displayName = displayName
        self.detail = detail
    }
}

public struct LLMProviderFactory: Sendable {
    private let promptBuilder: CorrectionPromptBuilder
    private let mlxManager: MLXModelManager

    public init(promptBuilder: CorrectionPromptBuilder = .init(), mlxManager: MLXModelManager) {
        self.promptBuilder = promptBuilder
        self.mlxManager = mlxManager
    }

    /// Build the provider for a preference (`.auto` runs the FM→MLX→Null resolve).
    public func makeProvider(preference: LLMBackendPreference) async -> any LLMCorrectionProvider {
        await LLMBackendResolver.resolve(mlxManager: mlxManager, preference: preference, promptBuilder: promptBuilder)
    }

    /// Force-construct an MLX provider regardless of preference/availability —
    /// used by the FM `.rateLimited` fallback (DECISIONS.md user-Q2): once FM
    /// reports `.rateLimited` and the user's toggle is on, swap directly to MLX
    /// rather than re-running the `.auto` resolve (which would just re-pick FM,
    /// since `FoundationModelsSystemAvailability.isAvailable` is a system-level
    /// check — "is Apple Intelligence enabled", not "is my current session
    /// rate-limited").
    public func makeMLXProvider() -> any LLMCorrectionProvider {
        MLXCorrectionProvider(runner: MLXQwenRunner(manager: mlxManager), promptBuilder: promptBuilder)
    }

    /// The Settings backend list (FM / MLX / Off), each with its availability.
    /// The MLX row's display name + detail derive from the manager's live
    /// `modelID` (via `ModelPreset`) — never a hardcoded "0.6B" (tasks.md §M8).
    public func probeBackends() async -> [LLMBackendStatus] {
        let fmAvailability: LLMProviderAvailability = FoundationModelsSystemAvailability.isAvailable
            ? .ready : .unavailable(reason: "appleIntelligenceUnavailable")
        let mlxAvailability = await mlxManager.availabilityProbe()
        let modelID = mlxManager.modelID
        let mlxDetail = "本地模型 · " + (ModelPreset(modelID: modelID)?.approxMemoryDescription ?? "用时加载")
        return [
            LLMBackendStatus(id: .foundationModels, availability: fmAvailability,
                             displayName: "Apple Intelligence", detail: "系统模型 · 约 0 MB"),
            LLMBackendStatus(id: .mlx, availability: mlxAvailability,
                             displayName: "MLX " + ModelPreset.displayName(forModelID: modelID),
                             detail: mlxDetail),
            LLMBackendStatus(id: .null, availability: .ready,
                             displayName: "关闭", detail: "候选 #1 = 引擎最优句"),
        ]
    }
}

/// The FM `.rateLimited` fallback policy (DECISIONS.md 2026-07-18 user-Q2):
/// default (toggle OFF) is to stay on FM — `FoundationModelsCorrectionProvider`
/// already silently returns `nil` for the rest of the session once rate-limited,
/// so slot#1 degrades to `engineBest` with zero extra wiring. The toggle (default
/// OFF, tasks.md §M8) opts into actively hot-swapping to MLX instead so slot#1
/// keeps getting corrections. This is the pure decision — `AppEnvironment`
/// (app-shell) is the only caller with access to the live coordinator + toggle
/// state, but the policy itself is deterministic and unit-tested here with zero
/// network/UI.
public enum RateLimitFallbackPolicy {
    /// True iff the fallback should fire right now: the toggle is on, the active
    /// backend is FoundationModels, it is reporting `.rateLimited`, and this
    /// session hasn't already applied the fallback (idempotent — only swap once).
    public static func shouldFallBackToMLX(activeBackend: LLMBackendID,
                                           activeAvailability: LLMProviderAvailability,
                                           toggleEnabled: Bool,
                                           alreadyApplied: Bool) -> Bool {
        guard toggleEnabled, !alreadyApplied, activeBackend == .foundationModels else { return false }
        if case .unavailable(let reason) = activeAvailability, reason == "rateLimited" { return true }
        return false
    }
}

public enum LLMBackendResolver {
    /// The pure decision (FM→MLX→Null), split out so both branches are testable
    /// with faked availability — zero network, zero Metal.
    static func decide(fmAvailable: Bool, mlxUsable: Bool, preference: LLMBackendPreference) -> LLMBackendID {
        switch preference {
        case .off:
            return .null
        case .foundationModels:
            return fmAvailable ? .foundationModels : .null
        case .mlx:
            return mlxUsable ? .mlx : .null
        case .auto:
            if fmAvailable { return .foundationModels }
            if mlxUsable { return .mlx }
            return .null
        }
    }

    /// Resolve a concrete provider. `auto`: FM (if Apple Intelligence on) → MLX
    /// (if usable) → Null.
    public static func resolve(mlxManager: MLXModelManager,
                               preference: LLMBackendPreference,
                               promptBuilder: CorrectionPromptBuilder = .init()) async -> any LLMCorrectionProvider {
        let fmAvailable = FoundationModelsSystemAvailability.isAvailable
        let mlxUsable = await mlxManager.isUsable

        switch decide(fmAvailable: fmAvailable, mlxUsable: mlxUsable, preference: preference) {
        case .foundationModels:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                return FoundationModelsCorrectionProvider(promptBuilder: promptBuilder)
            }
            #endif
            return NullProvider()
        case .mlx:
            return MLXCorrectionProvider(runner: MLXQwenRunner(manager: mlxManager), promptBuilder: promptBuilder)
        case .null:
            return NullProvider()
        }
    }
}
