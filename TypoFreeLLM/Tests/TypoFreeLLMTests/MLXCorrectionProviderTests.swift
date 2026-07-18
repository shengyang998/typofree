import XCTest
@testable import TypoFreeLLM
import TypoFreeCore

/// M4 (DESIGN.md §2.4/§9) — `MLXCorrectionProvider` state machine driven by
/// `FakeModelRunner`: on-demand load (coalesced), per-correction timeout →
/// nil, load-failure → decline, and idle unload with the double-check. Zero
/// Metal, zero network.
final class MLXCorrectionProviderTests: XCTestCase {

    func testCorrectLoadsThenReturnsResult() async throws {
        let runner = FakeModelRunner(response: "今天天气")
        let provider = MLXCorrectionProvider(runner: runner, idleUnload: .seconds(60),
                                             perCorrectionTimeout: .seconds(5))
        let out = await provider.correct(LLMTestFixtures.request(1))
        XCTAssertEqual(out?.text, "今天天气")
        XCTAssertEqual(out?.backend, .mlx)
        let loadCount = await runner.loadCount
        let state = await provider.state
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(state, .ready)
    }

    func testConcurrentCorrectsCoalesceOntoOneLoad() async throws {
        let runner = FakeModelRunner(loadDelay: .milliseconds(60))
        let provider = MLXCorrectionProvider(runner: runner, idleUnload: .seconds(60),
                                             perCorrectionTimeout: .seconds(5))
        async let a = provider.correct(LLMTestFixtures.request(1))
        async let b = provider.correct(LLMTestFixtures.request(2))
        _ = await (a, b)
        let loadCount = await runner.loadCount
        XCTAssertEqual(loadCount, 1, "the single loadTask coalesces concurrent callers")
    }

    func testRunTimeoutReturnsNil() async throws {
        let runner = FakeModelRunner(runDelay: .seconds(5))
        let provider = MLXCorrectionProvider(runner: runner, idleUnload: .seconds(60),
                                             perCorrectionTimeout: .milliseconds(60))
        let out = await provider.correct(LLMTestFixtures.request(1))
        XCTAssertNil(out, "run exceeded perCorrectionTimeout → decline")
    }

    func testLoadFailureDeclinesAndMarksFailed() async throws {
        let runner = FakeModelRunner(loadShouldFail: true)
        let provider = MLXCorrectionProvider(runner: runner)
        let out = await provider.correct(LLMTestFixtures.request(1))
        XCTAssertNil(out)
        let state = await provider.state
        guard case .failed = state else { return XCTFail("expected .failed, got \(state)") }
    }

    func testIdleUnloadAfterTimeout() async throws {
        let runner = FakeModelRunner()
        let provider = MLXCorrectionProvider(runner: runner, idleUnload: .milliseconds(80),
                                             perCorrectionTimeout: .seconds(5))
        _ = await provider.correct(LLMTestFixtures.request(1))
        let readyState = await provider.state
        XCTAssertEqual(readyState, .ready)

        try? await Task.sleep(for: .milliseconds(300)) // > idleUnload
        let unloadCount = await runner.unloadCount
        let finalState = await provider.state
        XCTAssertGreaterThanOrEqual(unloadCount, 1, "model unloaded after the idle window")
        XCTAssertEqual(finalState, .unloaded)
    }

    func testReleaseResourcesUnloads() async throws {
        let runner = FakeModelRunner()
        let provider = MLXCorrectionProvider(runner: runner, idleUnload: .seconds(60),
                                             perCorrectionTimeout: .seconds(5))
        _ = await provider.correct(LLMTestFixtures.request(1))
        await provider.releaseResources()
        let unloadCount = await runner.unloadCount
        let state = await provider.state
        XCTAssertGreaterThanOrEqual(unloadCount, 1)
        XCTAssertEqual(state, .unloaded)
    }

    func testAvailabilityReflectsRunnerProbe() async throws {
        let runner = FakeModelRunner()
        let provider = MLXCorrectionProvider(runner: runner)
        let before = await provider.availability()
        XCTAssertEqual(before, .availableOnDemand) // not loaded yet
        _ = await provider.correct(LLMTestFixtures.request(1))
        let after = await provider.availability()
        XCTAssertEqual(after, .ready)
    }
}
