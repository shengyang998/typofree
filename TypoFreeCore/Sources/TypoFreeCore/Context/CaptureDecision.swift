// Capture decision logic — DESIGN.md §2.7/§6, MF#6. Pure functions the app-shell
// context ladder (part 2) drives: (a) the bundle-id denylist of apps we never
// introspect, (b) the suppression reason for a capture attempt, and (c) which
// source tier a read resolved to. All AX-free; the shell feeds live facts.

/// The bundle-id denylist: apps we never introspect at all (they render their
/// own text, and AX reads there are noisy or unwelcome). Default is the two
/// high-confidence terminals (DESIGN §6); users may extend it (part 2 / M8).
public enum CaptureDenylist {
    /// The default denylist: Terminal + iTerm2.
    public static let defaults: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]

    /// Whether `bundleId` is on `denylist`. A `nil` bundle id is never denylisted.
    public static func contains(_ bundleId: String?, denylist: Set<String> = defaults) -> Bool {
        guard let bundleId else { return false }
        return denylist.contains(bundleId)
    }
}

extension ContextSnapshot {
    /// Resolve the suppression reason for a capture attempt, in priority order:
    /// denylist → system secure input → secure field → no source → none. The two
    /// secure signals arrive already OR-ed by `SecureFieldGuard` in the shell.
    public static func resolveSuppression(
        bundleId: String?,
        isSystemSecureInputActive: Bool,
        isSecureField: Bool,
        hasSource: Bool,
        denylist: Set<String> = CaptureDenylist.defaults
    ) -> CaptureSuppressionReason {
        if CaptureDenylist.contains(bundleId, denylist: denylist) { return .denylisted }
        if isSystemSecureInputActive { return .systemSecureInput }
        if isSecureField { return .secureField }
        if !hasSource { return .noSourceAvailable }
        return .none
    }

    /// Whether accumulated learning spans MUST be discarded for this snapshot —
    /// true for the privacy suppressions (denylist + both secure-field guards),
    /// false for a merely-degraded read (`noSourceAvailable`) or `none`.
    public var suppressesLearning: Bool { suppressionReason.isPrivacySuppression }
}

extension CaptureSuppressionReason {
    /// Privacy-driven suppressions where learning MUST discard the span.
    /// `noSourceAvailable` is a degraded read, not a privacy suppression.
    public var isPrivacySuppression: Bool {
        switch self {
        case .denylisted, .systemSecureInput, .secureField: return true
        case .none, .noSourceAvailable: return false
        }
    }
}

extension ContextSourceTier {
    /// Resolve the best available capture tier for the commit-time read ladder
    /// (IMKTextInput → AX → sentence-only). AX gives the deepest before/after
    /// context; IMK is the fast this-sentence fallback; neither → sentence-only.
    public static func resolve(accessibilityAvailable: Bool,
                               imkTextInputAvailable: Bool) -> ContextSourceTier {
        if accessibilityAvailable { return .accessibility }
        if imkTextInputAvailable { return .imkTextInput }
        return .sentenceOnly
    }
}
