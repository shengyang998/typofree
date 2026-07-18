import SwiftUI
import TypoFreeCore

// SettingsView — M8 (DESIGN.md §7, tasks.md §M8): the full Settings surface,
// composed as tabs so each M8-scoped subview (BackendPickerView/PermissionView/
// OnboardingView) stays its own file/type while presenting as one coherent
// window. `GeneralSettingsTab` (below) is the M8 home for the "清除学习数据" +
// privacy statement + FM rate-limit fallback toggle that DESIGN.md §7 assigns to
// this file, plus the lexicon attribution carried over from M5.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("通用", systemImage: "gearshape") }
            BackendPickerView()
                .tabItem { Label("后端", systemImage: "cpu") }
            PermissionView()
                .tabItem { Label("权限", systemImage: "lock.shield") }
            OnboardingView()
                .tabItem { Label("首次设置", systemImage: "flag.checkered") }
        }
        .frame(width: 480, height: 460)
    }
}

/// General tab: identity blurb, privacy statement, clear-learned-data, and the
/// FM `.rateLimited` fallback toggle (default OFF — DECISIONS.md user-Q2).
private struct GeneralSettingsTab: View {
    @State private var env = AppEnvironment.shared
    @State private var isClearing = false
    @State private var clearResult: String?
    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            Section {
                Text("TypoFree").font(.title2).bold()
                Text("macOS 小鹤双拼输入法 · 端上 LLM 错别字修正")
                    .foregroundStyle(.secondary)
            }

            Section("隐私") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("全部处理均在本地进行：不联网同步、不上传、无遥测。")
                    Text("上下文读取与学习默认开启，密码框等安全输入场景强制排除，永不读取、永不学习。")
                    Text("学习仅保存不超过 20 个字符的短片段，从不保存完整字段内容；数据只存于本机 " +
                         "~/Library/Application Support/com.soleilyu.inputmethod.TypoFree/ 下，随时可一键清除。")
                }
                .font(.callout).foregroundStyle(.secondary)
            }

            Section("学习数据") {
                Button(role: .destructive) { showClearConfirmation = true } label: {
                    if isClearing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("清除学习数据")
                    }
                }
                .disabled(isClearing)
                if let clearResult {
                    Text(clearResult).font(.caption).foregroundStyle(.secondary)
                }
                Text("清除后，本地学习到的用词习惯将立即失效且不可恢复；基础词库（只读）不受影响。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .confirmationDialog("确认清除学习数据？", isPresented: $showClearConfirmation, titleVisibility: .visible) {
                Button("清除", role: .destructive) { Task { await clearLearnedData() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作不可撤销。")
            }

            Section("Apple Intelligence 限流") {
                Toggle("限流时回落本地模型", isOn: Binding(
                    get: { env.fallbackOnRateLimitEnabled },
                    set: { env.fallbackOnRateLimitEnabled = $0 }
                ))
                Text("默认关闭：Apple Intelligence 被系统限流时，本次会话静默保持确定性候选（不打扰）。" +
                     "开启后会自动切换到本地 MLX 模型，让智能修正继续可用（会占用本地内存/算力）。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("词库") {
                Text("词库：rime-essay (LGPL-3.0)、pinyin-data / phrase-pinyin-data (MIT)。详见 data/README.md。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    private func clearLearnedData() async {
        isClearing = true
        clearResult = nil
        do {
            try await env.clearLearnedData()
            clearResult = "已清除。"
        } catch {
            clearResult = "清除失败：\(error)"
        }
        isClearing = false
    }
}
