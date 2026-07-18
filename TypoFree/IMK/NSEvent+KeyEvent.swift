import AppKit
import TypoFreeCore

// NSEvent → KeyEvent bridge (DESIGN.md §2.5). The only place that translates an
// AppKit `NSEvent` into Core's IMK-free `KeyEvent`; everything downstream
// (InputSession) is pure and unit-testable. `characters`/`charactersIgnoringModifiers`
// are read ONLY for keyDown — touching them on a flagsChanged event raises an
// Objective-C exception.
extension KeyEvent {
    init?(_ event: NSEvent) {
        let kind: KeyEvent.Kind
        switch event.type {
        case .keyDown:
            kind = .keyDown
        case .flagsChanged:
            kind = .flagsChanged
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            kind = .mouseDown
        default:
            return nil
        }

        var mods: KeyModifiers = []
        let f = event.modifierFlags
        if f.contains(.shift) { mods.insert(.shift) }
        if f.contains(.control) { mods.insert(.control) }
        if f.contains(.option) { mods.insert(.option) }
        if f.contains(.command) { mods.insert(.command) }
        if f.contains(.capsLock) { mods.insert(.capsLock) }
        if f.contains(.function) { mods.insert(.function) }

        let isKeyDown = event.type == .keyDown
        self.init(kind: kind,
                  keyCode: event.keyCode,
                  characters: isKeyDown ? event.characters : nil,
                  charactersIgnoringModifiers: isKeyDown ? event.charactersIgnoringModifiers : nil,
                  modifiers: mods,
                  isRepeat: isKeyDown ? event.isARepeat : false)
    }
}
