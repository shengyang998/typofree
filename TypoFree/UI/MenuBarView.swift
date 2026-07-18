import SwiftUI

// MenuBarView — minimal M5 menu-bar content. The full backend-status glyph +
// error overlays (MLX dual-source down / FM .rateLimited) are M8 (DESIGN.md §7);
// this is just enough to see the IME is alive and reach Settings.
struct MenuBarView: View {
    var body: some View {
        Text("TypoFree · 小鹤双拼")
        Divider()
        SettingsLink { Text("偏好设置…") }
        Divider()
        Button("退出 TypoFree") { NSApplication.shared.terminate(nil) }
    }
}
