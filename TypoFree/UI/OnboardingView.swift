import AppKit
import SwiftUI

// OnboardingView — first-run enable walkthrough (DESIGN.md §7 row 4, tasks.md
// §M8). Walks the user through System Settings ▸ Keyboard ▸ Input Sources ▸ + ▸
// 简体中文 ▸ TypoFree.
//
// Deliberately NO logout/login step here (a deviation from DESIGN §7's literal
// "首装必登出/登入一次" and from M5/M6/M7's dev.sh observations under the CURRENT
// bundle id): the pending bundle-id rename lands immediately after M8, and once
// TypoFree registers under its renamed identity the input source appears
// immediately without a logout — so instructing users to log out here would
// describe a limitation that no longer exists by the time this UI ships. See
// tasks.md §M8 交付确认 for the explicit call.
struct OnboardingView: View {
    private struct Step: Identifiable {
        let id: Int
        let title: String
        let detail: String
        let systemImage: String
    }

    private let steps: [Step] = [
        Step(id: 1, title: "打开系统设置", detail: "点击下方按钮，或手动前往「系统设置 ▸ 键盘」。",
             systemImage: "gearshape"),
        Step(id: 2, title: "进入输入源", detail: "在「键盘」页面找到「输入源」一栏，点击「编辑」或「+」。",
             systemImage: "keyboard"),
        Step(id: 3, title: "添加简体中文", detail: "在语言列表中选择「简体中文」。",
             systemImage: "character.book.closed"),
        Step(id: 4, title: "选择 TypoFree", detail: "在简体中文的输入法列表中勾选「TypoFree（小鹤双拼）」，点击「添加」。",
             systemImage: "checkmark.circle"),
        Step(id: 5, title: "切换输入法", detail: "从菜单栏输入法图标或按 Control+Space 切到 TypoFree，即可在任意 App 中打字。",
             systemImage: "character.cursor.ibeam"),
    ]

    var body: some View {
        Form {
            Section {
                Text("首次启用 TypoFree").font(.title3).bold()
                Text("按以下步骤把 TypoFree 添加为系统输入法（一次性设置）。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("步骤") {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: step.systemImage)
                            .frame(width: 20)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(step.id). \(step.title)").font(.body).bold()
                            Text(step.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                Button("打开系统设置 ▸ 键盘") { openKeyboardSettings() }
            }
        }
        .formStyle(.grouped)
    }

    private func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") else { return }
        NSWorkspace.shared.open(url)
    }
}
