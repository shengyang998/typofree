import SwiftUI
import ApplicationServices

// PermissionView — Accessibility (AX) status + the TCC prompt trigger (DESIGN.md
// §7 row 3, tasks.md §M8). AX is read-only checked (`AXIsProcessTrusted`)
// everywhere else in the app (`ContextReadLadder`, M6); THIS is the one place
// allowed to trigger the system prompt (`AXIsProcessTrustedWithOptions` with
// `kAXTrustedCheckOptionPrompt`), because it is an explicit user action, not
// something that should ever fire off the typing hot path.
//
// Copy is deliberately explicit: typing NEVER requires AX. AX only widens
// context capture (the LLM correction's preceding-sentence context) and
// send-detection learning; both degrade gracefully to "off" without it.
struct PermissionView: View {
    @State private var isTrusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        isTrusted ? "辅助功能权限：已授权" : "辅助功能权限：未授权",
                        systemImage: isTrusted ? "checkmark.shield.fill" : "exclamationmark.shield"
                    )
                    .foregroundStyle(isTrusted ? .green : .orange)
                    .font(.headline)

                    Text(
                        "打字功能本身从不依赖辅助功能权限——没有它，TypoFree 依然可以正常输入、转换、上屏。" +
                        "辅助功能权限只用于两处增强：① 读取当前光标附近更完整的上下文，帮助 LLM 判断同音错字；" +
                        "② 检测输入完成后（如按下发送）用于学习你的用词习惯。未授权时这两项会自动关闭，不影响正常打字。"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                if isTrusted {
                    Text("已授权，无需操作。").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("请求辅助功能权限…") { requestPermission() }
                    Text("点击后系统会弹出授权对话框；前往「系统设置 ▸ 隐私与安全性 ▸ 辅助功能」勾选 TypoFree 后返回本页重新检查。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("重新检查") { recheck() }
            }
        }
        .formStyle(.grouped)
        .onAppear { recheck() }
    }

    /// Triggers the system TCC prompt (a no-op if already trusted, or if the
    /// user already permanently denied it — macOS then just re-shows System
    /// Settings' entry rather than a fresh dialog).
    ///
    /// Uses the documented literal string value of `kAXTrustedCheckOptionPrompt`
    /// ("AXTrustedCheckOptionPrompt") rather than the imported C global directly:
    /// under Swift 6 strict concurrency, referencing that global fails with
    /// "not concurrency-safe because it involves shared mutable state" (it
    /// imports as an `Unmanaged<CFString>` global, not a `Sendable`-safe `let`).
    /// The string value is stable, public Apple API surface.
    private func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
    }

    private func recheck() {
        isTrusted = AXIsProcessTrusted()
    }
}
