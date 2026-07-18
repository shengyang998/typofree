import AppKit
import IMKSwift

// AppDelegate — brings up the IMKServer (which vends `TypoFreeInputController`
// instances per client) and eagerly builds the shared `AppEnvironment`
// (DESIGN.md §0/§1). The connection name MUST match Info.plist's
// `InputMethodConnectionName` (= `<bundleid>_Connection`) or the input method
// fails to load (IMKSwift README Best Practice §1).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.soleilyu.typofree"
        let connectionName = (Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String)
            ?? "\(bundleID)_Connection"
        server = IMKServer(name: connectionName, bundleIdentifier: bundleID)

        // Build the engine + coordinator now (loads the lexicon, kicks off backend
        // resolution) so the first keystroke is instant.
        _ = AppEnvironment.shared
    }
}
