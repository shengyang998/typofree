import ApplicationServices
import TypoFreeCore

// Low-level Accessibility attribute reads (DESIGN.md §2.7). Every real
// `AXUIElement` touch in the whole project funnels through here + `AXFocusResolver`;
// Core stays AX-free. All calls assume the caller already set a ~50 ms messaging
// timeout on the element (AXFocusResolver does), so a hung target app can never
// stall past that bound.
enum AXRead {
    /// Copy a string-valued attribute (`kAXValueAttribute`, `kAXRoleAttribute`, …).
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// Copy an `AXValue`-wrapped struct (CFRange / CGPoint / CGSize) into `out`.
    static func value<T>(_ element: AXUIElement, _ attribute: String,
                         _ type: AXValueType, into out: inout T) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
        return AXValueGetValue(raw as! AXValue, type, &out)
    }
}

// AXContextReader — reads a focused element's preceding context and its
// secure-field marker strings (DESIGN.md §2.7, scope item 2). Preceding context =
// `kAXValueAttribute` sliced to the insertion point from `kAXSelectedTextRangeAttribute`
// (UTF-16 offsets), capped. Markers (role/subrole/roleDescription/title/description)
// feed Core's `SecureFieldGuard.isSensitiveElement` — the static half of the
// secure double-guard. Stateless ⇒ `Sendable`; runs on `AXFocusResolver`'s queue.
struct AXContextReader: Sendable {

    /// Read `(precedingContext, secureMarkers)` from an already-resolved element.
    /// `role`/`subrole` are passed in (AXFocusResolver already read them for the
    /// signature) to avoid a duplicate AX round-trip.
    func read(_ element: AXUIElement, role: String?, subrole: String?,
              maxChars: Int) -> (precedingContext: String, markers: SecureFieldGuard.Markers) {
        let markers = SecureFieldGuard.Markers(
            role: role,
            subrole: subrole,
            roleDescription: AXRead.string(element, kAXRoleDescriptionAttribute),
            title: AXRead.string(element, kAXTitleAttribute),
            descriptionLabel: AXRead.string(element, kAXDescriptionAttribute))
        return (Self.precedingContext(element, maxChars: maxChars), markers)
    }

    /// The text immediately before the insertion point, capped to `maxChars`.
    /// Uses the selected-range location as the caret; if the field exposes no
    /// selection, falls back to the value's suffix (caret assumed at end — true
    /// right after a commit).
    private static func precedingContext(_ element: AXUIElement, maxChars: Int) -> String {
        guard maxChars > 0, let value = AXRead.string(element, kAXValueAttribute),
              !value.isEmpty else { return "" }
        let ns = value as NSString

        var range = CFRange(location: 0, length: 0)
        if AXRead.value(element, kAXSelectedTextRangeAttribute, .cfRange, into: &range),
           range.location != kCFNotFound, range.location >= 0 {
            let caret = min(range.location, ns.length)
            let start = max(0, caret - maxChars)
            return ns.substring(with: NSRange(location: start, length: caret - start))
        }
        let start = max(0, ns.length - maxChars)
        return ns.substring(with: NSRange(location: start, length: ns.length - start))
    }
}
