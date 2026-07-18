import SwiftUI
import TypoFreeCore
import TypoFreeLLM

// BackendPickerView — Settings' backend selection (DESIGN.md §7 row 1, tasks.md
// §M8). Lists FM/MLX/Off via `LLMProviderFactory.probeBackends()`; switching
// preference hot-swaps the coordinator's provider (`AppEnvironment.
// setBackendPreference`), which releases the OLD MLX model's memory first via
// `CorrectionCoordinator.setProvider`'s existing contract before installing the
// new one. Also hosts the M8 ModelPreset picker (quality/light) and embeds
// `ModelDownloadView` — the model choice + its download state are one section
// because they're one decision from the user's point of view.
struct BackendPickerView: View {
    @State private var env = AppEnvironment.shared
    @State private var statuses: [LLMBackendStatus] = []
    @State private var isLoading = true

    private var preferenceBinding: Binding<LLMBackendPreference> {
        Binding(
            get: { env.currentBackendPreference },
            set: { newValue in Task { await env.setBackendPreference(newValue) ; await refresh() } }
        )
    }

    private var presetBinding: Binding<ModelPreset> {
        Binding(
            get: { env.currentModelPreset },
            set: { newValue in Task { await env.applyModelPreset(newValue); await refresh() } }
        )
    }

    var body: some View {
        Form {
            Section("LLM 后端") {
                Picker("使用", selection: preferenceBinding) {
                    Text("自动（推荐）").tag(LLMBackendPreference.auto)
                    Text("仅 Apple Intelligence").tag(LLMBackendPreference.foundationModels)
                    Text("仅 MLX 本地模型").tag(LLMBackendPreference.mlx)
                    Text("关闭（仅确定性候选）").tag(LLMBackendPreference.off)
                }
                Text("自动：优先系统 Apple Intelligence，不可用时退到本地 MLX 模型，都不可用时仅用确定性引擎候选。")
                    .font(.caption).foregroundStyle(.secondary)

                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    ForEach(statuses) { status in
                        BackendStatusRow(status: status, isActive: status.id == env.activeBackend)
                    }
                }
            }

            Section("MLX 模型") {
                Picker("质量预设", selection: presetBinding) {
                    ForEach(ModelPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                Text(env.currentModelPreset.approxMemoryDescription)
                    .font(.caption).foregroundStyle(.secondary)
                Text("8GB 设备默认轻量预设；16GB 及以上默认高质量预设。可随时手动切换，切换会先释放当前已加载的模型再切换。")
                    .font(.caption).foregroundStyle(.secondary)

                ModelDownloadView()
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private func refresh() async {
        isLoading = true
        statuses = await env.probeBackends()
        await env.refreshBackendStatus()
        isLoading = false
    }
}

/// One backend's status row: name, detail, and an honest availability label
/// (never silently hides a download-needed / unavailable / rate-limited state).
private struct BackendStatusRow: View {
    let status: LLMBackendStatus
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(status.displayName).font(.body)
                    if isActive {
                        Text("当前使用").font(.caption2).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.tint))
                    }
                }
                Text(status.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(availabilityLabel).font(.caption).foregroundStyle(availabilityColor)
        }
        .padding(.vertical, 2)
    }

    private var availabilityLabel: String {
        switch status.availability {
        case .ready: return "就绪"
        case .availableOnDemand: return "已缓存，用时加载"
        case .needsDownload: return "需下载"
        case .unavailable(let reason): return "不可用（\(reason)）"
        }
    }

    private var availabilityColor: Color {
        switch status.availability {
        case .ready: return .green
        case .availableOnDemand, .needsDownload: return .secondary
        case .unavailable: return .red
        }
    }
}
