import CoreGraphics

// Pure context value types — DESIGN.md §2.7, MF#6. These are the AX-free value
// types the app shell's real Accessibility ladder (M6) will PRODUCE and the
// learning loop (M7) will CONSUME. They live in Core so `InputSession`'s commit
// contract (which carries a `ContextSnapshot`) is fully unit-testable with
// stub context; every real `AXUIElement`/`IMKTextInput` call stays in the app.

/// A rounded field frame, for the identity signature (send-detection, M6/M7).
public struct RoundedFrame: Equatable, Hashable, Sendable {
    public let x, y, width, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(rect: CGRect) {
        self.x = Int(rect.origin.x.rounded())
        self.y = Int(rect.origin.y.rounded())
        self.width = Int(rect.size.width.rounded())
        self.height = Int(rect.size.height.rounded())
    }
}

/// The identity of a focused field — `{bundleId, pid, role, subrole, frame}`.
/// Used by send-detection (M6/M7) to tell "same field" from "session ended".
public struct FieldSignature: Equatable, Hashable, Sendable {
    public let bundleId: String
    public let pid: pid_t?
    public let role: String?
    public let subrole: String?
    public let roundedFrame: RoundedFrame?
    public init(bundleId: String, pid: pid_t? = nil, role: String? = nil,
                subrole: String? = nil, roundedFrame: RoundedFrame? = nil) {
        self.bundleId = bundleId
        self.pid = pid
        self.role = role
        self.subrole = subrole
        self.roundedFrame = roundedFrame
    }
}

/// Which context source tier produced a snapshot (the app's read ladder, M6).
public enum ContextSourceTier: String, Sendable, Equatable {
    case imkTextInput      // fast path — this-sentence only (the LLM hot path)
    case accessibility     // AX-enhanced read (commit-time, off the hot path)
    case sentenceOnly      // degraded — only the composing sentence
}

/// Why context capture / learning was suppressed for a snapshot (M6).
public enum CaptureSuppressionReason: String, Sendable, Equatable {
    case none
    case denylisted
    case systemSecureInput
    case secureField
    case noSourceAvailable
}

/// A captured context snapshot — the app shell fills `before`/`after`/signature
/// at commit time; learning (M7) consumes it. The live `AXUIElement`/
/// `IMKTextInput` poll target is carried separately by the app shell (it is not
/// `Sendable`), never in this pure value type.
public struct ContextSnapshot: Sendable, Equatable {
    public let before: String
    public let after: String
    public let appBundleId: String?
    public let fieldSignature: FieldSignature?
    public let sourceTier: ContextSourceTier
    public let suppressionReason: CaptureSuppressionReason

    public init(before: String, after: String = "", appBundleId: String? = nil,
                fieldSignature: FieldSignature? = nil,
                sourceTier: ContextSourceTier = .imkTextInput,
                suppressionReason: CaptureSuppressionReason = .none) {
        self.before = before
        self.after = after
        self.appBundleId = appBundleId
        self.fieldSignature = fieldSignature
        self.sourceTier = sourceTier
        self.suppressionReason = suppressionReason
    }

    /// An empty snapshot — the app-shell default when no source is available and
    /// the mock-test default.
    public static let empty = ContextSnapshot(before: "", after: "",
                                              sourceTier: .sentenceOnly,
                                              suppressionReason: .noSourceAvailable)
}
