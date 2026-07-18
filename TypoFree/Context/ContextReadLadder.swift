import ApplicationServices
import TypoFreeCore

// ContextReadLadder — the real `ContextReading` conformer (DESIGN.md §2.7/§3,
// scope items 4/5). It is the M6 replacement for M5's `IMKContextReader`:
//
//   • precedingContext (LLM hot path)  — the FAST IMKTextInput route only, gated
//     by the fast dynamic secure guard + denylist. NO Accessibility on the
//     per-keystroke path (DESIGN §3 "AX 不上热路径").
//   • captureSnapshot (commit time)    — the full IMKTextInput → AX → sentence-only
//     ladder: one bounded (50 ms-capped) AX read for the field signature +
//     preceding context + secure markers, off the typing hot path. The pure
//     suppression/tier/blanking decision is delegated to Core's
//     `ContextSnapshot.assemble` so the security contract is unit-tested there.
//
// Secure-field double guard: the dynamic `SecureInputMonitor` (Carbon, zero IPC,
// checked first) OR Core's static `SecureFieldGuard` marker table (AX subrole /
// roleDescription). A secure context blanks captured context so learning (M7)
// stays inert. AX is attempted only when the process is AX-trusted
// (`AXIsProcessTrusted`, read-only — the permission PROMPT is M8's PermissionView);
// untrusted simply degrades to the IMK fast path, and core typing never depends
// on AX.
@MainActor final class ContextReadLadder: ContextReading {
    private let imk: IMKContextReader
    private let axReader: any FocusedFieldReading
    private let secureInput: SecureInputMonitor
    private let isAXTrusted: () -> Bool
    private let denylist: Set<String>
    private let maxContextChars: Int

    init(imk: IMKContextReader = IMKContextReader(),
         axReader: any FocusedFieldReading = AXFocusResolver(),
         secureInput: SecureInputMonitor = SecureInputMonitor(),
         isAXTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         denylist: Set<String> = CaptureDenylist.defaults,
         maxContextChars: Int = 200) {
        self.imk = imk
        self.axReader = axReader
        self.secureInput = secureInput
        self.isAXTrusted = isAXTrusted
        self.denylist = denylist
        self.maxContextChars = maxContextChars
    }

    /// Fast dynamic secure check (Carbon, no AX round-trip) — the hot-path guard.
    /// Routed through Core's combined guard with empty markers (the AX marker half
    /// is only available at capture time).
    var isSecureContext: Bool {
        SecureFieldGuard.isSecure(markers: .init(), isSecureEventInputEnabled: secureInput.callAsFunction)
    }

    // MARK: - LLM hot path (sync on MainActor, < 5 ms, no AX)

    func precedingContext(for client: (any TextClient)?, maxChars: Int) -> String {
        if isSecureContext { return "" }
        if CaptureDenylist.contains(client?.bundleIdentifier, denylist: denylist) { return "" }
        return imk.precedingContext(for: client, maxChars: maxChars)
    }

    // MARK: - Commit-time capture (off the per-keystroke hot path)

    func captureSnapshot(for client: (any TextClient)?) -> ContextSnapshot {
        let bundleId = client?.bundleIdentifier
        let systemSecure = secureInput.isActive
        let denied = CaptureDenylist.contains(bundleId, denylist: denylist)

        // Only touch AX when trusted AND not denylisted (denylisted apps are never
        // introspected at all — DESIGN §6). Otherwise degrade to the IMK fast path.
        let field: FocusedField? = (denied || !isAXTrusted())
            ? nil
            : axReader.readFocusedField(maxChars: maxContextChars)
        let isSecureField = field.map { SecureFieldGuard.isSensitiveElement($0.markers) } ?? false
        let imkBefore = imk.precedingContext(for: client, maxChars: maxContextChars)

        return ContextSnapshot.assemble(
            bundleId: bundleId,
            axPrecedingText: field?.precedingText,
            imkPrecedingText: imkBefore,
            fieldSignature: field?.signature,
            isSystemSecureInputActive: systemSecure,
            isSecureField: isSecureField,
            maxChars: maxContextChars,
            denylist: denylist)
    }
}
