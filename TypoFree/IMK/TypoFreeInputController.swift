import AppKit
import IMKSwift
import TypoFreeCore

// TypoFreeInputController — the IMK entry point (DESIGN.md §2.5, DECISIONS.md).
// Subclasses IMKSwift's `IMKInputSessionController` (the ONLY Swift-6-safe base;
// IMKSwift README) and is deliberately NOT `@objc`-renamed, so its Objective-C
// runtime name stays module-qualified `TypoFree.TypoFreeInputController` —
// exactly what Info.plist's `InputMethodServerControllerClass =
// $(PRODUCT_MODULE_NAME).TypoFreeInputController` resolves via NSClassFromString.
//
// The controller holds NO business logic: composition state lives in the shared
// `InputSessionCache` (keyed by the client's address token), and the controller
// keeps only a WEAK ref to the session (IMKSwift README §3 — rapid IME switching
// must not drag heavy objects through ARC).
@MainActor
final class TypoFreeInputController: IMKInputSessionController {
    private weak var session: InputSession?
    private var adapter: IMKTextClientAdapter?

    override init(server: IMKServer, delegate: Any?, client inputClient: any IMKTextInput) {
        super.init(server: server, delegate: delegate, client: inputClient)
    }

    // keyDown drives composition; flagsChanged drives the lone-Shift 中英 toggle;
    // leftMouseDown implicitly finalizes (DESIGN.md §2.6).
    override func recognizedEvents(_ sender: any IMKTextInput) -> UInt {
        UInt(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown]).rawValue)
    }

    override func activateServer(_ sender: any IMKTextInput) {
        bind(to: sender)
    }

    override func deactivateServer(_ sender: any IMKTextInput) {
        // Focus leaving mid-composition → commit engineBest, never an unaccepted
        // async correction (DECISIONS.md user-Q4). Then hide the panel; the
        // session stays cached for reconnect.
        session?.finalizeImplicitly()
        session?.detach()
    }

    override func handle(_ event: NSEvent?, client sender: any IMKTextInput) -> Bool {
        guard let event, let keyEvent = KeyEvent(event) else { return false }
        // Re-bind if activateServer's ordering left us pointed at a different
        // client (Fire hit this in Safari's address bar).
        if session == nil || adapter?.isClient(sender) != true {
            bind(to: sender)
        }
        return session?.handle(keyEvent) ?? false
    }

    override func commitComposition(_ sender: any IMKTextInput) {
        session?.finalizeImplicitly()
    }

    override func inputControllerWillClose() {
        session?.sessionWillEnd()
        super.inputControllerWillClose()
    }

    // MARK: - Binding

    private func bind(to sender: any IMKTextInput) {
        let env = AppEnvironment.shared
        let token = IMKTextClientAdapter.token(for: sender)
        let adapter = IMKTextClientAdapter(sender)
        self.adapter = adapter
        let session = env.cache.session(forKey: token) {
            InputSession(dependencies: env.makeDependencies(),
                         sessionID: LearningSessionID(owner: adapter))
        }
        session.attach(client: adapter)
        self.session = session
    }
}
