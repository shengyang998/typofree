import Carbon

// SecureInputMonitor — the app-shell wrapper around Carbon's dynamic
// `IsSecureEventInputEnabled()` authority (DESIGN.md §2.7/§6, DECISIONS.md
// privacy posture). Core's `SecureFieldGuard` deliberately never imports Carbon;
// it takes this as an injected `() -> Bool` closure, so the whole guard stays
// unit-testable with a fake. This is the "先查、零 IPC" dynamic half of the
// secure-field double guard (the static AX marker half lives in `AXContextReader`
// → `SecureFieldGuard.isSensitiveElement`).
struct SecureInputMonitor: Sendable {
    private let probe: @Sendable () -> Bool

    /// Defaults to the real Carbon call; tests inject a stub.
    init(_ probe: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }) {
        self.probe = probe
    }

    /// Whether the system reports secure event input active (a focused
    /// NSSecureTextField, a lock screen, etc.).
    var isActive: Bool { probe() }

    func callAsFunction() -> Bool { probe() }
}
