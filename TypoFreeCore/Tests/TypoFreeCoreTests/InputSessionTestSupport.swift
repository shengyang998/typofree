import XCTest
import CoreGraphics
@testable import TypoFreeCore

// Mocks + factory for the M5 InputSession suite (DESIGN.md §2.6/§9). All pure
// and MainActor — zero IMKit/AppKit — so the state machine is exercised with
// synthetic key events and recorded collaborator calls.

@MainActor final class MockTextClient: TextClient {
    var committed: [String] = []
    var lastPreedit: (String, Int)?
    var clearPreeditCount = 0
    var caret = CGRect(x: 100, y: 200, width: 2, height: 16)

    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let addressToken: Int

    init(bundleIdentifier: String? = "com.example.app", pid: pid_t = 4242, addressToken: Int = 0xABCD) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = pid
        self.addressToken = addressToken
    }

    func commit(_ text: String) { committed.append(text) }
    func setPreedit(_ composing: String, cursor: Int) { lastPreedit = (composing, cursor) }
    func clearPreedit() { clearPreeditCount += 1; lastPreedit = nil }
    func caretRectInScreen() -> CGRect { caret }

    var lastCommitted: String? { committed.last }
    var committedJoined: String { committed.joined() }
}

@MainActor final class MockRenderer: CandidateRendering {
    private(set) var showCount = 0
    private(set) var updateSlot1Count = 0
    private(set) var hideCount = 0
    private(set) var lastModel: CandidateBarModel?
    private(set) var lastSlot1Update: Slot1State?
    private(set) var lastHighlight: Int?
    var isVisible = false

    func show(_ model: CandidateBarModel, at caret: CGRect) {
        showCount += 1
        lastModel = model
        isVisible = true
    }
    func updateSlot1(_ state: Slot1State) {
        updateSlot1Count += 1
        lastSlot1Update = state
        if var m = lastModel { m.slot1 = state; lastModel = m }
    }
    func moveHighlight(to index: Int) { lastHighlight = index }
    func hide() { hideCount += 1; isVisible = false }
}

@MainActor final class MockContext: ContextReading {
    var canned: String
    var isSecureContext: Bool
    var snapshot: ContextSnapshot
    private(set) var precedingContextCalls = 0
    private(set) var captureCalls = 0

    init(canned: String = "上文", isSecure: Bool = false, snapshot: ContextSnapshot = .empty) {
        self.canned = canned
        self.isSecureContext = isSecure
        self.snapshot = snapshot
    }

    func precedingContext(for client: (any TextClient)?, maxChars: Int) -> String {
        precedingContextCalls += 1
        return canned
    }
    func captureSnapshot(for client: (any TextClient)?) -> ContextSnapshot {
        captureCalls += 1
        return snapshot
    }
}

@MainActor final class MockCommitObserver: CommitObserver {
    struct Commit { let text: String; let spans: [WordSpan] }
    private(set) var commits: [Commit] = []
    private(set) var sessionEndCount = 0

    func didCommit(committed: String, spans: [WordSpan], sessionID: LearningSessionID, snapshot: ContextSnapshot) {
        commits.append(Commit(text: committed, spans: spans))
    }
    func sessionDidEnd(sessionID: LearningSessionID) { sessionEndCount += 1 }

    var lastCommit: String? { commits.last?.text }
}

/// Builds InputSession test rigs with the REAL conversion engine (real
/// `lexicon.bin`) so routing + the zero-initial traps are exercised end to end.
@MainActor enum SessionRig {
    static func realEngine() throws -> ConversionCandidateEngine {
        let scheme = FlypyScheme.flypy
        let store = try LexiconStore.loadBundled(scheme: scheme)
        let engine = ConversionEngine(lexicon: store, scheme: scheme, config: LatticeConfig())
        return ConversionCandidateEngine(engine: engine)
    }

    static func realCoordinator(provider: any LLMCorrectionProvider,
                                debounce: Duration = .milliseconds(1)) throws -> CorrectionCoordinator {
        let validator = try LLMTestFactory.realValidator()
        return CorrectionCoordinator(provider: provider, validator: validator, debounce: debounce)
    }

    /// A provider whose `correct` never returns — used to hold slot#1 at
    /// `.computing` while events are injected directly (no async race).
    static func hangingProvider() -> ScriptedProvider {
        ScriptedProvider(id: .mlx) { _ in
            try? await Task.sleep(for: .seconds(3600))
            return nil
        }
    }
}
