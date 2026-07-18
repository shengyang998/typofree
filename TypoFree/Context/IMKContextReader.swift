import Foundation
import TypoFreeCore

// IMKContextReader — the M5 `ContextReading` conformer: the fast IMKTextInput
// preceding-sentence path only (DESIGN.md §2.7/§3). It is stateless (one shared
// instance) and does NOT touch Accessibility — the AX read ladder + secure-field
// guard are M6. `isSecureContext` is conservatively `false` here; M6 replaces
// this whole reader with `ContextReadLadder` + `SecureFieldGuard`.
@MainActor final class IMKContextReader: ContextReading {
    var isSecureContext: Bool { false }   // M6: real IsSecureEventInputEnabled + SecureFieldGuard

    func precedingContext(for client: (any TextClient)?, maxChars: Int) -> String {
        (client as? IMKTextClientAdapter)?.readPrecedingText(maxChars: maxChars) ?? ""
    }

    func captureSnapshot(for client: (any TextClient)?) -> ContextSnapshot {
        let before = precedingContext(for: client, maxChars: 20)
        return ContextSnapshot(before: before, after: "",
                               appBundleId: client?.bundleIdentifier, fieldSignature: nil,
                               sourceTier: .imkTextInput, suppressionReason: .none)
    }
}
