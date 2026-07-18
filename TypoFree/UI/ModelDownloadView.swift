import SwiftUI
import TypoFreeLLM

// ModelDownloadView — MLX weight fetch progress + trigger/cancel + honest
// source/local-cache-hit state (DESIGN.md §7 row 2, tasks.md §M8). Embedded
// inside `BackendPickerView`'s "MLX 模型" section (the model choice and its
// download state are one user-facing decision). Download is user-triggered from
// here — never implicit on a keystroke (DESIGN's "Progress UI on first fetch").
struct ModelDownloadView: View {
    @State private var env = AppEnvironment.shared
    @State private var localCacheHit: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                stateIcon
                Text(stateLabel).font(.callout)
                Spacer()
                actionButton
            }
            Text(sourceLabel).font(.caption2).foregroundStyle(.secondary)
        }
        .task { await refreshLocalCacheHit() }
        .onChange(of: env.currentModelPreset) { _, _ in Task { await refreshLocalCacheHit() } }
    }

    private func refreshLocalCacheHit() async {
        localCacheHit = await env.willHitLocalModelCache()
    }

    // MARK: - State → UI

    @ViewBuilder private var stateIcon: some View {
        switch env.modelDownloadState {
        case .unloaded:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .downloading:
            ProgressView().controlSize(.small)
        case .loading:
            ProgressView().controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .unloading:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var stateLabel: String {
        switch env.modelDownloadState {
        case .unloaded:
            return localCacheHit == true ? "本地已有权重，尚未加载" : "尚未下载"
        case .downloading(let fraction):
            return "下载中… \(Int(fraction * 100))%"
        case .loading:
            return "加载中…"
        case .ready:
            return "已就绪"
        case .unloading:
            return "释放中…"
        case .failed(let reason):
            return "失败：\(reason)"
        }
    }

    private var sourceLabel: String {
        switch localCacheHit {
        case .some(true):
            return "本地缓存命中：无需下载，直接使用（探测顺序：应用缓存 → ~/.cache/huggingface/hub → ~/Documents/huggingface）。"
        case .some(false):
            return "本地未命中，将从 HuggingFace 下载（失败自动改用 hf-mirror.com 镜像）。"
        case .none:
            return "正在检查本地缓存…"
        }
    }

    // MARK: - Actions

    @ViewBuilder private var actionButton: some View {
        switch env.modelDownloadState {
        case .unloaded, .failed:
            Button(localCacheHit == true ? "加载" : "下载") {
                Task {
                    await env.downloadModelIfNeeded()
                    await refreshLocalCacheHit()
                }
            }
        case .downloading, .loading:
            Button("取消") { Task { await env.cancelModelDownload() } }
        case .ready:
            Button("释放") { Task { await env.cancelModelDownload() } }
        case .unloading:
            EmptyView()
        }
    }
}
