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

    // MARK: thinking is disabled (DECISIONS: NEVER enable thinking)

    func testThinkingIsDisabledInModelContext() {
        XCTAssertEqual(MLXModelManager.thinkingDisabledContext["enable_thinking"] as? Bool, false)
    }
}
