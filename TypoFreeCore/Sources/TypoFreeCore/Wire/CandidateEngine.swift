// CandidateEngine — the wire protocol the app shell (M5's InputSession) drives
// the conversion engine through. DESIGN.md §2.3/§2.6, MF#3.
//
// `recompute` takes the current immutable `UserBoostOverlay` as a parameter:
// that is the MF#3 fix — the overlay flows *through the wire boundary* into the
// lattice on every keystroke, so a learned boost can never be stranded outside
// conversion. The protocol is `@MainActor` + `AnyObject` because the concrete
// conformer (app shell, M5) is a stateful, main-actor-resident adapter that
// holds the candidate-bar focus and forwards to the pure, `Sendable`
// `ConversionEngine.convert`; it deliberately does NOT take a `focus` argument
// (the conformer owns that state and re-queries via `ConversionEngine.candidates`).
@MainActor public protocol CandidateEngine: AnyObject {
    /// Recompute the full conversion for the raw 小鹤 key buffer, layering the
    /// given user-boost overlay onto the base lexicon.
    func recompute(rawKeys: String, overlay: UserBoostOverlay) -> EngineResult
}
