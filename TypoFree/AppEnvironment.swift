import Foundation
import TypoFreeCore
import TypoFreeLLM

// AppEnvironment — the shared, MainActor-resident wiring every controller reads
// (DESIGN.md §0/§2.4/§3). Built once at launch: the deterministic conversion
// engine (real bundled lexicon), the single async `CorrectionCoordinator`, the
// one shared self-drawn candidate panel, the composition LRU, and the MLX model
// manager. The correction backend is resolved OFF the main actor and hot-swapped
// in, so typing is available immediately (NullProvider) and slot#1 upgrades to
// FM/MLX once resolution finishes.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let engine: ConversionCandidateEngine
    let coordinator: CorrectionCoordinator
    let panel: CandidatePanel
    let cache: InputSessionCache
    let context: ContextReadLadder

    private let mlxManager: MLXModelManager

    /// The model id flows through UserDefaults (default = MLXModelManager's own
    /// default), so M8's picker can layer on top without touching this wiring.
    static let modelIDKey = "TypoFreeModelID"
    static let backendPreferenceKey = "TypoFreeBackendPreference"
    static let defaultModelID = "mlx-community/Qwen3-0.6B-4bit"

    private init() {
        let scheme = FlypyScheme.flypy
        let decoder = ShuangpinDecoder(scheme: scheme)
        let store: LexiconStore
        let index: PinyinReadingIndex
        do {
            store = try LexiconStore.loadBundled(scheme: scheme)
            index = try PinyinReadingIndex.loadBundled()
        } catch {
            fatalError("TypoFree: failed to load bundled lexicon/readings — \(error)")
        }
        let conversion = ConversionEngine(lexicon: store, scheme: scheme, config: LatticeConfig())
        self.engine = ConversionCandidateEngine(engine: conversion)

        let validator = CorrectionValidator(index: index, decoder: decoder)
        self.coordinator = CorrectionCoordinator(provider: NullProvider(), validator: validator)

        self.panel = CandidatePanel()
        self.cache = InputSessionCache(capacity: 5)
        // The real M6 context ladder: fast IMKTextInput on the LLM hot path, the
        // bounded AX read + secure double-guard at commit time. Core typing never
        // depends on AX (untrusted → IMK-only degrade); the AX permission prompt
        // is M8's PermissionView, so we only read `AXIsProcessTrusted` here.
        self.context = ContextReadLadder()

        let modelID = UserDefaults.standard.string(forKey: Self.modelIDKey) ?? Self.defaultModelID
        self.mlxManager = MLXModelManager(modelID: modelID, cacheDirectory: Self.modelCacheDirectory())

        Task { await self.resolveBackend() }
    }

    /// The dependency bundle every InputSession is built with. Learning
    /// (commitObserver / a real overlay) is M7 — M5 wires an inert `.empty`
    /// overlay and no observer.
    func makeDependencies() -> SessionDependencies {
        SessionDependencies(engine: engine, coordinator: coordinator, context: context,
                            renderer: panel, commitObserver: nil,
                            overlayProvider: { .empty }, minCharsForLLM: 4)
    }

    private func resolveBackend() async {
        let raw = UserDefaults.standard.string(forKey: Self.backendPreferenceKey)
            ?? LLMBackendPreference.auto.rawValue
        let preference = LLMBackendPreference(rawValue: raw) ?? .auto
        let factory = LLMProviderFactory(mlxManager: mlxManager)
        let provider = await factory.makeProvider(preference: preference)
        await coordinator.setProvider(provider)
    }

    private static func modelCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("com.soleilyu.typofree/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
