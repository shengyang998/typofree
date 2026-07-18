import XCTest
@testable import TypoFreeCore

/// M4 (DESIGN.md §2.4/§9) — `FoundationModelsCorrectionProvider`. On the dev box
/// Apple Intelligence is OFF (region zh_CN), so this is compile-coverage + a
/// runtime smoke test of the "graceful absence" contract: an unavailable FM
/// declines (nil) and the coordinator silently keeps `engineBest`. Never gates
/// on FM being available.
final class FoundationModelsProviderTests: XCTestCase {
    func testAvailabilityIsWellDefinedAndUnavailableFMDeclines() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let provider = FoundationModelsCorrectionProvider()
            switch await provider.availability() {
            case .ready, .unavailable:
                break // both are valid; dev box → .unavailable
            case .availableOnDemand, .needsDownload:
                XCTFail("FM should never report MLX-style on-demand/download states")
            }

            if !FoundationModelsCorrectionProvider.isSystemAvailable() {
                let req = CorrectionRequest(id: 1, precedingContext: "",
                                            rawPinyin: LLMTestFactory.codes(["jin", "tian", "tian", "qi"]),
                                            engineBest: "今天天气")
                let out = await provider.correct(req)
                XCTAssertNil(out, "an unavailable FM must decline, not fabricate")
            }
        } else {
            throw XCTSkip("macOS < 26 has no FoundationModels")
        }
        #else
        throw XCTSkip("FoundationModels not importable on this toolchain")
        #endif
    }

    func testCoordinatorWithUnavailableFMEmitsNilCorrection() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), !FoundationModelsCorrectionProvider.isSystemAvailable() else {
            throw XCTSkip("requires FoundationModels importable + Apple Intelligence OFF (this dev box)")
        }
        let provider = FoundationModelsCorrectionProvider()
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
        let events = await collector.waitForCount(1, timeout: .seconds(2))
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.corrected, "graceful absence: keep engineBest")
        XCTAssertEqual(events.first?.engineBest, "今天天气")
        #else
        throw XCTSkip("FoundationModels not importable on this toolchain")
        #endif
    }
}
