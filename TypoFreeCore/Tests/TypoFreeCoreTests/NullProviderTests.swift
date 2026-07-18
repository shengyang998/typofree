import XCTest
@testable import TypoFreeCore

/// M4 (DESIGN.md §2.4) — the real `NullProvider` conforming to
/// `LLMCorrectionProvider` (replaces the M0 no-arg placeholder).
final class NullProviderTests: XCTestCase {
    func testDeclinesButReportsReady() async {
        let provider = NullProvider()
        XCTAssertEqual(provider.id, .null)

        let req = CorrectionRequest(id: 1, precedingContext: "", rawPinyin: "nihc", engineBest: "你好")
        let out = await provider.correct(req)
        XCTAssertNil(out, "NullProvider declines (nil), never fabricates engineBest — Candidate #1 stays engineBest")

        let availability = await provider.availability()
        XCTAssertEqual(availability, .ready)
        // These are no-ops but must exist + not throw.
        await provider.prewarm()
        await provider.releaseResources()
    }

    func testUsableThroughExistentialProtocol() async {
        let provider: any LLMCorrectionProvider = NullProvider()
        XCTAssertEqual(provider.id, .null)
        let req = CorrectionRequest(id: 2, precedingContext: "上文", rawPinyin: "nihc", engineBest: "你好")
        let out = await provider.correct(req)
        XCTAssertNil(out)
    }
}

/// M4 (DESIGN.md §3, concurrency risk #2) — provider-isolation hard contract:
/// `correct()` must never execute on the MainActor. Driven FROM the MainActor to
/// prove the coordinator hops off it.
@MainActor
final class CorrectionProviderIsolationTests: XCTestCase {
    func testCorrectNeverRunsOnMainActor() async throws {
        let witness = MainThreadWitness()
        let provider = ScriptedProvider(id: .mlx, witness: witness) { _ in
            CorrectionResult(text: "今天天气", backend: .mlx)
        }
        let coord = CorrectionCoordinator(provider: provider,
                                          validator: try LLMTestFactory.realValidator(),
                                          debounce: .milliseconds(1))
        let collector = EventCollector()
        let pump = pumpEvents(coord.events, into: collector)
        defer { pump.cancel() }

        let snap = CompositionSnapshot(requestID: 1, precedingContext: "",
                                       rawPinyin: LLMTestFactory.codes(["jin", "tian", "tian", "qi"]),
                                       engineBest: "今天天气", endedClause: true, hanziCount: 4)
        await coord.onCompositionChanged(snap)
        _ = await collector.waitForCount(1, timeout: .seconds(2))

        let records = await witness.records
        let ranOnMain = await witness.everRanOnMain
        XCTAssertFalse(records.isEmpty, "correct() must have been invoked")
        XCTAssertFalse(ranOnMain, "correct() must never occupy the MainActor (§3)")
    }
}
