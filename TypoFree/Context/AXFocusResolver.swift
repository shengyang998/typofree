import AppKit
import ApplicationServices
import TypoFreeCore

/// A resolved focused field — the AX read result the ladder consumes. Pure
/// `Sendable` value types only (the live `AXUIElement` never escapes the read),
/// so it can cross back from the dedicated AX queue.
struct FocusedField: Sendable {
    let signature: FieldSignature
    let precedingText: String
    let markers: SecureFieldGuard.Markers
}

/// The AX-reading seam (scope item 1/2). The real conformer is `AXFocusResolver`;
/// tests inject a fake so the ladder's decision logic is exercisable without live
/// AX. `Sendable` so M7's off-MainActor send-detection poller can reuse it.
protocol FocusedFieldReading: Sendable {
    /// The currently focused field, or `nil` if unresolved (no focus, untrusted,
    /// or the target app timed out). Never throws; degradation is `nil`.
    func readFocusedField(maxChars: Int) -> FocusedField?
}

// AXFocusResolver — resolves the system-wide focused UI element and stamps a
// `FieldSignature {bundleId, pid, role, subrole, roundedFrame}` (DESIGN.md §2.7,
// scope item 1). Sets a ~50 ms `AXUIElementSetMessagingTimeout` on BOTH the
// system-wide element and the resolved focused element so a hung app can never
// stall the caller past that bound. The owning app is found via
// `AXUIElementGetPid` (the element's real owner), NOT `NSWorkspace.frontmost`.
//
// All AX calls run on a dedicated serial queue (DESIGN §3: AX off the MainActor
// hot path). At commit time the ladder blocks on this queue for one bounded read;
// the per-keystroke typing path never reaches here (it uses the IMK fast path).
final class AXFocusResolver: FocusedFieldReading {
    private let queue = DispatchQueue(label: "com.soleilyu.typofree.ax.read", qos: .userInitiated)
    private let contextReader: AXContextReader
    private let messagingTimeout: Float

    init(contextReader: AXContextReader = AXContextReader(), messagingTimeout: Float = 0.05) {
        self.contextReader = contextReader
        self.messagingTimeout = messagingTimeout
    }

    func readFocusedField(maxChars: Int) -> FocusedField? {
        queue.sync { readOnQueue(maxChars: maxChars) }
    }

    // MARK: - On the dedicated AX queue

    private func readOnQueue(maxChars: Int) -> FocusedField? {
        guard let element = copyFocusedElement() else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let bundleId = pid > 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil
        let role = AXRead.string(element, kAXRoleAttribute)
        let subrole = AXRead.string(element, kAXSubroleAttribute)

        let signature = FieldSignature(bundleId: bundleId ?? "",
                                       pid: pid > 0 ? pid : nil,
                                       role: role, subrole: subrole,
                                       roundedFrame: frame(of: element))
        let (text, markers) = contextReader.read(element, role: role, subrole: subrole,
                                                 maxChars: maxChars)
        return FocusedField(signature: signature, precedingText: text, markers: markers)
    }

    private func copyFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private func frame(of element: AXUIElement) -> RoundedFrame? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXRead.value(element, kAXPositionAttribute, .cgPoint, into: &position),
              AXRead.value(element, kAXSizeAttribute, .cgSize, into: &size) else { return nil }
        return RoundedFrame(rect: CGRect(origin: position, size: size))
    }
}
