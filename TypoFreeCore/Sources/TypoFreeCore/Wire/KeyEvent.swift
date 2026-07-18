// KeyEvent + KeyModifiers — the IMK-free key event the app shell hands to
// `InputSession`. DESIGN.md §2.5. The app's `NSEvent+KeyEvent` bridge builds
// one of these from an `NSEvent`; Core never sees AppKit/IMKit, so the whole
// session state machine is unit-testable with synthetic key events.

/// A platform-agnostic modifier flag set (mirrors the NSEvent flags the bridge
/// translates, but with zero AppKit dependency).
public struct KeyModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)
    public static let function = KeyModifiers(rawValue: 1 << 5)
}

/// One key event routed into `InputSession.handle`. `characters` /
/// `charactersIgnoringModifiers` mirror `NSEvent`'s; the session routes on
/// `charactersIgnoringModifiers` (so Shift-modified letters still map to a-z).
public struct KeyEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keyDown
        case flagsChanged
        case mouseDown
    }

    public var kind: Kind
    public var keyCode: UInt16
    public var characters: String?
    public var charactersIgnoringModifiers: String?
    public var modifiers: KeyModifiers
    public var isRepeat: Bool

    public init(kind: Kind, keyCode: UInt16, characters: String? = nil,
                charactersIgnoringModifiers: String? = nil,
                modifiers: KeyModifiers = [], isRepeat: Bool = false) {
        self.kind = kind
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }
}

/// The small set of virtual key codes the session routes on structurally
/// (independent of the produced character). Values are the standard macOS
/// `kVK_*` constants; kept here so Core stays Carbon-free.
public enum SpecialKeyCode {
    public static let returnKey: UInt16 = 0x24
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    public static let delete: UInt16 = 0x33   // Backspace
    public static let escape: UInt16 = 0x35
    public static let keypadEnter: UInt16 = 0x4C
    public static let shiftLeft: UInt16 = 0x38
    public static let shiftRight: UInt16 = 0x3C
}
