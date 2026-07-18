// ConversionCandidateEngine — the concrete `CandidateEngine` (MF#3 wire
// protocol) over the pure `ConversionEngine`. DESIGN.md §2.3/§2.6. A tiny
// `@MainActor` adapter shared by the app shell and the InputSession tests: it
// forwards `recompute(rawKeys:overlay:)` to the pure, `Sendable`
// `ConversionEngine.convert` with focus 0 (the session commits segments
// left-to-right, re-slicing the buffer so the focus is always at the head).
@MainActor public final class ConversionCandidateEngine: CandidateEngine {
    public let engine: ConversionEngine

    public init(engine: ConversionEngine) {
        self.engine = engine
    }

    public func recompute(rawKeys: String, overlay: UserBoostOverlay) -> EngineResult {
        engine.convert(rawKeys, overlay: overlay, focus: 0)
    }
}
