import XCTest
@testable import TypoFreeCore

/// M4 (DESIGN.md §2.4/§3/§9, MF#4) — `CorrectionCoordinator`: debounce,
/// cancellation, the ≥N trigger gate, staleness by requestID, timeout→nil, and
/// deadlock-freedom under a stuck provider. All driven by fake providers; zero
/// FM, zero MLX. The coordinator uses a real `ContinuousClock`, so tests bound
/// waits and use long/short debounces to make each property observable without
/// timing races.
final class CorrectionCoordinatorTests: XCTestCase {
    private func validator() throws -> CorrectionValidator { try LLMTestFactory.realValidator() }

    /// A valid 4-hanzi composition (passes the ≥4 gate; the validator accepts
    /// "今天天气" against these codes).
    private func snapshot(id: UInt64, endedClause: Bool = false, hanziCount: Int = 4) -> CompositionSnapshot {
        CompositionSnapshot(requestID: id, precedingContext: "",
                            rawPinyin: LLMTestFactory.codes(["jin", "tian", "tian", "qi"]),
                            engineBest: "今天天气", endedClause: endedClause, hanziCount: hanziCount)
    }

    // MARK: debounce collapses a burst to a single call

    func testDebounceFiresOnlyLatest() async throws {
        let provider = ScriptedProvider { _ in CorrectionResult(text: "今天天气", backend: .mlx) }
        let coord = CorrectionCoordinator(provider: provider, validator: try validator(),
                                          debounce: .milliseconds(150))
        let collector = EventCollector()
        let pump = pumpEvents(coord.events, into: collector)
        defer { pump.cancel() }

        await coord.onCompositionChanged(snapshot(id: 1))
        await coord.onCompositionChanged(snapshot(id: 2))
        await coord.onCompositionChanged(snapshot(id: 3))

        let events = await collector.waitForCount(1, timeout: .seconds(2))
        try? await Task.sleep(for: .milliseconds(200)) // settle: prove no stragglers
        let finalCount = await collector.count()
        let callCount = await provider.callCount
        XCTAssertEqual(finalCount, 1)
        XCTAssertEqual(events.first?.requestID, 3)
        XCTAssertEqual(events.first?.corrected, "今天天气")
        XCTAssertEqual(callCount, 1, "only the surviving id=3 hit the provider")
    }

    // MARK: clause boundary skips the debounce

    func testClauseBoundarySkipsDebounce() async throws {
        // A 10s debounce would make this test time out IF the clause path didn't
        // skip it — arrival within 2s proves immediate firing.
        let provider = ScriptedProvider { _ in CorrectionResult(text: "今天天气", backend: .mlx) }
        let coord = CorrectionCoordinator(provider: provider, validator: try validator(),
                                          debounce: .seconds(10))
        let collector = EventCollector()
        let pump = pumpEvents(coord.events, into: collector)
        defer { pump.cancel() }

        await coord.onCompositionChanged(snapshot(id: 1, endedClause: true))
        let events = await collector.waitForCount(1, timeout: .seconds(2))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.requestID, 1)
    }

    // MARK: a new keystroke cancels the pending correction before it fires

    func testNewInputCancelsPendingBeforeFiring() async throws {
        let provider = ScriptedProvider { _ in CorrectionResult(text: "今天天气", backend: .mlx) }
        let coord = CorrectionCoordinator(provider: provider, validator: try validator(),
                                          debounce: .milliseconds(150))
        let collector = EventCollector()
        let pump = pumpEvents(coord.events, into: collector)
        defer { pump.cancel() }

        await coord.onCompositionChanged(snapshot(id: 1))
        await coord.onCompositionChanged(snapshot(id: 2))
        let events = await collector.waitForCount(1, timeout: .seconds(2))
        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 1, "id=1 was cancelled before it ever hit the provider")
        XCTAssertEqual(events.first?.requestID, 2)
    }

    // MARK: a stale (slow) result for an old requestID never reaches slot#1

    func testStaleResultDroppedByRequestID() async throws {
        let provider = ScriptedProvider { req in
            if req.id == 1 { try? await Task.sleep(for: .milliseconds(250)) }
            return CorrectionResult(text: "今天天气", backend: .mlx)
        }
        let coord = CorrectionCoordinator(provider: provider, validator: try validator(),
                                          debounce: .milliseconds(1))
        let collector = EventCollector()
        let pump = pumpEvents(coord.events, into: collector)
        defer { pump.cancel() }

        await coord.onCompositionChanged(snapshot(id: 1, endedClause: true)) // fires, then stalls
        await coord.onCompositionChanged(snapshot(id: 2, endedClause: true)) // supersedes id=1
        _ = await collector.waitForCount(1, timeout: .seconds(2))
        try? await Task.sleep(for: .milliseconds(400)) // let id=1's late result arrive (if it would)

        let all = await collector.all()
        XCTAssertTrue(all.contains { $0.requestID == 2 })
        XCTAssertTrue(all.allSatisfy { $0.requestID == 2 }, "no event may carry the stale id=1")
    }

    // MARK: provider decline (its internal timeout) → corrected:nil → keep engineBest

    func testProviderDeclineEmitsNilCorrection() async throws {
        let provider = ScriptedProvider { _ in nil } // models a timed-out/failed provider
        let coord = CorrectionCoordinator(provider: provider, validator: try validator(),
                                          debounce: .milliseconds(1))
        let collector = EventCollector()
        let pump = pumpEvents(coord.events, into: collector)
        defer { pump.cancel() }

        await coord.onCompositionChanged(snapshot(id: 1, endedClause: true))
        let events = await collector.waitForCount(1, timeout: .seconds(2))
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.corrected, "nil ⇒ slot#1 keeps engineBest")
        XCTAssertEqual(events.first?.engineBest, "今天天气")
        XCTAssertEqual(events.first?.backend, .mlx)
    }

    // MARK: a rejected correction also emits nil (gate rejections are normal)

    func testGateRejectionEmitsNilCorrection() async throws {
        // Provider hallucinates 世界 — all hanzi, right length, wrong sounds.
        let provider = ScriptedProvider { _ in CorrectionResult(text: "上海名城", backend: .mlx) }
        let coord = CorrectionCoordinator(provider: provider, validator: try validator(),
                                          debounce: .milliseconds(1))
        let collector = EventCollector()
        let pump = pumpEvents(coord.events, into: collector)
        defer { pump.cancel() }

        await coord.onCompositionChanged(snapshot(id: 1, endedClause: true))
        let events = await collector.waitForCount(1, timeout: .seconds(2))
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.corrected, "gate rejected the hallucination → keep engineBest")
    }

    // MARK: below the ≥4 hanzi gate — no provider call, no event

    func testBelowThresholdDoesNotFire() async throws {
        let provider = ScriptedProvider { _ in CorrectionResult(text: "今天天", backend: .mlx) }
        let coord = CorrectionCoordinator(provider: provider, validator: try validator(),
                                          debounce: .milliseconds(1))
        let collector = EventCollector()
        let pump = pumpEvents(coord.events, into: collector)
        defer { pump.cancel() }

        await coord.onCompositionChanged(snapshot(id: 1, hanziCount: 3)) // below minCharsForLLM=4
        try? await Task.sleep(for: .milliseconds(150))
        let callCount = await provider.callCount
        let eventCount = await collector.count()
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(eventCount, 0)
    }

    // MARK: a stuck provider does not deadlock the coordinator

    func testStuckProviderDoesNotDeadlock() async throws {
        let hanging = ScriptedProvider { _ in
            while !Task.isCancelled { await Task.yield() } // hang until cancelled
            return nil
        }
        let coord = CorrectionCoordinator(provider: hanging, validator: try validator(),
                                          debounce: .milliseconds(1))
        let collector = EventCollector()
        let pump = pumpEvents(coord.events, into: collector)
        defer { pump.cancel() }

        await coord.onCompositionChanged(snapshot(id: 1, endedClause: true)) // provider hangs
        // The actor is still responsive while correct() is outstanding:
        await coord.prewarm()

        // Swap in a fast provider (cancels the hung one) and fire again.
        let fast = ScriptedProvider { _ in CorrectionResult(text: "今天天气", backend: .mlx) }
        await coord.setProvider(fast)
        await coord.onCompositionChanged(snapshot(id: 2, endedClause: true))

        let events = await collector.waitForCount(1, timeout: .seconds(2))
        XCTAssertTrue(events.contains { $0.requestID == 2 && $0.corrected == "今天天气" },
                      "id=2 delivered despite the earlier stuck correct()")
        let releaseCount = await hanging.releaseCount
        XCTAssertEqual(releaseCount, 1, "setProvider released the old provider")
    }

    // MARK: cancelPending invalidates outstanding work

    func testCancelPendingStopsInFlight() async throws {
        let provider = ScriptedProvider { req in
            try? await Task.sleep(for: .milliseconds(200))
            return CorrectionResult(text: "今天天气", backend: .mlx)
        }
        let coord = CorrectionCoordinator(provider: provider, validator: try validator(),
                                          debounce: .milliseconds(1))
        let collector = EventCollector()
        let pump = pumpEvents(coord.events, into: collector)
        defer { pump.cancel() }

        await coord.onCompositionChanged(snapshot(id: 1, endedClause: true))
        await coord.cancelPending()
        try? await Task.sleep(for: .milliseconds(400))
        let eventCount = await collector.count()
        XCTAssertEqual(eventCount, 0, "cancelled work must not emit")
    }
}
