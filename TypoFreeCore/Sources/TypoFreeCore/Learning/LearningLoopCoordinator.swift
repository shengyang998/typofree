import Foundation

// LearningLoopCoordinator — the ONE owner of send-detection sessions and the
// single learning LRU (DESIGN.md §2.7/§4, MF#7/#8). It is the seam the whole
// learning loop hangs off: `InputSession` commits reach it (via the app-shell
// `CommitObserver` bridge) as `recordCommit`; the app-shell `SendDetectionPoller`
// drives `pollOnce`/`ingest` at 1.5 s; on a confirmed send (the field emptied)
// it runs the pure `DiffLearner`, writes the durable `UserDictStore`, and swaps a
// fresh boost snapshot into `OverlayHost` so the next keystroke's
// `ConversionEngine.convert` already sees the learned boost.
//
// Send-detection sessions are keyed by `FieldSignature` (the field being typed
// into is the send-detect unit) and capped at `sessionCap` (5). This is the ONLY
// LRU for learning anywhere — the composition-reconnect `InputSessionCache`
// (app shell) and this are the two distinct caches DESIGN §4 de-duplicated to.
//
// Concurrency: `@MainActor` (it owns mutable session state and swaps the
// MainActor `OverlayHost`), but every field READ runs OFF the MainActor
// (`pollOnce` → `Task.detached`), so Accessibility never touches the typing hot
// path, and every durable WRITE is `await`ed on the actor-isolated
// `UserDictStore`. Session removal happens BEFORE the flush `await`, so a
// re-entrant poll can neither double-flush nor see a stale `isPolling`.

/// One field reading the send-detection poller obtains per tick. A pure Sendable
/// value the app shell fills off the MainActor (AX, 50 ms-capped) and Core
/// classifies. An unresolved element is `signature == nil` / `text == nil`;
/// `isSuppressed` flags a secure/denylisted read seen mid-session — the session
/// is then discarded with NO learning (DESIGN §6).
public struct SendDetectionReading: Sendable, Equatable {
    public let signature: FieldSignature?
    public let text: String?
    public let isSuppressed: Bool
    public init(signature: FieldSignature?, text: String?, isSuppressed: Bool = false) {
        self.signature = signature
        self.text = text
        self.isSuppressed = isSuppressed
    }
}

/// A Sendable handle the poller reads each tick to obtain a field's current
/// value. The app shell's concrete ref re-resolves the system-wide focused
/// element via AX (bounded 50 ms) and reports its signature + text; Core tests
/// inject a scripted fake. `readCurrent` is nonisolated — the poller calls it OFF
/// the MainActor so AX never reaches the per-keystroke path (DESIGN §3).
public protocol SendDetectionPollTargetRef: Sendable {
    func readCurrent() -> SendDetectionReading
}

@MainActor public final class LearningLoopCoordinator {

    /// One field's un-flushed send-detection state.
    private struct Tracked {
        /// Accumulated committed material — what the IME put into this field
        /// (the `DiffLearner` "committedText").
        var committed: String
        var appBundleId: String?
        /// The pure send-detection state machine (its `currentText` accumulates
        /// the last-seen field value — the "finalFieldText" at send).
        var detect: SendDetectionSession
        var pollTarget: any SendDetectionPollTargetRef
        /// Monotonic recency stamp for LRU eviction.
        var recency: UInt64
    }

    private var sessions: [FieldSignature: Tracked] = [:]
    private var recencyCounter: UInt64 = 0

    private let store: UserDictStore
    private let overlayHost: OverlayHost
    private let index: PinyinReadingIndex
    private let encoder: ShuangpinDecoder
    private let lexicon: LexiconStore
    private let sessionCap: Int
    private let diffConfig: DiffLearner.Config

    public init(store: UserDictStore, overlayHost: OverlayHost,
                index: PinyinReadingIndex, encoder: ShuangpinDecoder,
                lexicon: LexiconStore, sessionCap: Int = 5,
                diffConfig: DiffLearner.Config = .init()) {
        self.store = store
        self.overlayHost = overlayHost
        self.index = index
        self.encoder = encoder
        self.lexicon = lexicon
        self.sessionCap = max(1, sessionCap)
        self.diffConfig = diffConfig
    }

    /// True iff at least one un-flushed send-detection session exists — the
    /// `SendDetectionPoller`'s CPU invariant: run the 1.5 s timer ONLY while this
    /// is true, and stop it the instant this goes false (no idle polling).
    public var isPolling: Bool { !sessions.isEmpty }

    /// The number of live send-detection sessions (test seam for the LRU cap).
    var sessionCount: Int { sessions.count }

    // MARK: - Commit contract (MF#7)

    /// Open or extend the send-detection session for the committed field, keyed by
    /// its `FieldSignature`, and record the live poll target. Dropped (learning
    /// stays inert) when the snapshot is a privacy suppression (secure /
    /// denylisted) or carries no field signature — there is no field to
    /// send-detect. Extending an existing field appends the committed material and
    /// refreshes recency + poll target.
    public func recordCommit(committed: String, spans: [WordSpan],
                             sessionID: LearningSessionID, snapshot: ContextSnapshot,
                             pollTarget: any SendDetectionPollTargetRef) {
        guard !snapshot.suppressesLearning, let sig = snapshot.fieldSignature else { return }
        recencyCounter += 1
        if var existing = sessions[sig] {
            existing.committed += committed
            existing.pollTarget = pollTarget
            existing.appBundleId = snapshot.appBundleId ?? existing.appBundleId
            existing.recency = recencyCounter
            sessions[sig] = existing
        } else {
            sessions[sig] = Tracked(committed: committed,
                                    appBundleId: snapshot.appBundleId,
                                    detect: SendDetectionSession(signature: sig, text: committed),
                                    pollTarget: pollTarget,
                                    recency: recencyCounter)
            evictIfNeeded()
        }
    }

    /// Explicitly drop a field's session without learning — a secure-field turn
    /// mid-session, or an input session that closed (DESIGN §6).
    public func discardSession(signature: FieldSignature) {
        sessions[signature] = nil
    }

    // MARK: - Polling (the SendDetectionPoller's shared per-tick body)

    /// The `(signature, target)` pairs the poller reads this tick — one per
    /// un-flushed session.
    public func activePollTargets() -> [(signature: FieldSignature, target: any SendDetectionPollTargetRef)] {
        sessions.map { ($0.key, $0.value.pollTarget) }
    }

    /// Read every active field once and classify it — the poller's per-tick body,
    /// shared so the shell timer is a thin wrapper and Core tests drive ticks
    /// directly. Each field read runs OFF the MainActor (AX off the hot path); the
    /// classify + durable write happen back on the MainActor / store.
    public func pollOnce() async {
        for (sig, target) in activePollTargets() {
            let reading = await Self.readOffMain(target)
            await ingest(signature: sig, reading: reading)
        }
    }

    /// Feed one polled reading into its session. `.textChanged` accumulates the
    /// field text, `.unchanged` is a no-op, `.sessionEnded` (field emptied / focus
    /// moved / element unresolved) flushes the commit→field diff into learning. A
    /// suppressed (secure) read discards the session with no learning.
    public func ingest(signature: FieldSignature, reading: SendDetectionReading) async {
        guard var tracked = sessions[signature] else { return }
        if reading.isSuppressed {
            sessions[signature] = nil                     // secure mid-session → drop, never learn
            return
        }
        let transition = tracked.detect.poll(signature: reading.signature, newText: reading.text)
        switch transition {
        case .unchanged:
            break                                         // detect unmutated — nothing to persist
        case .textChanged:
            sessions[signature] = tracked                 // persist the accumulated field text
        case .sessionEnded:
            let committed = tracked.committed
            let finalText = tracked.detect.currentText
            let bundleId = tracked.appBundleId
            sessions[signature] = nil                     // remove BEFORE awaiting — no double flush
            await flushLearning(committed: committed, finalText: finalText, appBundleId: bundleId)
        }
    }

    // MARK: - Learning pipeline (diff → durable write → atomic overlay swap)

    private func flushLearning(committed: String, finalText: String, appBundleId: String?) async {
        guard committed != finalText else { return }      // no manual edit → nothing to learn
        let outcome = DiffLearner.evaluate(committedText: committed, finalFieldText: finalText,
                                           index: index, encoder: encoder, config: diffConfig)
        if outcome.rejected != nil {
            try? await store.recordEvent(kind: .rejected, appBundleId: appBundleId,
                                         spanBefore: committed, spanAfter: finalText)
            return
        }
        var updates: [BoostUpdate] = []
        for c in outcome.corrections {
            if let update = try? await store.recordCorrection(c) { updates.append(update) }
            try? await store.recordEvent(kind: .correction, appBundleId: appBundleId,
                                         spanBefore: c.wrong, spanAfter: c.right)
        }
        for o in outcome.oovCandidates {
            // "OOV not already in lexicon" filter: a word the base lexicon already
            // lists under this keySeq is NOT out-of-vocabulary — record it as a
            // plain usage boost (no `pending_oov` ledger row); otherwise a real OOV.
            let known = lexicon.postings(forKey: o.keySeq).contains { $0.word == o.word }
            let update: BoostUpdate?
            if known {
                update = try? await store.recordKnownWordReuse(keySeq: o.keySeq, word: o.word)
            } else {
                update = try? await store.recordOOV(o)
                try? await store.recordEvent(kind: .oov, appBundleId: appBundleId,
                                             spanBefore: nil, spanAfter: o.word)
            }
            if let update { updates.append(update) }
        }
        for update in updates { overlayHost.apply(update) }
    }

    // MARK: - LRU eviction (cap `sessionCap`; the ONE learning LRU, DESIGN §4)

    private func evictIfNeeded() {
        // An un-sent field has no reliable final text, so eviction DISCARDS —
        // learning only ever fires on a confirmed send (conservative).
        while sessions.count > sessionCap,
              let lru = sessions.min(by: { $0.value.recency < $1.value.recency })?.key {
            sessions[lru] = nil
        }
    }

    // MARK: - Off-main field read

    private static func readOffMain(_ target: any SendDetectionPollTargetRef) async -> SendDetectionReading {
        await Task.detached { target.readCurrent() }.value
    }
}
