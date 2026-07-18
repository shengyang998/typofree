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

    // Learning loop (M7): the durable user dictionary, the immutable boost overlay
    // the hot path reads, the ONE send-detection owner, its 1.5 s poller, and the
    // commit→learn bridge (held strong here; `SessionDependencies.commitObserver`
    // is weak).
    let overlayHost: OverlayHost
    let learningCoordinator: LearningLoopCoordinator
    private let userDict: UserDictStore
    private let poller: SendDetectionPoller
    private let learningBridge: CommitLearningBridge

    private let mlxManager: MLXModelManager

    /// The model id flows through UserDefaults (default = MLXModelManager's own
    /// default), so M8's picker can layer on top without touching this wiring.
    static let modelIDKey = "TypoFreeModelID"
    static let backendPreferenceKey = "TypoFreeBackendPreference"
    static let defaultModelID = "mlx-community/Qwen3-0.6B-4bit"

    private init() {
        let scheme = FlypyScheme.flypy
        let decoder = ShuangpinDecoder(scheme: scheme)
        let lexicon: LexiconStore
        let index: PinyinReadingIndex
        do {
            lexicon = try LexiconStore.loadBundled(scheme: scheme)
            index = try PinyinReadingIndex.loadBundled()
        } catch {
            fatalError("TypoFree: failed to load bundled lexicon/readings — \(error)")
        }
        let conversion = ConversionEngine(lexicon: lexicon, scheme: scheme, config: LatticeConfig())
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

        // Learning loop (M7 part 2): open the durable user dictionary, hold the
        // immutable boost overlay, and build the ONE send-detection owner + its
        // poller + the commit bridge. The overlay is seeded from sqlite below.
        let overlayHost = OverlayHost()
        self.overlayHost = overlayHost
        let userDict: UserDictStore
        do {
            userDict = try UserDictStore(fileURL: UserDictStore.applicationSupportDefault())
        } catch {
            fatalError("TypoFree: failed to open the user dictionary — \(error)")
        }
        self.userDict = userDict
        let learningCoordinator = LearningLoopCoordinator(
            store: userDict, overlayHost: overlayHost, index: index,
            encoder: decoder, lexicon: lexicon)
        self.learningCoordinator = learningCoordinator
        let poller = SendDetectionPoller(coordinator: learningCoordinator)
        self.poller = poller
        self.learningBridge = CommitLearningBridge(
            coordinator: learningCoordinator, poller: poller,
            pollTarget: FocusedFieldPollTarget(reader: AXFocusResolver(),
                                               secureInput: SecureInputMonitor(),
                                               denylist: CaptureDenylist.defaults,
                                               maxChars: 200))

        let modelID = UserDefaults.standard.string(forKey: Self.modelIDKey) ?? Self.defaultModelID
        self.mlxManager = MLXModelManager(modelID: modelID, cacheDirectory: Self.modelCacheDirectory())

        Task { await self.resolveBackend() }
        Task { await self.seedOverlay() }
    }

    /// Seed the boost overlay from the durable user dictionary at startup so the
    /// very first keystroke's `ConversionEngine.convert` already reflects prior
    /// learning (MF#8 end to end).
    private func seedOverlay() async {
        if let overlay = try? await userDict.loadBoostOverlay() {
            overlayHost.replaceAll(overlay)
        }
    }

    /// The dependency bundle every InputSession is built with. The commit bridge
    /// feeds the learning loop, and the overlay provider reads the current
    /// immutable boost snapshot lock-free on the MainActor (MF#8).
    func makeDependencies() -> SessionDependencies {
        SessionDependencies(engine: engine, coordinator: coordinator, context: context,
                            renderer: panel, commitObserver: learningBridge,
                            overlayProvider: { [overlayHost] in overlayHost.current },
                            minCharsForLLM: 4)
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
