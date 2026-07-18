import XCTest
import Foundation
@testable import TypoFreeCore

// LearningLoopCoordinator (DESIGN.md §2.7/§4, tasks.md §M7 part 2). The ONE
// send-detection owner + learning LRU. These tests drive the full loop headlessly
// with a scripted poll-target fake standing in for the app-shell AX reader:
//   fake commit → poll ticks (field edited, then emptied = sent) → DiffLearner →
//   UserDictStore (real sqlite) → OverlayHost → a real ConversionEngine.convert
//   already sees the learned boost (MF#8 end to end).
// The `isPolling` CPU invariant, the secure-snapshot drop, the LRU cap, and the
// "OOV not already in lexicon" filter are pinned here too.
@MainActor
final class LearningLoopCoordinatorTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
    }

    // MARK: - Fixtures

    /// A scripted poll target: returns the queued readings in order, then a
    /// terminal "unresolved" reading (== session ended). `@unchecked Sendable`
    /// with a lock because the poller reads it off the MainActor.
    private final class FakePollTarget: SendDetectionPollTargetRef, @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [SendDetectionReading]
        init(_ readings: [SendDetectionReading]) { self.queue = readings }
        func readCurrent() -> SendDetectionReading {
            lock.lock(); defer { lock.unlock() }
            return queue.isEmpty ? SendDetectionReading(signature: nil, text: nil) : queue.removeFirst()
        }
    }

    private func makeStore() throws -> UserDictStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typofree-llc-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(dir)
        return try UserDictStore(fileURL: dir.appendingPathComponent("userdict.sqlite"))
    }

    private func makeCoordinator(store: UserDictStore, overlayHost: OverlayHost,
                                 lexicon: LexiconStore, sessionCap: Int = 5) throws
        -> LearningLoopCoordinator {
        let index = try PinyinReadingIndex.loadBundled()
        let decoder = ShuangpinDecoder(scheme: FlypyScheme.flypy)
        return LearningLoopCoordinator(store: store, overlayHost: overlayHost, index: index,
                                       encoder: decoder, lexicon: lexicon, sessionCap: sessionCap)
    }

    private func fixtureLexicon(_ entries: [String: [(word: String, rawCount: Double)]]) throws
        -> LexiconStore {
        try LexiconStore(data: TFX1Fixture.build(entries), scheme: FlypyScheme.flypy)
    }

    private func signature(_ frame: Int) -> FieldSignature {
        FieldSignature(bundleId: "com.apple.TextEdit", pid: 42, role: "AXTextArea",
                       subrole: nil, roundedFrame: RoundedFrame(x: 0, y: 0, width: frame, height: 20))
    }

    private func snapshot(_ sig: FieldSignature?,
                          suppression: CaptureSuppressionReason = .none) -> ContextSnapshot {
        ContextSnapshot(before: "", after: "", appBundleId: "com.apple.TextEdit",
                        fieldSignature: sig, sourceTier: .accessibility,
                        suppressionReason: suppression)
    }

    private func sessionID() -> LearningSessionID { LearningSessionID(owner: NSObject()) }

    private func reading(_ sig: FieldSignature?, _ text: String?,
                         suppressed: Bool = false) -> SendDetectionReading {
        SendDetectionReading(signature: sig, text: text, isSuppressed: suppressed)
    }

    // MARK: - isPolling CPU invariant

    func testIsPollingOnlyWhileUnflushedSessionsExist() async throws {
        let store = try makeStore()
        let coordinator = try makeCoordinator(store: store, overlayHost: OverlayHost(),
                                              lexicon: try fixtureLexicon([:]))
        XCTAssertFalse(coordinator.isPolling, "idle → no polling")

        let sig = signature(100)
        coordinator.recordCommit(committed: "啊", spans: [], sessionID: sessionID(),
                                 snapshot: snapshot(sig),
                                 pollTarget: FakePollTarget([reading(nil, nil)]))
        XCTAssertTrue(coordinator.isPolling, "an un-flushed session → the poller must run")

        await coordinator.pollOnce()   // field already unresolved → session ends immediately
        XCTAssertFalse(coordinator.isPolling, "session flushed → the poller must stop")
    }

    // MARK: - Commit drops (scope 3: suppressesLearning → drop)

    func testRecordCommitDropsSecureSnapshot() async throws {
        let store = try makeStore()
        let coordinator = try makeCoordinator(store: store, overlayHost: OverlayHost(),
                                              lexicon: try fixtureLexicon([:]))
        coordinator.recordCommit(committed: "密码", spans: [], sessionID: sessionID(),
                                 snapshot: snapshot(signature(100), suppression: .secureField),
                                 pollTarget: FakePollTarget([reading(nil, nil)]))
        XCTAssertFalse(coordinator.isPolling, "a secure-field commit must never open a learning session")
        XCTAssertEqual(coordinator.sessionCount, 0)
    }

    func testRecordCommitDropsWhenNoFieldSignature() async throws {
        let store = try makeStore()
        let coordinator = try makeCoordinator(store: store, overlayHost: OverlayHost(),
                                              lexicon: try fixtureLexicon([:]))
        coordinator.recordCommit(committed: "你好", spans: [], sessionID: sessionID(),
                                 snapshot: snapshot(nil),   // IMK-only degrade: no signature
                                 pollTarget: FakePollTarget([reading(nil, nil)]))
        XCTAssertFalse(coordinator.isPolling, "no field signature → nothing to send-detect")
    }

    // MARK: - Secure turn mid-session discards (DESIGN §6)

    func testSuppressedReadMidSessionDiscardsWithoutLearning() async throws {
        let store = try makeStore()
        let coordinator = try makeCoordinator(store: store, overlayHost: OverlayHost(),
                                              lexicon: try fixtureLexicon(["aa": [("啊", 100)]]))
        let sig = signature(100)
        coordinator.recordCommit(committed: "啊", spans: [], sessionID: sessionID(),
                                 snapshot: snapshot(sig),
                                 pollTarget: FakePollTarget([reading(sig, "阿", suppressed: true)]))
        await coordinator.pollOnce()   // the field turned secure mid-edit
        XCTAssertFalse(coordinator.isPolling)
        let overlay = try await store.loadBoostOverlay()
        XCTAssertTrue(overlay.boosts.isEmpty, "a secure turn discards the span — nothing is learned")
    }

    // MARK: - LRU cap 5 (the ONE learning LRU)

    func testLRUCapEvictsOldestBeyondFive() async throws {
        let store = try makeStore()
        let coordinator = try makeCoordinator(store: store, overlayHost: OverlayHost(),
                                              lexicon: try fixtureLexicon([:]), sessionCap: 5)
        for i in 0..<7 {
            coordinator.recordCommit(committed: "字", spans: [], sessionID: sessionID(),
                                     snapshot: snapshot(signature(100 + i)),
                                     pollTarget: FakePollTarget([reading(nil, nil)]))
        }
        XCTAssertEqual(coordinator.sessionCount, 5, "cap 5 — the two oldest fields are evicted")
    }

    // MARK: - End to end: correction → send-detect → learn → convert reorders

    func testEndToEndCorrectionLearnsAndReordersConversion() async throws {
        // A real ConversionEngine over a fixture with 啊 ranked above 阿; two learned
        // 啊→阿 corrections (count 2, boost log 3 ≈ 1.099 > the 0.68 base gap) must
        // flip the ranking through the whole loop.
        let scheme = FlypyScheme.flypy
        let lexicon = try fixtureLexicon(["aa": [("啊", 100), ("阿", 50)]])
        let engine = ConversionEngine(lexicon: lexicon, scheme: scheme, config: LatticeConfig())

        let store = try makeStore()
        let overlayHost = OverlayHost()
        let coordinator = try makeCoordinator(store: store, overlayHost: overlayHost, lexicon: lexicon)

        // Base ranking: 啊 wins with an empty overlay.
        XCTAssertEqual(engine.convert("aa", overlay: .empty, focus: 0).engineBest, "啊")

        let sig = signature(100)
        // Two occurrences: IME commits 啊, the user corrects the field to 阿, then
        // sends (field empties).
        for occurrence in 1...2 {
            let target = FakePollTarget([reading(sig, "阿"), reading(nil, nil)])
            coordinator.recordCommit(committed: "啊", spans: [], sessionID: sessionID(),
                                     snapshot: snapshot(sig), pollTarget: target)
            XCTAssertTrue(coordinator.isPolling)
            await coordinator.pollOnce()   // tick 1: field now holds 阿 (edited)
            await coordinator.pollOnce()   // tick 2: field empty (sent) → flush → learn
            XCTAssertFalse(coordinator.isPolling, "occurrence \(occurrence) flushed")
        }

        // The durable sqlite row surfaced at count 2.
        let persisted = try await store.loadBoostOverlay()
        XCTAssertEqual(persisted.boosts["aa"]?["阿"], Float(log(3.0)), "learned boost persisted to sqlite")
        XCTAssertEqual(overlayHost.current.boosts["aa"]?["阿"], Float(log(3.0)),
                       "overlay host holds the same fresh snapshot")

        // A real convert call, driven by the overlay the loop produced, reorders.
        let reordered = engine.convert("aa", overlay: overlayHost.current, focus: 0)
        XCTAssertEqual(reordered.engineBest, "阿", "the learned correction reordered conversion")
        XCTAssertEqual(reordered.focusCandidates.first?.word, "阿")
        XCTAssertEqual(reordered.focusCandidates.first?.source, .userOverlay)
    }

    func testFirstOccurrenceDoesNotYetBoost() async throws {
        let lexicon = try fixtureLexicon(["aa": [("啊", 100), ("阿", 50)]])
        let store = try makeStore()
        let overlayHost = OverlayHost()
        let coordinator = try makeCoordinator(store: store, overlayHost: overlayHost, lexicon: lexicon)
        let sig = signature(100)

        coordinator.recordCommit(committed: "啊", spans: [], sessionID: sessionID(),
                                 snapshot: snapshot(sig),
                                 pollTarget: FakePollTarget([reading(sig, "阿"), reading(nil, nil)]))
        await coordinator.pollOnce()
        await coordinator.pollOnce()   // one occurrence only → count 1, no boost

        XCTAssertTrue(overlayHost.current.boosts.isEmpty, "occurrence<2 must not affect ranking")
        let correction = DiffLearner.CorrectionCandidate(keySeq: "aa", wrong: "啊", right: "阿",
                                                         contextPinyin: ["a"])
        let pairCount = try await store.correctionPairCount(for: correction)
        XCTAssertEqual(pairCount, 1)
    }

    // MARK: - "OOV not already in lexicon" filter

    func testOOVFilterKnownWordBoostsUnknownWordGoesToPendingLedger() async throws {
        // 外 is already in the base lexicon under "wd"; 王 (wh) is not. Inserting 外
        // must NOT create a pending_oov row (it becomes a plain usage boost);
        // inserting 王 must land in pending_oov.
        let lexicon = try fixtureLexicon(["wd": [("外", 10)]])
        let store = try makeStore()
        let overlayHost = OverlayHost()
        let coordinator = try makeCoordinator(store: store, overlayHost: overlayHost, lexicon: lexicon)

        for _ in 1...2 { try await learnInsertion(coordinator, sig: signature(10), inserted: "外") }
        for _ in 1...2 { try await learnInsertion(coordinator, sig: signature(20), inserted: "王") }

        // Known word: boosted in `words`, but NO pending_oov ledger row.
        let knownPending = try await store.pendingOOVCount(for: .init(keySeq: "wd", word: "外"))
        XCTAssertNil(knownPending, "a known lexicon word is a boost, not a pending OOV")
        XCTAssertEqual(overlayHost.current.boosts["wd"]?["外"], Float(log(3.0)))

        // Unknown word: real OOV → pending_oov ledger + boost.
        let unknownPending = try await store.pendingOOVCount(for: .init(keySeq: "wh", word: "王"))
        XCTAssertEqual(unknownPending, 2)
        XCTAssertEqual(overlayHost.current.boosts["wh"]?["王"], Float(log(3.0)))
    }

    /// Run one insertion occurrence: commit an anchor, poll the field holding the
    /// anchor + inserted word, then empty (sent).
    private func learnInsertion(_ coordinator: LearningLoopCoordinator,
                                sig: FieldSignature, inserted: String) async throws {
        let target = FakePollTarget([reading(sig, "他" + inserted), reading(nil, nil)])
        coordinator.recordCommit(committed: "他", spans: [], sessionID: sessionID(),
                                 snapshot: snapshot(sig), pollTarget: target)
        await coordinator.pollOnce()
        await coordinator.pollOnce()
    }
}
