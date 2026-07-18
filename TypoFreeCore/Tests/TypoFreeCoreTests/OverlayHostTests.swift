import XCTest
@testable import TypoFreeCore

// OverlayHost (DESIGN.md §2.8, MF#8). Holds the current immutable
// UserBoostOverlay and swaps a fresh snapshot in atomically on every delta —
// never mutating an already-handed-out reference.
@MainActor
final class OverlayHostTests: XCTestCase {

    func testApplyProducesFreshImmutableSnapshot() {
        let host = OverlayHost(initial: .empty)
        let before = host.current                                  // captured value snapshot
        host.apply(BoostUpdate(keySeq: "de", word: "得", boost: 1.5))
        XCTAssertTrue(before.boosts.isEmpty)                       // old snapshot untouched
        XCTAssertEqual(host.current.boosts["de"]?["得"], Float(1.5))
    }

    func testApplyMergesWithoutClobbering() {
        let host = OverlayHost(initial: .empty)
        host.apply(BoostUpdate(keySeq: "de", word: "得", boost: 1.5))
        host.apply(BoostUpdate(keySeq: "ni", word: "你", boost: 2.0))
        XCTAssertEqual(host.current.boosts["de"]?["得"], Float(1.5))
        XCTAssertEqual(host.current.boosts["ni"]?["你"], Float(2.0))
    }

    func testApplyOverwritesSameKeyWord() {
        let host = OverlayHost(initial: .empty)
        host.apply(BoostUpdate(keySeq: "de", word: "得", boost: 1.0))
        host.apply(BoostUpdate(keySeq: "de", word: "得", boost: 2.5))
        XCTAssertEqual(host.current.boosts["de"]?["得"], Float(2.5))
        XCTAssertEqual(host.current.boosts["de"]?.count, 1)
    }

    func testReplaceAllSwapsWholeOverlay() {
        let host = OverlayHost(initial: UserBoostOverlay(boosts: ["de": ["得": 1.0]]))
        host.replaceAll(.empty)
        XCTAssertTrue(host.current.boosts.isEmpty)
        XCTAssertEqual(host.snapshot(), host.current)
    }

    func testSnapshotEqualsCurrent() {
        let host = OverlayHost(initial: .empty)
        host.apply(BoostUpdate(keySeq: "de", word: "得", boost: 1.5))
        XCTAssertEqual(host.snapshot(), host.current)
    }
}
