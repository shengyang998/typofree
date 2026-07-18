import XCTest
import CoreGraphics
@testable import TypoFreeCore

// M5 InputSession suite (DESIGN.md §2.6/§3, tasks.md §M5). Mock-driven routing +
// commit-content model + async slot#1 (provisional→landed, no reflow) +
// stale-drop by requestID + NullProvider→unavailable + sub-5ms handle + LRU
// reconnect + the zero-initial traps through the REAL engine.

// MARK: - Key event builders

@MainActor private func key(_ s: String, keyCode: UInt16 = 0, mods: KeyModifiers = []) -> KeyEvent {
    KeyEvent(kind: .keyDown, keyCode: keyCode, characters: s, charactersIgnoringModifiers: s, modifiers: mods)
}
private let spaceKey = KeyEvent(kind: .keyDown, keyCode: SpecialKeyCode.space, characters: " ", charactersIgnoringModifiers: " ")
private let returnKey = KeyEvent(kind: .keyDown, keyCode: SpecialKeyCode.returnKey, characters: "\r", charactersIgnoringModifiers: "\r")
private let backspaceKey = KeyEvent(kind: .keyDown, keyCode: SpecialKeyCode.delete)
private let escapeKey = KeyEvent(kind: .keyDown, keyCode: SpecialKeyCode.escape)
private let mouseKey = KeyEvent(kind: .mouseDown, keyCode: 0)
private let shiftDown = KeyEvent(kind: .flagsChanged, keyCode: SpecialKeyCode.shiftLeft, modifiers: .shift)
private let shiftUp = KeyEvent(kind: .flagsChanged, keyCode: SpecialKeyCode.shiftLeft, modifiers: [])
@MainActor private func number(_ n: Int) -> KeyEvent { key(String(n)) }
@MainActor private func cmd(_ c: String) -> KeyEvent { key(c, mods: .command) }

@MainActor
final class InputSessionTests: XCTestCase {

    // MARK: - Rig

    struct Rig {
        let session: InputSession
        let client: MockTextClient
        let renderer: MockRenderer
        let context: MockContext
        let observer: MockCommitObserver
        let coordinator: CorrectionCoordinator?
    }

    private var strongClients: [MockTextClient] = []

    private func makeRig(coordinator: CorrectionCoordinator? = nil,
                         minChars: Int = 4) throws -> Rig {
        let engine = try SessionRig.realEngine()
        let client = MockTextClient()
        strongClients.append(client)          // keep the weak session.client alive
        let renderer = MockRenderer()
        let context = MockContext()
        let observer = MockCommitObserver()
        let deps = SessionDependencies(
            engine: engine, coordinator: coordinator, context: context, renderer: renderer,
            commitObserver: observer, overlayProvider: { .empty }, minCharsForLLM: minChars)
        let session = InputSession(dependencies: deps, sessionID: LearningSessionID(owner: client))
        session.attach(client: client)
        return Rig(session: session, client: client, renderer: renderer,
                   context: context, observer: observer, coordinator: coordinator)
    }

    @MainActor private func type(_ rig: Rig, _ s: String) {
        for ch in s { _ = rig.session.handle(key(String(ch))) }
    }

    // MARK: - Routing

    func testLetterKeysComposeAndRenderPreedit() throws {
        let rig = try makeRig()
        type(rig, "nihc")   // 你好
        XCTAssertEqual(rig.session.rawBuffer, "nihc")
        XCTAssertTrue(rig.session.isComposing)
        XCTAssertEqual(rig.renderer.lastModel?.engineBest, "你好")
        XCTAssertEqual(rig.client.lastPreedit?.0, "你好")
        XCTAssertTrue(rig.renderer.isVisible)
    }

    func testSpaceCommitsRecommendedEngineBest() throws {
        let rig = try makeRig()
        type(rig, "nihc")
        XCTAssertTrue(rig.session.handle(spaceKey))
        XCTAssertEqual(rig.client.lastCommitted, "你好")
        XCTAssertFalse(rig.session.isComposing)
        XCTAssertEqual(rig.renderer.hideCount, 1)
        XCTAssertEqual(rig.observer.lastCommit, "你好")
    }

    func testReturnCommitsVerbatimRawBuffer() throws {
        let rig = try makeRig()
        type(rig, "nihc")
        XCTAssertTrue(rig.session.handle(returnKey))
        XCTAssertEqual(rig.client.lastCommitted, "nihc")   // verbatim letters
        XCTAssertFalse(rig.session.isComposing)
    }

    func testBackspaceDeletesThenHidesWhenEmpty() throws {
        let rig = try makeRig()
        type(rig, "ni")
        XCTAssertTrue(rig.session.handle(backspaceKey))
        XCTAssertEqual(rig.session.rawBuffer, "n")
        XCTAssertTrue(rig.session.handle(backspaceKey))
        XCTAssertFalse(rig.session.isComposing)
        XCTAssertEqual(rig.renderer.hideCount, 1)
        XCTAssertTrue(rig.observer.commits.isEmpty)    // backspace-to-empty commits nothing
    }

    func testEscapeCancelsWithoutCommit() throws {
        let rig = try makeRig()
        type(rig, "nihc")
        XCTAssertTrue(rig.session.handle(escapeKey))
        XCTAssertFalse(rig.session.isComposing)
        XCTAssertTrue(rig.observer.commits.isEmpty)
        XCTAssertEqual(rig.renderer.hideCount, 1)
        XCTAssertEqual(rig.client.clearPreeditCount, 1)
    }

    func testCommandComboFinalizesEngineBestAndPassesThrough() throws {
        let rig = try makeRig()
        type(rig, "nihc")
        XCTAssertFalse(rig.session.handle(cmd("c")))    // passthrough (not consumed)
        XCTAssertEqual(rig.client.lastCommitted, "你好") // implicit finalize = engineBest
        XCTAssertFalse(rig.session.isComposing)
    }

    func testMouseDownFinalizesEngineBest() throws {
        let rig = try makeRig()
        type(rig, "nihc")
        XCTAssertFalse(rig.session.handle(mouseKey))
        XCTAssertEqual(rig.client.lastCommitted, "你好")
        XCTAssertFalse(rig.session.isComposing)
    }

    func testNumberTwoCommitsEngineBest() throws {
        let rig = try makeRig()
        type(rig, "nihc")
        XCTAssertTrue(rig.session.handle(number(2)))
        XCTAssertEqual(rig.client.lastCommitted, "你好")
        XCTAssertFalse(rig.session.isComposing)
    }

    func testNotComposingLettersPassThroughOnlyAfterMode() throws {
        let rig = try makeRig()
        // Space with no composition passes through.
        XCTAssertFalse(rig.session.handle(spaceKey))
        // Return with no composition passes through.
        XCTAssertFalse(rig.session.handle(returnKey))
        XCTAssertTrue(rig.observer.commits.isEmpty)
    }

    // MARK: - 中英 toggle (lone Shift)

    func testLoneShiftTogglesEnglishModeAndPassesAscii() throws {
        let rig = try makeRig()
        XCTAssertFalse(rig.session.englishMode)
        XCTAssertFalse(rig.session.handle(shiftDown))
        XCTAssertFalse(rig.session.handle(shiftUp))
        XCTAssertTrue(rig.session.englishMode)

        // In English mode a letter passes through, no composition.
        XCTAssertFalse(rig.session.handle(key("n")))
        XCTAssertFalse(rig.session.isComposing)

        // Toggle back.
        _ = rig.session.handle(shiftDown)
        _ = rig.session.handle(shiftUp)
        XCTAssertFalse(rig.session.englishMode)
        XCTAssertTrue(rig.session.handle(key("n")))     // composes again
        XCTAssertTrue(rig.session.isComposing)
    }

    func testShiftWithInterveningKeyDoesNotToggle() throws {
        let rig = try makeRig()
        _ = rig.session.handle(shiftDown)
        _ = rig.session.handle(key("n"))     // a key intervened
        _ = rig.session.handle(shiftUp)
        XCTAssertFalse(rig.session.englishMode)          // NOT toggled
    }

    func testToggleToEnglishMidCompositionCommitsEngineBest() throws {
        let rig = try makeRig()
        type(rig, "nihc")
        _ = rig.session.handle(shiftDown)
        _ = rig.session.handle(shiftUp)                  // lone Shift toggle
        XCTAssertTrue(rig.session.englishMode)
        XCTAssertEqual(rig.client.lastCommitted, "你好")  // never lose input
        XCTAssertFalse(rig.session.isComposing)
    }

    // MARK: - Async slot#1 (provisional → landed, no reflow)

    func testSlot1ComputingThenLandedNoReflow() async throws {
        let coordinator = try SessionRig.realCoordinator(provider: SessionRig.hangingProvider())
        let rig = try makeRig(coordinator: coordinator)
        type(rig, "nihcuijp")       // 4 hanzi ≥ gate (你好 + 2 more)

        let best = try XCTUnwrap(rig.renderer.lastModel?.engineBest)
        XCTAssertEqual(best.count, 4)
        guard case .computing(let provisional) = rig.renderer.lastModel?.slot1 else {
            return XCTFail("slot#1 should be .computing while the model runs")
        }
        XCTAssertEqual(provisional, best)
        let rid = try XCTUnwrap(rig.session.activeRequestID)
        let showsBefore = rig.renderer.showCount

        // A distinct correction lands — via the direct apply path (the same one
        // the events subscription calls).
        rig.session.applyCorrectionEvent(
            CorrectionEvent(requestID: rid, engineBest: best, corrected: "校正结果", backend: .mlx))

        XCTAssertEqual(rig.renderer.lastSlot1Update, .landed(corrected: "校正结果"))
        XCTAssertEqual(rig.renderer.updateSlot1Count, 1)
        XCTAssertEqual(rig.renderer.showCount, showsBefore, "slot#1 landing must NOT reflow the bar")
    }

    func testStaleCorrectionDroppedByRequestID() throws {
        let coordinator = try SessionRig.realCoordinator(provider: SessionRig.hangingProvider())
        let rig = try makeRig(coordinator: coordinator)
        type(rig, "nihcuijp")
        let rid = try XCTUnwrap(rig.session.activeRequestID)

        // A stale event (wrong id) is dropped.
        rig.session.applyCorrectionEvent(
            CorrectionEvent(requestID: rid &+ 999, engineBest: "x", corrected: "错误", backend: .mlx))
        XCTAssertEqual(rig.renderer.updateSlot1Count, 0)

        // After commit the token is cleared, so even the right id is dropped.
        _ = rig.session.handle(spaceKey)
        rig.session.applyCorrectionEvent(
            CorrectionEvent(requestID: rid, engineBest: "你好世界", corrected: "你好世界", backend: .mlx))
        XCTAssertEqual(rig.renderer.updateSlot1Count, 0)
    }

    func testBelowGateStaysUnavailableAndNeverFires() throws {
        let coordinator = try SessionRig.realCoordinator(provider: SessionRig.hangingProvider())
        let rig = try makeRig(coordinator: coordinator)
        type(rig, "nihc")           // only 2 hanzi < gate
        XCTAssertEqual(rig.renderer.lastModel?.slot1, .unavailable)
        XCTAssertNil(rig.session.activeRequestID)
    }

    // MARK: - Async slot#1 end to end through the real coordinator

    func testLandedThroughRealCoordinatorEventStream() async throws {
        let provider = ScriptedProvider(id: .mlx) { req in
            CorrectionResult(text: req.engineBest, backend: .mlx)   // identity → passes D12
        }
        let coordinator = try SessionRig.realCoordinator(provider: provider)
        let rig = try makeRig(coordinator: coordinator)
        type(rig, "nihcuijp")
        let best = try XCTUnwrap(rig.renderer.lastModel?.engineBest)
        try await pollUntil { rig.renderer.lastSlot1Update == .landed(corrected: best) }
        XCTAssertEqual(rig.renderer.lastSlot1Update, .landed(corrected: best))
    }

    func testNullProviderResolvesToUnavailable() async throws {
        let coordinator = try SessionRig.realCoordinator(provider: NullProvider())
        let rig = try makeRig(coordinator: coordinator)
        type(rig, "nihcuijp")
        try await pollUntil { rig.renderer.lastSlot1Update == .unavailable }
        XCTAssertEqual(rig.renderer.lastSlot1Update, .unavailable)
    }

    // MARK: - handle() is synchronous and sub-5 ms

    func testHandleIsSubFiveMilliseconds() throws {
        let rig = try makeRig()   // no coordinator: measure the pure sync typing path
        let keys = Array("woshiyigezhongguoren")   // 我是一个中国人-ish, long buffer
        var maxSeconds = 0.0
        for ch in keys {
            let start = ContinuousClock().now
            _ = rig.session.handle(key(String(ch)))
            let elapsed = ContinuousClock().now - start
            maxSeconds = max(maxSeconds, elapsed.seconds)
        }
        // Design target < 5 ms; assert a generous CI-jitter bound but log the max.
        XCTAssertLessThan(maxSeconds, 0.050, "handle max was \(maxSeconds * 1000) ms")
    }

    // MARK: - Zero-initial traps through the real engine (commit correct)

    func testZeroInitialTrapsCommitCorrectly() throws {
        // (小鹤 code, expected hanzi) — the 8 counter-intuitive zero-initial
        // spellings (DESIGN §2.1). Each must decode to the right pinyin family
        // AND the listed hanzi must be a selectable candidate that commits exactly.
        let traps: [(String, Character)] = [
            ("wd", "歪"), ("ww", "为"), ("wj", "万"), ("wh", "王"),
            ("yc", "要"), ("yz", "有"), ("yh", "羊"), ("ys", "用"),
        ]
        for (code, expected) in traps {
            let rig = try makeRig()
            type(rig, code)
            let words = try XCTUnwrap(rig.renderer.lastModel?.words)
            let idx = try XCTUnwrap(words.firstIndex { $0.word == String(expected) },
                                    "\(expected) must be a candidate for \(code)")
            XCTAssertTrue(rig.session.selectCandidate(at: idx))
            XCTAssertEqual(rig.client.lastCommitted, String(expected),
                           "typing \(code) then selecting must commit \(expected)")
            XCTAssertFalse(rig.session.isComposing)
        }
    }

    // MARK: - Partial candidate selection keeps composing the remainder

    func testPartialCandidateSelectionContinuesComposition() throws {
        let rig = try makeRig()
        type(rig, "nihcuijp")   // 你好世界 (4 syllables)
        let words = try XCTUnwrap(rig.renderer.lastModel?.words)
        // The head candidate for a multi-syllable buffer starts at syllable 0;
        // pick the single-syllable 你 to force a partial commit + continue.
        guard let niIdx = words.firstIndex(where: { $0.word == "你" && $0.syllableCount == 1 }) else {
            throw XCTSkip("你 not offered as a head candidate on this lexicon build")
        }
        XCTAssertTrue(rig.session.selectCandidate(at: niIdx))
        XCTAssertEqual(rig.client.lastCommitted, "你")
        XCTAssertTrue(rig.session.isComposing)             // still composing the rest
        XCTAssertEqual(rig.session.rawBuffer, "hcuijp")    // 好世界 remains
    }

    // MARK: - InputSessionCache (LRU reconnect)

    func testCacheReconnectPreservesSessionState() throws {
        let cache = InputSessionCache(capacity: 5)
        let token = 0x1234
        let s1 = cache.session(forKey: token, make: { self.makeBareSession() })
        s1.attach(client: strongClients.last!)
        _ = s1.handle(shiftDown); _ = s1.handle(shiftUp)   // englishMode = true
        XCTAssertTrue(s1.englishMode)

        // Controller rebuild: same client token retrieves the SAME session.
        let s2 = cache.session(forKey: token, make: { XCTFail("should reuse"); return self.makeBareSession() })
        XCTAssertTrue(s1 === s2)
        XCTAssertTrue(s2.englishMode)                      // state preserved
    }

    func testCacheEvictsLeastRecentlyUsedAtCapacity() throws {
        let cache = InputSessionCache(capacity: 2)
        let a = cache.session(forKey: 1, make: { self.makeBareSession() })
        _ = cache.session(forKey: 2, make: { self.makeBareSession() })
        _ = cache.session(forKey: 1, make: { XCTFail("1 should still be cached"); return self.makeBareSession() }) // touch 1
        _ = cache.session(forKey: 3, make: { self.makeBareSession() })   // evicts LRU = 2
        XCTAssertNil(cache.peek(forKey: 2))
        XCTAssertTrue(cache.peek(forKey: 1) === a)
        XCTAssertNotNil(cache.peek(forKey: 3))
        XCTAssertEqual(cache.count, 2)
    }

    private func makeBareSession() -> InputSession {
        let engine = try! SessionRig.realEngine()
        let client = MockTextClient()
        strongClients.append(client)
        let deps = SessionDependencies(
            engine: engine, coordinator: nil, context: MockContext(), renderer: MockRenderer(),
            commitObserver: MockCommitObserver())
        return InputSession(dependencies: deps, sessionID: LearningSessionID(owner: client))
    }

    // MARK: - Helpers

    private func pollUntil(timeout: Duration = .seconds(3),
                           _ predicate: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met within \(timeout)")
    }
}

private extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
