import SwiftUI

// SettingsView — minimal M5 placeholder. The full onboarding / backend picker /
// model download / permission / clear-learned-data UX is M8 (DESIGN.md §7). M5
// ships only the local-only privacy statement + lexicon attribution.
struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TypoFree").font(.title2).bold()
            Text("macOS 小鹤双拼输入法 · 端上 LLM 错别字修正")
                .foregroundStyle(.secondary)
            Divider()
            Text("隐私")
                .font(.headline)
            Text("全部处理在本地进行：不联网同步、不上传、无遥测。密码框强制排除。")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("词库：rime-essay (LGPL-3.0)、pinyin-data / phrase-pinyin-data (MIT)。详见 data/README.md。")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
    }
}
