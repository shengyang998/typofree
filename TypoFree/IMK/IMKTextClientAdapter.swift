import AppKit
import InputMethodKit
import TypoFreeCore

// IMKTextClientAdapter — wraps the live `IMKTextInput` client behind Core's
// IMK-free `TextClient` protocol (DESIGN.md §2.5). This is the ONLY place that
// speaks `IMKTextInput`; InputSession sees only `TextClient`. The client is held
// weakly (identity-only, per IMKSwift README §3): the stable address token is the
// InputSessionCache key, and we never keep a dead client alive.
@MainActor final class IMKTextClientAdapter: TextClient {
    private weak var imkClient: (any IMKTextInput)?

    /// The client's RAM address, captured at creation — the InputSessionCache key
    /// (stable identity even after the weak client is torn down).
    let addressToken: Int
    let bundleIdentifier: String?
    /// pid is not exposed by `IMKTextInput`; the real field identity (pid, role,
    /// frame) is the AX ladder's job in M6. `0` here is a deliberate M5 placeholder.
    let processIdentifier: pid_t = 0

    init(_ client: any IMKTextInput) {
        self.imkClient = client
        self.addressToken = Self.token(for: client)
        self.bundleIdentifier = client.bundleIdentifier()
    }

    /// The stable identity token for an `IMKTextInput` (its object address). Used
    /// only as an identity key — never dereferenced (IMKSwift README §3).
    static func token(for client: any IMKTextInput) -> Int {
        Int(bitPattern: Unmanaged.passUnretained(client as AnyObject).toOpaque())
    }

    /// Whether this adapter still wraps `other` (same underlying client object).
    func isClient(_ other: any IMKTextInput) -> Bool {
        addressToken == Self.token(for: other)
    }

    // MARK: - TextClient

    func commit(_ text: String) {
        guard !text.isEmpty, let c = imkClient else { return }
        c.insertText(text, replacementRange: Self.notFoundRange)
    }

    func setPreedit(_ composing: String, cursor: Int) {
        guard let c = imkClient else { return }
        let attributed = NSAttributedString(string: composing, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.labelColor,
        ])
        c.setMarkedText(attributed, selectionRange: Self.selection(cursor, in: composing),
                        replacementRange: Self.notFoundRange)
    }

    func clearPreedit() {
        guard let c = imkClient else { return }
        c.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                        replacementRange: Self.notFoundRange)
    }

    func caretRectInScreen() -> CGRect {
        guard let c = imkClient else { return .zero }
        var rect = NSRect.zero
        _ = c.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }

    /// The fast (< 5 ms) IMKTextInput preceding-context read used by the LLM hot
    /// path (DESIGN.md §3). The deep AX ladder is M6 — this is the sentence-local
    /// fast path only.
    func readPrecedingText(maxChars: Int) -> String {
        guard let c = imkClient, maxChars > 0 else { return "" }
        let selected = c.selectedRange()
        guard selected.location != NSNotFound, selected.location > 0 else { return "" }
        let start = max(0, selected.location - maxChars)
        let range = NSRange(location: start, length: selected.location - start)
        return c.attributedSubstring(from: range)?.string ?? ""
    }

    // MARK: - Helpers

    private static let notFoundRange = NSRange(location: NSNotFound, length: 0)

    /// Convert a Character-index cursor into a zero-length UTF-16 selection range,
    /// clamped into `text` (setMarkedText wants UTF-16 offsets).
    private static func selection(_ cursor: Int, in text: String) -> NSRange {
        let clamped = max(0, min(cursor, text.count))
        let charIndex = text.index(text.startIndex, offsetBy: clamped)
        let utf16Offset = text.utf16.distance(from: text.utf16.startIndex,
                                              to: charIndex.samePosition(in: text.utf16) ?? text.utf16.endIndex)
        return NSRange(location: utf16Offset, length: 0)
    }
}
