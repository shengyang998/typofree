import SwiftUI

// TypoFreeApp — the SwiftUI menu-bar app scene (DESIGN.md §1). Deliberately NOT
// `@main`: `main.swift` owns the entry point and calls `TypoFreeApp.main()` only
// for the `.run` argv case (installer sub-commands run TIS actions and exit
// without starting a scene). `LSUIElement` (Info.plist) keeps it out of the Dock.
struct TypoFreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("TypoFree", systemImage: "character.cursor.ibeam") {
            MenuBarView()
        }
        Settings {
            SettingsView()
        }
    }
}
