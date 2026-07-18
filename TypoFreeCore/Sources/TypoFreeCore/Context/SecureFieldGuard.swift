// SecureFieldGuard — DESIGN.md §2.7/§6, DECISIONS.md privacy posture, MF#6. Pure
// string logic deciding whether a focused element is a secure/sensitive field
// (password / one-time code / OTP / CVV / PIN …) from its AX marker strings,
// plus a combined check that ORs in the *dynamic* system-secure-input authority.
//
// The dynamic authority (Carbon `IsSecureEventInputEnabled()`) is INJECTED as a
// closure by the app shell (part 2) — Core never imports Carbon/ApplicationServices,
// so the whole guard is unit-testable with zero live AX. The static marker table
// matches short tokens (pin/otp/ssn/cvv/cvc) on WHOLE-WORD boundaries only, so
// "Opinion" and "Pinyin" are never mistaken for a PIN field; longer, distinctive
// markers ("password", "one-time code", …) match as case-insensitive substrings.
public enum SecureFieldGuard {

    /// The AX marker strings read from a focused element (all optional; the app
    /// shell fills whatever AX returned). `isSensitiveElement` scans them all,
    /// case-insensitively.
    public struct Markers: Sendable {
        public let role: String?
        public let subrole: String?
        public let roleDescription: String?
        public let title: String?
        public let descriptionLabel: String?
        public init(role: String? = nil, subrole: String? = nil,
                    roleDescription: String? = nil, title: String? = nil,
                    descriptionLabel: String? = nil) {
            self.role = role
            self.subrole = subrole
            self.roleDescription = roleDescription
            self.title = title
            self.descriptionLabel = descriptionLabel
        }
    }

    /// The authoritative AX subrole for a macOS secure text field.
    public static let secureTextFieldSubrole = "AXSecureTextField"

    /// Distinctive markers matched as case-insensitive substrings — long enough
    /// that they will not appear inside ordinary words.
    static let longMarkers: [String] = [
        "password", "passcode", "passwd",
        "one-time code", "one time code", "onetime code",
        "verification code", "security code", "authentication code",
        secureTextFieldSubrole.lowercased(),
    ]

    /// Short tokens matched on WHOLE-WORD boundaries only (so "Opinion" /
    /// "Pinyin" / "spinning" / "typing" never match "pin").
    static let shortTokens: [String] = ["pin", "otp", "ssn", "cvv", "cvc"]

    /// The full guard: secure iff the injected dynamic system-secure-input
    /// authority reports on, OR the static markers flag a sensitive element.
    public static func isSecure(markers: Markers,
                                isSecureEventInputEnabled: () -> Bool) -> Bool {
        if isSecureEventInputEnabled() { return true }
        return isSensitiveElement(markers)
    }

    /// Static, marker-only decision (no dynamic authority). `true` when the AX
    /// subrole is the authoritative secure text field, or any marker string
    /// carries a sensitive token.
    public static func isSensitiveElement(_ m: Markers) -> Bool {
        if let sub = m.subrole,
           sub.caseInsensitiveCompare(secureTextFieldSubrole) == .orderedSame {
            return true
        }
        for field in [m.role, m.subrole, m.roleDescription, m.title, m.descriptionLabel] {
            guard let raw = field else { continue }
            let text = raw.lowercased()
            for marker in longMarkers where text.contains(marker) { return true }
            for token in shortTokens where containsWholeWord(token, in: text) { return true }
        }
        return false
    }

    /// Whole-word containment: `token` (lowercased) appears in `text` (lowercased)
    /// bounded by non-alphanumeric characters (or the string edges).
    static func containsWholeWord(_ token: String, in text: String) -> Bool {
        let hay = Array(text), needle = Array(token)
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        let last = hay.count - needle.count
        var i = 0
        while i <= last {
            if Array(hay[i..<(i + needle.count)]) == needle {
                let beforeOK = (i == 0) || !isWordChar(hay[i - 1])
                let afterIdx = i + needle.count
                let afterOK = (afterIdx == hay.count) || !isWordChar(hay[afterIdx])
                if beforeOK && afterOK { return true }
            }
            i += 1
        }
        return false
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }
}
