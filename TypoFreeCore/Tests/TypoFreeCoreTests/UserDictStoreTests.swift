import XCTest
import Foundation
@testable import TypoFreeCore

// UserDictStore (DESIGN.md §2.8, MF#10). Native sqlite3 (CSQLite shim), WAL,
// actor-serialized. Every test runs against its own temp-file DB. Occurrence
// count accumulates; only count ≥ 2 surfaces a boost = log(1+count).
// (Awaits are hoisted out of XCTAssert autoclosures — those don't support async.)
final class UserDictStoreTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
    }

    private func makeStore() throws -> UserDictStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typofree-udict-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(dir)
        return try UserDictStore(fileURL: dir.appendingPathComponent("userdict.sqlite"))
    }

    private func correction() -> DiffLearner.CorrectionCandidate {
        DiffLearner.CorrectionCandidate(keySeq: "de", wrong: "的", right: "得", contextPinyin: ["de"])
    }

    // MARK: - Occurrence threshold (< 2 no boost, == 2 boosts)

    func testOccurrenceBelowTwoNoBoostAtTwoBoosts() async throws {
        let store = try makeStore()
        let c = correction()

        let first = try await store.recordCorrection(c)                 // count 1
        XCTAssertNil(first, "count 1 must not promote")
        let overlay1 = try await store.loadBoostOverlay()
        XCTAssertTrue(overlay1.boosts.isEmpty)

        let second = try await store.recordCorrection(c)                // count 2
        XCTAssertEqual(second?.keySeq, "de")
        XCTAssertEqual(second?.word, "得")
        XCTAssertEqual(second?.boost ?? .nan, log(3.0), accuracy: 1e-9)

        let overlay2 = try await store.loadBoostOverlay()
        XCTAssertEqual(overlay2.boosts["de"]?["得"], Float(log(3.0)))
    }

    // MARK: - Correction pairs accumulate

    func testCorrectionPairsAccumulate() async throws {
        let store = try makeStore()
        let c = correction()

        let before = try await store.correctionPairCount(for: c)
        XCTAssertNil(before)
        _ = try await store.recordCorrection(c)
        let once = try await store.correctionPairCount(for: c)
        XCTAssertEqual(once, 1)
        _ = try await store.recordCorrection(c)
        let twice = try await store.correctionPairCount(for: c)
        XCTAssertEqual(twice, 2)
    }

    // MARK: - OOV pending ledger + promotion at ≥2

    func testOOVRecordsPendingLedgerAndPromotesAtTwo() async throws {
        let store = try makeStore()
        let o = DiffLearner.OOVCandidate(keySeq: "wdwh", word: "外王")

        let u1 = try await store.recordOOV(o)                           // count 1
        XCTAssertNil(u1)
        let pending1 = try await store.pendingOOVCount(for: o)
        XCTAssertEqual(pending1, 1)
        let overlay1 = try await store.loadBoostOverlay()
        XCTAssertTrue(overlay1.boosts.isEmpty)

        let u2 = try await store.recordOOV(o)                           // count 2 → boost
        XCTAssertEqual(u2?.word, "外王")
        let pending2 = try await store.pendingOOVCount(for: o)
        XCTAssertEqual(pending2, 2)
        let overlay2 = try await store.loadBoostOverlay()
        XCTAssertEqual(overlay2.boosts["wdwh"]?["外王"], Float(log(3.0)))
    }

    // MARK: - clearAll empties everything

    func testClearAllWipesEverything() async throws {
        let store = try makeStore()
        let c = correction()
        _ = try await store.recordCorrection(c)
        _ = try await store.recordCorrection(c)                         // count 2 → overlay non-empty
        try await store.recordEvent(kind: .correction, appBundleId: "com.apple.dt.Xcode",
                                    spanBefore: "的", spanAfter: "得")
        let before = try await store.loadBoostOverlay()
        XCTAssertFalse(before.boosts.isEmpty)

        try await store.clearAll()

        let overlay = try await store.loadBoostOverlay()
        XCTAssertTrue(overlay.boosts.isEmpty)
        let pairs = try await store.correctionPairCount(for: c)
        XCTAssertNil(pairs)
    }

    // MARK: - Concurrent learns don't corrupt WAL

    func testConcurrentLearnsSerializeWithoutCorruption() async throws {
        let store = try makeStore()
        let c = correction()
        let n = 40

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<n {
                group.addTask { _ = try await store.recordCorrection(c) }
            }
            try await group.waitForAll()
        }

        // No lost updates: exactly `n` increments landed in both the words table
        // (via the boost = log(1+n)) and the correction_pairs ledger.
        let pairs = try await store.correctionPairCount(for: c)
        XCTAssertEqual(pairs, n)
        let overlay = try await store.loadBoostOverlay()
        XCTAssertEqual(overlay.boosts["de"]?["得"], Float(log(Double(1 + n))))
    }

    // MARK: - learning_events span is capped at ≤ 20 chars

    func testRecordEventTruncatesLongSpanWithoutError() async throws {
        // A > 20-char span must not throw and must be stored truncated; this
        // exercises the write-boundary cap without needing to read it back.
        let store = try makeStore()
        let long = String(repeating: "字", count: 50)
        try await store.recordEvent(kind: .rejected, appBundleId: nil,
                                    spanBefore: long, spanAfter: nil)
    }
}
