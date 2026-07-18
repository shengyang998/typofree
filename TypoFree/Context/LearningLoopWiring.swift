import Foundation
import TypoFreeCore

// LearningLoopWiring — the app-shell glue that turns the pure-Core
// `LearningLoopCoordinator` (DESIGN.md §2.7/§4, tasks.md §M7 part 2) into a live
// learning loop:
//
//   • `FocusedFieldPollTarget`  — the real `SendDetectionPollTargetRef`: each tick
//     it re-resolves the system-wide focused field via the bounded (50 ms) AX
//     ladder and reports (signature, text), OR a suppressed reading when the
//     dynamic Carbon secure authority / static AX secure markers / denylist fire.
//   • `SendDetectionPoller`     — the 1.5 s timer that runs ONLY while the
//     coordinator has un-flushed sessions (`isPolling`), driving `pollOnce`. AX
//     reads happen off the MainActor inside `pollOnce`, never on the typing path.
//   • `CommitLearningBridge`    — the `CommitObserver` `InputSession` calls on every
//     commit; it drops secure/no-signature snapshots and otherwise opens/extends
//     the send-detection session and wakes the poller.

/// The real poll target: reads whatever field is focused right now via the AX
/// ladder. Re-resolving the system-wide focus each tick (rather than caching a
/// live `AXUIElement`, which goes stale) is the robust send-detection read — the
/// Core `SendDetectionSession` compares the reported signature against the field
/// this session is bound to. A single stateless instance is shared by every
/// session. Runtime AX behavior is validated on device (M9).
struct FocusedFieldPollTarget: SendDetectionPollTargetRef {
    let reader: any FocusedFieldReading
    let secureInput: SecureInputMonitor
    let denylist: Set<String>
    let maxChars: Int

    func readCurrent() -> SendDetectionReading {
        // Dynamic secure authority first (zero IPC): a secure turn mid-session
        // discards the accumulated span — never learn from a password field.
        if secureInput.isActive {
            return SendDetectionReading(signature: nil, text: nil, isSuppressed: true)
        }
        guard let field = reader.readFocusedField(maxChars: maxChars) else {
            return SendDetectionReading(signature: nil, text: nil)   // unresolved == session ended
        }
        // Static AX secure-marker half + denylist: also a discard, not a learn.
        if CaptureDenylist.contains(field.signature.bundleId, denylist: denylist)
            || SecureFieldGuard.isSensitiveElement(field.markers) {
            return SendDetectionReading(signature: field.signature, text: nil, isSuppressed: true)
        }
        return SendDetectionReading(signature: field.signature, text: field.precedingText)
    }
}

/// Drives `LearningLoopCoordinator.pollOnce` on a 1.5 s cadence — but ONLY while
/// there are un-flushed send-detection sessions. The loop stops the instant the
/// last session flushes (the `isPolling` CPU invariant), and a later commit
/// re-`poke`s it. Everything is `@MainActor` (the coordinator is), yet the actual
/// AX field reads run OFF the MainActor inside `pollOnce`.
@MainActor final class SendDetectionPoller {
    private let coordinator: LearningLoopCoordinator
    private let interval: Duration
    private var loop: Task<Void, Never>?

    init(coordinator: LearningLoopCoordinator, interval: Duration = .milliseconds(1500)) {
        self.coordinator = coordinator
        self.interval = interval
    }

    /// Start the poll loop if it is not already running (idempotent) — called
    /// after each commit opens/extends a session.
    func poke() {
        guard loop == nil, coordinator.isPolling else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        defer { loop = nil }
        while !Task.isCancelled, coordinator.isPolling {
            await coordinator.pollOnce()
            guard coordinator.isPolling else { break }   // last session flushed → stop the timer
            try? await Task.sleep(for: interval)
        }
    }
}

/// The `CommitObserver` `InputSession` fires on every commit. It drops privacy
/// suppressions (secure / denylisted) and commits with no field signature
/// (learning stays inert there — MF#8/§6), otherwise opens/extends the field's
/// send-detection session and wakes the poller. A single stateless poll target is
/// reused for every session (it reads the current focus).
@MainActor final class CommitLearningBridge: CommitObserver {
    private let coordinator: LearningLoopCoordinator
    private let poller: SendDetectionPoller
    private let pollTarget: any SendDetectionPollTargetRef

    init(coordinator: LearningLoopCoordinator, poller: SendDetectionPoller,
         pollTarget: any SendDetectionPollTargetRef) {
        self.coordinator = coordinator
        self.poller = poller
        self.pollTarget = pollTarget
    }

    func didCommit(committed: String, spans: [WordSpan],
                   sessionID: LearningSessionID, snapshot: ContextSnapshot) {
        guard !snapshot.suppressesLearning, snapshot.fieldSignature != nil else { return }
        coordinator.recordCommit(committed: committed, spans: spans, sessionID: sessionID,
                                 snapshot: snapshot, pollTarget: pollTarget)
        poller.poke()
    }

    func sessionDidEnd(sessionID: LearningSessionID) {
        // The poller self-cleans dead fields (an unresolved focused element ==
        // session ended), so no explicit teardown is needed on session close.
    }
}
