import CoreGraphics

// TextClient — the IMK-free abstraction over the focused text field.
// DESIGN.md §2.5. The app's `IMKTextClientAdapter` wraps the real `IMKTextInput`
// behind this; Core (and the InputSession tests) only ever see this protocol, so
// the session never imports InputMethodKit.
@MainActor public protocol TextClient: AnyObject {
    /// Insert committed text, replacing any marked (preedit) text.
    func commit(_ text: String)
    /// Show inline marked (preedit) text with the caret at `cursor` (in Characters).
    func setPreedit(_ composing: String, cursor: Int)
    /// Clear any marked text.
    func clearPreedit()
    /// The caret rectangle in screen coordinates, for positioning the candidate bar.
    func caretRectInScreen() -> CGRect

    /// Identity of the owning app/field — used for the session cache key and, in
    /// later milestones, send-detection signatures.
    var bundleIdentifier: String? { get }
    var processIdentifier: pid_t { get }
    /// A stable per-client token (the client object's address) — the
    /// `InputSessionCache` key for reconnecting composition state after the
    /// controller is rebuilt (CapsLock / mode switch).
    var addressToken: Int { get }
}
