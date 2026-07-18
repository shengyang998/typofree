import XCTest
@testable import TypoFreeLLM
import TypoFreeCore

/// M4 (DESIGN.md §2.4/§9) — `LLMBackendResolver` + `LLMProviderFactory`. The
/// pure `decide(...)` covers all FM/MLX/Null branches with faked availability
/// (zero network); the `resolve(...)`/factory paths construct providers without
/// loading (still zero network — the MLX weights are only fetched on `correct`).
final class LLMBackendResolverTests: XCTestCase {

    // MARK: pure decision — the two (three) branches, faked

    func testDecideOffIsAlwaysNull() {
        XCTAssertEqual(LLMBackendResolver.decide(fmAvailable: true, mlxUsable: true, preference: .off), .null)
    }

    func testDecideForcedFoundationModels() {
        XCTAssertEqual(LLMBackendResolver.decide(fmAvailable: true, mlxUsable: false, preference: .foundationModels),
                       .foundationModels)
        XCTAssertEqual(LLMBackendResolver.decide(fmAvailable: false, mlxUsable: true, preference: .foundationModels),
                       .null, "forced FM with FM off falls back to Null")
    }

    func testDecideForcedMLX() {
        XCTAssertEqual(LLMBackendResolver.decide(fmAvailable: false, mlxUsable: true, preference: .mlx), .mlx)
        XCTAssertEqual(LLMBackendResolver.decide(fmAvailable: true, mlxUsable: false, preference: .mlx), .null)
    }

    func testDecideAutoPrefersFMThenMLXThenNull() {
        XCTAssertEqual(LLMBackendResolver.decide(fmAvailable: true, mlxUsable: true, preference: .auto),
                       .foundationModels, "FM branch")
        XCTAssertEqual(LLMBackendResolver.decide(fmAvailable: false, mlxUsable: true, preference: .auto),
                       .mlx, "MLX branch")
        XCTAssertEqual(LLMBackendResolver.decide(fmAvailable: false, mlxUsable: false, preference: .auto),
                       .null, "Null branch")
    }

    // MARK: resolve() → concrete providers, zero network (no load triggered)

    func testResolveOffReturnsNullProvider() async {
        let manager = MLXModelManager(cacheDirectory: LLMTestFixtures.tempCacheDir())
        let provider = await LLMBackendResolver.resolve(mlxManager: manager, preference: .off)
        XCTAssertEqual(provider.id, .null)
    }

    func testResolveMLXReturnsMLXProvider() async {
        let manager = MLXModelManager(cacheDirectory: LLMTestFixtures.tempCacheDir())
        let provider = await LLMBackendResolver.resolve(mlxManager: manager, preference: .mlx)
        XCTAssertEqual(provider.id, .mlx)
    }

    func testResolveAutoOnThisBoxIsNonNull() async {
        // Dev box: Apple Intelligence OFF → auto falls to MLX (usable). If a CI
        // box has FM, .foundationModels is equally valid; either way, non-null.
        let manager = MLXModelManager(cacheDirectory: LLMTestFixtures.tempCacheDir())
        let provider = await LLMBackendResolver.resolve(mlxManager: manager, preference: .auto)
        XCTAssertNotEqual(provider.id, .null)
        if !FoundationModelsSystemAvailability.isAvailable {
            XCTAssertEqual(provider.id, .mlx, "FM off → auto picks MLX")
        }
    }

    // MARK: factory

    func testFactoryMakeProviderMatchesResolve() async {
        let manager = MLXModelManager(cacheDirectory: LLMTestFixtures.tempCacheDir())
        let factory = LLMProviderFactory(mlxManager: manager)
        let off = await factory.makeProvider(preference: .off)
        let mlx = await factory.makeProvider(preference: .mlx)
        XCTAssertEqual(off.id, .null)
        XCTAssertEqual(mlx.id, .mlx)
    }

    func testProbeBackendsListsThree() async {
        let manager = MLXModelManager(cacheDirectory: LLMTestFixtures.tempCacheDir())
        let factory = LLMProviderFactory(mlxManager: manager)
        let statuses = await factory.probeBackends()
        XCTAssertEqual(statuses.map(\.id), [.foundationModels, .mlx, .null])
        // On a fresh temp cache, MLX has no local weights → needsDownload.
        let mlx = statuses.first { $0.id == .mlx }
        XCTAssertEqual(mlx?.availability, .needsDownload(bytes: nil))
    }

    // MARK: M8 — MLX display name derives from the manager's live modelID,
    // never a hardcoded "0.6B" (tasks.md §M8 ModelPreset box).

    func testProbeBackendsMLXDisplayNameDerivesFromLightPreset() async {
        let manager = MLXModelManager(modelID: ModelPreset.light.modelID, cacheDirectory: LLMTestFixtures.tempCacheDir())
        let statuses = await LLMProviderFactory(mlxManager: manager).probeBackends()
        let mlx = statuses.first { $0.id == .mlx }
        XCTAssertEqual(mlx?.displayName, "MLX " + ModelPreset.light.displayName)
        XCTAssertTrue(mlx?.detail.contains("500") ?? false)
    }

    func testProbeBackendsMLXDisplayNameDerivesFromQualityPreset() async {
        let manager = MLXModelManager(modelID: ModelPreset.quality.modelID, cacheDirectory: LLMTestFixtures.tempCacheDir())
        let statuses = await LLMProviderFactory(mlxManager: manager).probeBackends()
        let mlx = statuses.first { $0.id == .mlx }
        XCTAssertEqual(mlx?.displayName, "MLX " + ModelPreset.quality.displayName)
        XCTAssertFalse(mlx?.displayName.contains("0.6B") ?? true, "must not hardcode the light preset's size")
        XCTAssertTrue(mlx?.detail.contains("1.0") ?? false)
    }

    // MARK: thinking is disabled (DECISIONS: NEVER enable thinking)

    func testThinkingIsDisabledInModelContext() {
        XCTAssertEqual(MLXModelManager.thinkingDisabledContext["enable_thinking"] as? Bool, false)
    }
}

/// M8 — the FM `.rateLimited` fallback policy (DECISIONS.md 2026-07-18 user-Q2):
/// default OFF stays silently on FM (already `FoundationModelsCorrectionProvider`'s
/// built-in behavior); the toggle opts into hot-swapping to MLX. Pure decision
/// function, zero network/UI — `AppEnvironment` (app-shell) is the only caller.
final class RateLimitFallbackPolicyTests: XCTestCase {
    func testToggleOffNeverFallsBack() {
        XCTAssertFalse(RateLimitFallbackPolicy.shouldFallBackToMLX(
            activeBackend: .foundationModels, activeAvailability: .unavailable(reason: "rateLimited"),
            toggleEnabled: false, alreadyApplied: false))
    }

    func testToggleOnButNotRateLimitedDoesNotFallBack() {
        XCTAssertFalse(RateLimitFallbackPolicy.shouldFallBackToMLX(
            activeBackend: .foundationModels, activeAvailability: .ready,
            toggleEnabled: true, alreadyApplied: false))
    }

    func testToggleOnAndRateLimitedFallsBack() {
        XCTAssertTrue(RateLimitFallbackPolicy.shouldFallBackToMLX(
            activeBackend: .foundationModels, activeAvailability: .unavailable(reason: "rateLimited"),
            toggleEnabled: true, alreadyApplied: false))
    }

    func testAlreadyAppliedNeverFiresTwice() {
        XCTAssertFalse(RateLimitFallbackPolicy.shouldFallBackToMLX(
            activeBackend: .foundationModels, activeAvailability: .unavailable(reason: "rateLimited"),
            toggleEnabled: true, alreadyApplied: true))
    }

    func testNonFMBackendNeverFallsBack() {
        // Already on MLX (or Null) — the policy is FM-specific.
        XCTAssertFalse(RateLimitFallbackPolicy.shouldFallBackToMLX(
            activeBackend: .mlx, activeAvailability: .unavailable(reason: "rateLimited"),
            toggleEnabled: true, alreadyApplied: false))
    }

    func testOtherUnavailableReasonsDoNotTriggerFallback() {
        // Only the specific "rateLimited" reason triggers — e.g. Apple
        // Intelligence simply being off must not swap providers.
        XCTAssertFalse(RateLimitFallbackPolicy.shouldFallBackToMLX(
            activeBackend: .foundationModels, activeAvailability: .unavailable(reason: "appleIntelligenceNotEnabled"),
            toggleEnabled: true, alreadyApplied: false))
    }
}
