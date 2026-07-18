// The session's collaboration contracts — DESIGN.md §2.6/§2.7, MF#4/#6/#7.
// `ContextReading` (the one context protocol), `CommitObserver` (the commit
// contract that carries everything learning needs), `LearningSessionID`, and
// `SessionDependencies` (what `InputSession` is injected with). All `@MainActor`;
// the real AX ladder + learning loop conform in later milestones, mocks conform
// in the InputSession test suite.

/// A per-input-session identity for the learning loop (M7). Hashes by the owner
/// object's identity so send-detection sessions can be keyed and evicted.
public struct LearningSessionID: Hashable, Sendable {
    private let id: ObjectIdentifier
    public init(owner: AnyObject) { self.id = ObjectIdentifier(owner) }
}

/// The single context-reading protocol (MF#6). The LLM hot path uses only
/// `precedingContext` (the fast IMKTextInput route, sync-on-MainActor, < 5 ms);
/// `captureSnapshot` runs the fuller (commit-time) read for learning.
@MainActor public protocol ContextReading: AnyObject {
    /// Preceding sentence context for the LLM request. MUST be the fast path
    /// (no deep AX on the typing hot path) — the app's reader downcasts the
    /// `TextClient` to reach the live `IMKTextInput`.
    func precedingContext(for client: (any TextClient)?, maxChars: Int) -> String
    /// Whether the current field is a secure (password/OTP) context.
    var isSecureContext: Bool { get }
    /// The full commit-time snapshot (before/after/signature) for learning.
    func captureSnapshot(for client: (any TextClient)?) -> ContextSnapshot
}

/// The commit contract (MF#7): every commit carries the per-word `WordSpan`s
/// (from `EngineResult.bestPath`, for keySeq attribution), the learning session
/// id, and the commit-time context snapshot.
@MainActor public protocol CommitObserver: AnyObject {
    func didCommit(committed: String, spans: [WordSpan],
                   sessionID: LearningSessionID, snapshot: ContextSnapshot)
    func sessionDidEnd(sessionID: LearningSessionID)
}

/// Everything `InputSession` is injected with. A `@MainActor` value: the engine,
/// coordinator (nil ⇒ Null-only, no async slot#1), context reader, renderer, a
/// weak commit observer, and a closure that reads the current immutable
/// user-boost overlay snapshot (MF#8 — lock-free hot-path read).
@MainActor public struct SessionDependencies {
    public var engine: any CandidateEngine
    public var coordinator: CorrectionCoordinator?
    public var context: any ContextReading
    public var renderer: any CandidateRendering
    public weak var commitObserver: (any CommitObserver)?
    public var overlayProvider: @MainActor () -> UserBoostOverlay
    /// The ≥ N-hanzi gate below which no async correction is requested (slot#1
    /// stays `.unavailable`). Mirrors the coordinator's `minCharsForLLM` so the
    /// session shows `.computing` exactly when the coordinator will actually fire.
    public var minCharsForLLM: Int

    public init(engine: any CandidateEngine,
                coordinator: CorrectionCoordinator?,
                context: any ContextReading,
                renderer: any CandidateRendering,
                commitObserver: (any CommitObserver)?,
                overlayProvider: @escaping @MainActor () -> UserBoostOverlay = { .empty },
                minCharsForLLM: Int = 4) {
        self.engine = engine
        self.coordinator = coordinator
        self.context = context
        self.renderer = renderer
        self.commitObserver = commitObserver
        self.overlayProvider = overlayProvider
        self.minCharsForLLM = minCharsForLLM
    }
}
