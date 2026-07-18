import CoreGraphics

// CandidateBarModel + Slot1State + CandidateRendering — the candidate-bar wire
// contract. DESIGN.md §2.5, MF#11. The model is a pure `Sendable` value the
// session hands to the renderer; the app's self-drawn `CandidateBarView`
// (NSView.draw) renders it with FIXED slot geometry so slot#1 landing late never
// reflows the bar. Core defines the contract + model; the AppKit drawing lives
// in the app shell.

/// The state of slot#1 — the LLM-corrected sentence candidate.
public enum Slot1State: Sendable, Equatable {
    /// A correction was requested; show the engineBest provisionally with a
    /// spinner while the model runs (100 ms–2 s).
    case computing(provisional: String)
    /// A validated correction landed — show it with the ✦ mark.
    case landed(corrected: String)
    /// No correction available (Null backend, below the gate, declined, or
    /// gate-rejected) — show engineBest plainly, no mark, no spinner.
    case unavailable
}

/// The full candidate-bar model. `highlighted` is an index into the flat visual
/// slot order (0 = slot#1, 1 = slot#2/engineBest, 2+ = `words[i-2]`).
public struct CandidateBarModel: Sendable, Equatable {
    public var slot1: Slot1State
    public var engineBest: String
    public var words: [Candidate]
    public var highlighted: Int

    public init(slot1: Slot1State, engineBest: String, words: [Candidate], highlighted: Int = 0) {
        self.slot1 = slot1
        self.engineBest = engineBest
        self.words = words
        self.highlighted = highlighted
    }

    /// The commit text for a 1-based candidate-bar slot number (the number keys):
    /// 1 → the recommended sentence (landed correction, else engineBest),
    /// 2 → engineBest, 3+ → `words[i-3]`. `nil` when the slot is empty.
    public func commitText(atSlot slot: Int) -> String? {
        switch slot {
        case 1: return recommendedCommitText
        case 2: return engineBest.isEmpty ? nil : engineBest
        default:
            let idx = slot - 3
            guard idx >= 0, idx < words.count else { return nil }
            return words[idx].word
        }
    }

    /// What an explicit accept (Space, number key 1) commits: the landed
    /// correction if one is showing, otherwise the deterministic engineBest.
    public var recommendedCommitText: String {
        if case let .landed(corrected) = slot1 { return corrected }
        return engineBest
    }
}

/// What the session drives to show/update the candidate bar. `@MainActor` +
/// `AnyObject`: the concrete conformer is the app's stateful `CandidatePanel`.
@MainActor public protocol CandidateRendering: AnyObject {
    /// Show the bar for a fresh composition, anchored at the caret rect.
    func show(_ model: CandidateBarModel, at caret: CGRect)
    /// Update ONLY slot#1 in place (no reflow) when the async correction lands.
    func updateSlot1(_ state: Slot1State)
    /// Move the highlight to a flat slot index.
    func moveHighlight(to index: Int)
    /// Hide the bar (composition ended).
    func hide()
    var isVisible: Bool { get }
}
