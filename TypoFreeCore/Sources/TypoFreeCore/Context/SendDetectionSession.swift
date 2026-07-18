// SendDetectionSession — DESIGN.md §2.7/§4, DECISIONS.md send-detection, MF#6. A
// pure, timer-free state machine the app shell (part 2) feeds with polled field
// readings; Core holds NO timer (the shell's `SendDetectionPoller` drives the
// 1.5 s cadence). It tracks the last-seen committed material and classifies each
// poll: the field is unchanged, its text changed, or the session ended (the
// message was sent). Per D7, an unresolved element (`nil` signature or `nil`
// text) == an empty string == `sessionEnded`.
public struct SendDetectionSession: Sendable {

    /// The classification of one poll tick.
    public enum Transition: Sendable, Equatable {
        case unchanged
        case textChanged(String)
        case sessionEnded
    }

    /// The identity of the field this session is bound to — send-detection tells
    /// "same field" from "session ended" by comparing this each poll.
    public let signature: IdentitySignature
    /// The last observed field text — the committed-material accumulation the
    /// learning loop diffs against when the session ends (sent).
    public private(set) var currentText: String
    /// Sticky: once the session has ended, every further poll stays `.sessionEnded`.
    public private(set) var hasEnded: Bool

    public init(signature: IdentitySignature, text: String) {
        self.signature = signature
        self.currentText = text
        self.hasEnded = false
    }

    /// Feed one polled reading. An unresolved element (`signature == nil` or
    /// `newText == nil`), an empty string, or a *different* field identity all
    /// mean the send target is gone → `.sessionEnded` (finalize with
    /// `currentText`). Otherwise: same text → `.unchanged`; new non-empty text →
    /// `.textChanged`, accumulating the new value.
    public mutating func poll(signature: IdentitySignature?, newText: String?) -> Transition {
        if hasEnded { return .sessionEnded }
        guard let sig = signature, let text = newText,
              !text.isEmpty, sig == self.signature else {
            hasEnded = true
            return .sessionEnded
        }
        if text == currentText { return .unchanged }
        currentText = text
        return .textChanged(text)
    }
}
