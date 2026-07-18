import SwiftUI
import TypoFreeCore

// MenuBarView — M8 (DESIGN.md §7 rows 6/7, tasks.md §M8): the current-backend
// glyph + honest error surfacing (MLX unavailable / FM `.rateLimited`), on top
// of M5's minimal "alive + reach Settings" content. Status is re-polled every
// time the menu opens (`.task` re-runs when a `MenuBarExtra`'s content becomes
// visible) — cheap (an availability() probe, no load) and needs no background
// timer.
struct MenuBarView: View {
    @State private var env = AppEnvironment.shared

    var body: some View {
        Label(backendLabel, systemImage: backendGlyph)
            .task { await env.refreshBackendStatus() }
        if let errorMessage {
            Text(errorMessage).font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        SettingsLink { Text("偏好设置…") }
        Divider()
        Button("退出 TypoFree") { NSApplication.shared.terminate(nil) }
    }

    private var backendGlyph: String {
        switch env.activeBackend {
        case .foundationModels: return "sparkles"
        case .mlx: return "cpu"
        case .null: return "circle.slash"
        }
    }

    private var backendLabel: String {
        switch env.activeBackend {
        case .foundationModels: return "TypoFree · Apple Intelligence"
        case .mlx: return "TypoFree · MLX 本地模型"
        case .null: return "TypoFree · 确定性候选"
        }
    }

    /// Honest error surfacing (DESIGN §7: "MLX 双源都挂 → .unavailable；FM 背景
    /// .rateLimited → 需可见状态，不再纯静默"). `nil` when everything is fine —
    /// no banner clutter for the common case.
    private var errorMessage: String? {
        guard case .unavailable(let reason) = env.activeBackendAvailability else { return nil }
        switch env.activeBackend {
        case .mlx:
            return "MLX 不可用（下载或加载失败）：\(reason)"
        case .foundationModels where reason == "rateLimited":
            return "Apple Intelligence 已被限流，本次会话回落到确定性候选（可在设置中开启自动切换本地模型）"
        case .foundationModels:
            return "Apple Intelligence 不可用：\(reason)"
        case .null:
            return nil
        }
    }
}
