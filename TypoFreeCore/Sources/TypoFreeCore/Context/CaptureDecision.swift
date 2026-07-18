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

extension ContextSnapshot {
    /// Assemble a commit-time snapshot from already-gathered facts — the pure
    /// decision the app-shell context ladder (M6 part 2) delegates to after it
    /// has done its AX/IMK reads. Keeping this in Core (MF#6: "AX 触碰代码全出
    /// Core，Core 只留纯值+纯逻辑") makes the security-critical contract unit-testable
    /// with zero live AX:
    ///   - the source tier is AX (when `axPrecedingText != nil`) → IMK (when the
    ///     fast path returned text) → sentence-only;
    ///   - a privacy suppression (denylist / system-secure-input / secure field)
    ///     BLANKS `before` so learning stays inert, while still carrying the field
    ///     signature (identity only, no content) for send-detection — except a
    ///     denylisted app, which we never introspect, so its signature is dropped.
    /// - Parameters:
    ///   - axPrecedingText: the AX-read preceding context, or `nil` if AX was
    ///     untrusted / denylisted / unresolved (already capped by the reader).
    ///   - imkPrecedingText: the fast IMKTextInput preceding context (may be "").
    public static func assemble(
        bundleId: String?,
        axPrecedingText: String?,
        imkPrecedingText: String,
        fieldSignature: FieldSignature?,
        isSystemSecureInputActive: Bool,
        isSecureField: Bool,
        maxChars: Int,
        denylist: Set<String> = CaptureDenylist.defaults
    ) -> ContextSnapshot {
        let hasAX = axPrecedingText != nil
        let hasIMK = !imkPrecedingText.isEmpty
        let suppression = resolveSuppression(
            bundleId: bundleId,
            isSystemSecureInputActive: isSystemSecureInputActive,
            isSecureField: isSecureField,
            hasSource: hasAX || hasIMK,
            denylist: denylist)
        let tier = ContextSourceTier.resolve(accessibilityAvailable: hasAX,
                                             imkTextInputAvailable: hasIMK)
        let rawBefore = hasAX ? (axPrecedingText ?? "") : imkPrecedingText
        let before = suppression.isPrivacySuppression ? "" : String(rawBefore.suffix(maxChars))
        let signature = (suppression == .denylisted) ? nil : fieldSignature
        return ContextSnapshot(before: before, after: "", appBundleId: bundleId,
                               fieldSignature: signature, sourceTier: tier,
                               suppressionReason: suppression)
    }
}
