import CoreGraphics

// InputSession — the @MainActor, IMK-free composition state machine. DESIGN.md
// §2.6/§3, MF#4/#7. It routes key events, drives the conversion engine + the
// candidate bar synchronously (sub-ms, never blocking the typing path), and
// hops the LLM correction OFF the MainActor through `CorrectionCoordinator`,
// applying a landed result back ON the MainActor only if its `requestID` still
// matches (the single staleness token). It holds NO IMKit/AppKit types; the app
// shell injects concrete `TextClient`/`CandidateRendering`/`ContextReading`
// conformers, and the InputSession test suite injects mocks.
@MainActor public final class InputSession {
    // MARK: - Injected collaborators
    private let deps: SessionDependencies
    private let sessionID: LearningSessionID
    /// The focused client — weak so we never retain the IMK client (the
    /// `InputSessionCache` retains the *session*, not the client).
    private weak var client: (any TextClient)?

    // MARK: - Public observable state (DESIGN §2.6)
    public private(set) var rawBuffer: String = ""
    public private(set) var englishMode: Bool = false
    public var isComposing: Bool { !rawBuffer.isEmpty }

    // MARK: - Internal state
    private var lastResult: EngineResult?
    private var lastModel: CandidateBarModel?
    /// The requestID of the last fired correction — the MainActor staleness
    /// token. `nil` = nothing in flight for the current composition. Maintained
    /// synchronously so a landed event is dropped the instant the user types
    /// more / commits, regardless of coordinator task ordering. `internal` read
    /// so the InputSession test suite can assert the stale-drop contract.
    private(set) var activeRequestID: UInt64?
    private var nextRequestID: UInt64 = 0
    /// Armed when Shift goes down alone; a lone Shift tap (down-then-up with no
    /// intervening key) toggles 中英 mode.
    private var loneShiftArmed = false

    /// Ordered, non-blocking submission chain to the coordinator actor: each
    /// submission awaits the prior so `onCompositionChanged`/`cancelPending`
    /// reach the coordinator in exactly the order the user typed (the typing
    /// path itself never awaits — `handle` stays synchronous).
    private var submitChain: Task<Void, Never>?
    /// The single events subscription (started on attach, cancelled on detach).
    private var eventTask: Task<Void, Never>?

    public init(dependencies: SessionDependencies, sessionID: LearningSessionID) {
        self.deps = dependencies
        self.sessionID = sessionID
    }

    deinit {
        eventTask?.cancel()
        submitChain?.cancel()
    }

    // MARK: - Client lifecycle

    /// Bind (or re-bind, after a controller rebuild) the focused client. Starts
    /// the events subscription and re-renders any preserved composition.
    public func attach(client: any TextClient) {
        self.client = client
        startObserving()
        if isComposing, let model = lastModel, let result = lastResult {
            client.setPreedit(result.preeditDisplay, cursor: result.preeditCursor)
            deps.renderer.show(model, at: client.caretRectInScreen())
        }
    }

    /// Unbind the client (focus lost / controller closing). Composition state is
    /// preserved in this object for `InputSessionCache` reconnect; the panel hides.
    public func detach() {
        eventTask?.cancel(); eventTask = nil
        deps.renderer.hide()
        client = nil
    }

    // MARK: - Event routing (DESIGN §2.6)

    @discardableResult
    public func handle(_ key: KeyEvent) -> Bool {
        switch key.kind {
        case .flagsChanged:
            return handleFlagsChanged(key)
        case .mouseDown:
            if isComposing { finalizeImplicitly() }
            return false                       // let the click through
        case .keyDown:
            return handleKeyDown(key)
        }
    }

    private func handleKeyDown(_ key: KeyEvent) -> Bool {
        loneShiftArmed = false                 // a key intervened — not a lone Shift

        if englishMode { return false }        // pass ASCII straight through

        // Command combos: implicit-finalize the composition, then pass through.
        if key.modifiers.contains(.command) {
            if isComposing { finalizeImplicitly() }
            return false
        }

        switch key.keyCode {
        case SpecialKeyCode.space:
            if isComposing { commitRecommended(); return true }
            return false
        case SpecialKeyCode.returnKey, SpecialKeyCode.keypadEnter:
            if isComposing { commitVerbatim(); return true }
            return false
        case SpecialKeyCode.delete:
            if isComposing { backspace(); return true }
            return false
        case SpecialKeyCode.escape:
            if isComposing { cancelComposition(); return true }
            return false
        default:
            break
        }

        // Number-key candidate selection (only while composing).
        if isComposing, hasNoShortcutModifier(key), let digit = digit(of: key) {
            return selectSlot(digit)
        }

        // 小鹤 letter key → append + recompute.
        if hasNoShortcutModifier(key), let letter = composeLetter(of: key) {
            appendKey(letter)
            return true
        }

        // Any other key (punctuation, etc.) while composing: finalize engineBest
        // then let the key through to the app.
        if isComposing { finalizeImplicitly() }
        return false
    }

    private func handleFlagsChanged(_ key: KeyEvent) -> Bool {
        let mods = key.modifiers.subtracting(.capsLock)
        if mods == .shift {
            loneShiftArmed = true              // Shift down, nothing else
        } else if mods.isEmpty {
            if loneShiftArmed { toggleEnglishMode() }
            loneShiftArmed = false
        } else {
            loneShiftArmed = false             // some other modifier — disarm
        }
        return false                           // never consume a flagsChanged
    }

    // MARK: - Composition edits

    private func appendKey(_ ch: Character) {
        rawBuffer.append(ch)
        recomputeAndRender()
        scheduleCorrection()
    }

    private func backspace() {
        guard !rawBuffer.isEmpty else { return }
        rawBuffer.removeLast()
        if rawBuffer.isEmpty {
            client?.clearPreedit()
            endComposition()               // buffer empty → hide + invalidate
        } else {
            recomputeAndRender()
            scheduleCorrection()
        }
    }

    private func toggleEnglishMode() {
        if isComposing { finalizeImplicitly() }
        englishMode.toggle()
    }

    // MARK: - Commit paths (DESIGN §2.6 commit content model)

    /// Explicit accept (Space, number 1): the recommended sentence = landed
    /// correction if showing, else engineBest.
    private func commitRecommended() {
        guard let result = lastResult else { return }
        let text = lastModel?.recommendedCommitText ?? result.engineBest
        commitFull(text: text, spans: result.bestPath)
    }

    /// Return: verbatim commit of the raw 小鹤 letters (never lose typed input).
    private func commitVerbatim() {
        commitFull(text: rawBuffer, spans: [])
    }

    /// Implicit finalize (Command / mouse / deactivate / commitComposition):
    /// engineBest ONLY — never an unaccepted async correction (user-Q4).
    public func finalizeImplicitly() {
        guard isComposing, let result = lastResult else {
            if isComposing { commitFull(text: rawBuffer, spans: []) } // no result yet → raw
            return
        }
        commitFull(text: result.engineBest.isEmpty ? rawBuffer : result.engineBest,
                   spans: result.bestPath)
    }

    /// Escape: discard the composition, commit nothing.
    public func cancelComposition() {
        guard isComposing else { return }
        client?.clearPreedit()
        endComposition()
    }

    /// The controller is closing: never lose input (finalize engineBest), then
    /// tell learning the session ended.
    public func sessionWillEnd() {
        if isComposing { finalizeImplicitly() }
        deps.commitObserver?.sessionDidEnd(sessionID: sessionID)
        detach()
    }

    /// Number key n (1-based slot). 1 → recommended, 2 → engineBest, 3+ → word.
    private func selectSlot(_ n: Int) -> Bool {
        switch n {
        case 1:
            commitRecommended()
            return true
        case 2:
            guard let result = lastResult else { return true }
            let text = result.engineBest.isEmpty ? rawBuffer : result.engineBest
            commitFull(text: text, spans: result.bestPath)
            return true
        default:
            return selectCandidate(at: n - 3)
        }
    }

    /// Select a word candidate for the head segment (number keys 3+, or a mouse
    /// click). Commits the word; if it consumes the whole buffer the composition
    /// ends, otherwise the remaining keys keep composing (never lose input).
    @discardableResult
    public func selectCandidate(at index: Int) -> Bool {
        guard isComposing, let result = lastResult,
              index >= 0, index < result.focusCandidates.count else { return false }
        let cand = result.focusCandidates[index]
        let consumedKeys = cand.syllableCount * 2
        let bufferChars = Array(rawBuffer)
        let span = WordSpan(word: cand.word, code: cand.code, range: 0..<cand.syllableCount)

        if consumedKeys >= bufferChars.count {
            commitFull(text: cand.word, spans: [span])
            return true
        }
        // Partial: commit the word, keep composing the remainder.
        client?.commit(cand.word)
        let snapshot = deps.context.captureSnapshot(for: client)
        deps.commitObserver?.didCommit(committed: cand.word, spans: [span],
                                       sessionID: sessionID, snapshot: snapshot)
        invalidateCorrection()
        rawBuffer = String(bufferChars[consumedKeys...])
        recomputeAndRender()
        scheduleCorrection()
        return true
    }

    private func commitFull(text: String, spans: [WordSpan]) {
        client?.commit(text)
        client?.clearPreedit()
        let snapshot = deps.context.captureSnapshot(for: client)
        deps.commitObserver?.didCommit(committed: text, spans: spans,
                                       sessionID: sessionID, snapshot: snapshot)
        endComposition()
    }

    private func endComposition() {
        rawBuffer = ""
        lastResult = nil
        lastModel = nil
        invalidateCorrection()
        deps.renderer.hide()
    }

    // MARK: - Rendering + correction scheduling (concurrency contract §3)

    /// Synchronous, sub-ms: decode + Viterbi (pure), push preedit + the candidate
    /// bar. slot#1 is `.computing` only when a coordinator exists AND the ≥ N
    /// gate passes (so it never spins forever below the gate).
    private func recomputeAndRender() {
        let overlay = deps.overlayProvider()
        let result = deps.engine.recompute(rawKeys: rawBuffer, overlay: overlay)
        lastResult = result

        let slot1: Slot1State
        if deps.coordinator != nil, result.hanziCount >= deps.minCharsForLLM {
            slot1 = .computing(provisional: result.engineBest)
        } else {
            slot1 = .unavailable
        }
        let model = CandidateBarModel(slot1: slot1, engineBest: result.engineBest,
                                      words: result.focusCandidates, highlighted: 0)
        lastModel = model

        client?.setPreedit(result.preeditDisplay, cursor: result.preeditCursor)
        deps.renderer.show(model, at: client?.caretRectInScreen() ?? .zero)
    }

    /// Build the MainActor snapshot (fast context path) and submit it to the
    /// coordinator in order. Below the gate / no coordinator: cancel any in-flight.
    private func scheduleCorrection() {
        guard let coordinator = deps.coordinator, let result = lastResult,
              result.hanziCount >= deps.minCharsForLLM else {
            invalidateCorrection()
            return
        }
        nextRequestID += 1
        let rid = nextRequestID
        activeRequestID = rid
        let ctx = deps.context.precedingContext(for: client, maxChars: 200)
        let rawPinyin = result.syllables.map(\.code).joined()
        let snapshot = CompositionSnapshot(
            requestID: rid, precedingContext: ctx, rawPinyin: rawPinyin,
            engineBest: result.engineBest, endedClause: result.endsAtClauseBoundary,
            hanziCount: result.hanziCount)
        submit(coordinator) { await $0.onCompositionChanged(snapshot) }
    }

    /// Invalidate any in-flight correction synchronously (staleness token), and
    /// tell the coordinator to cancel (ordered, non-blocking).
    private func invalidateCorrection() {
        activeRequestID = nil
        if let coordinator = deps.coordinator {
            submit(coordinator) { await $0.cancelPending() }
        }
    }

    /// Apply a landed correction ON the MainActor — the single staleness check.
    /// Public so both the events subscription and the InputSession tests drive it.
    public func applyCorrectionEvent(_ event: CorrectionEvent) {
        guard let active = activeRequestID, event.requestID == active else { return }
        guard var model = lastModel else { return }
        let newState: Slot1State = event.corrected.map { .landed(corrected: $0) } ?? .unavailable
        model.slot1 = newState
        lastModel = model
        deps.renderer.updateSlot1(newState)     // in place — NO reflow
    }

    // MARK: - Ordered coordinator submission + events subscription

    private func submit(_ coordinator: CorrectionCoordinator,
                        _ op: @escaping @Sendable (CorrectionCoordinator) async -> Void) {
        let prev = submitChain
        submitChain = Task {
            await prev?.value
            await op(coordinator)
        }
    }

    private func startObserving() {
        guard eventTask == nil, let coordinator = deps.coordinator else { return }
        let events = coordinator.events
        eventTask = Task { [weak self] in
            // This Task inherits MainActor isolation from the enclosing
            // @MainActor context, so `applyCorrectionEvent` is a synchronous
            // same-actor call; `for await` still suspends (never blocks) between
            // events. That is exactly the §3 "back to MainActor apply" hop.
            for await event in events {
                self?.applyCorrectionEvent(event)
            }
        }
    }

    // MARK: - Key classification helpers

    private func hasNoShortcutModifier(_ key: KeyEvent) -> Bool {
        key.modifiers.isDisjoint(with: [.command, .control, .option, .function])
    }

    /// The single a–z compose letter for a key (case-folded), else nil.
    private func composeLetter(of key: KeyEvent) -> Character? {
        guard let s = key.charactersIgnoringModifiers, s.count == 1,
              let ch = s.lowercased().first, ch.isASCII, ch.isLetter else { return nil }
        return ch
    }

    /// The 1–9 slot digit for a key, else nil.
    private func digit(of key: KeyEvent) -> Int? {
        guard let s = key.charactersIgnoringModifiers, s.count == 1,
              let ch = s.first, let v = ch.wholeNumberValue, (1...9).contains(v) else { return nil }
        return v
    }
}
