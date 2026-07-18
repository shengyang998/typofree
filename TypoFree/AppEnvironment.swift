import Foundation
import Observation
import TypoFreeCore
import TypoFreeLLM

// AppEnvironment — the shared, MainActor-resident wiring every controller reads
// (DESIGN.md §0/§2.4/§3). Built once at launch: the deterministic conversion
// engine (real bundled lexicon), the single async `CorrectionCoordinator`, the
// one shared self-drawn candidate panel, the composition LRU, and the MLX model
// manager. The correction backend is resolved OFF the main actor and hot-swapped
// in, so typing is available immediately (NullProvider) and slot#1 upgrades to
// FM/MLX once resolution finishes.
//
// M8 (tasks.md §M8, DESIGN.md §7) adds the Settings/menu-bar-observable surface:
// `@Observable` so BackendPickerView/ModelDownloadView/PermissionView/
// MenuBarView re-render on backend/download state changes with no extra
// plumbing — SwiftUI's Observation integration tracks whichever properties a
// view's `body` actually reads, no `@Published`/`@ObservedObject` needed.
@MainActor
@Observable
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

    /// M8: no longer `let` — switching the model preset builds a FRESH manager
    /// (one manager, one model, for its whole lifetime; simpler + safer than a
    /// mutable-modelID actor). The old MLX provider's ~500MB–1.1GB is released
    /// via `CorrectionCoordinator.setProvider`'s existing hot-swap contract
    /// (`MLXCorrectionProvider.releaseResources()` → `runner.unload()`), so no
    /// separate teardown of the old manager is needed here.
    private var mlxManager: MLXModelManager

    // MARK: - M8 observable UX state (Settings / menu bar read these)

    /// The backend actually serving corrections right now (updated after every
    /// resolve/hot-swap). The menu-bar glyph + Settings status derive from this.
    private(set) var activeBackend: LLMBackendID = .null
    /// That backend's last-known availability — carries the FM `.rateLimited` /
    /// MLX `.unavailable` detail for honest error surfacing (tasks.md §M8).
    private(set) var activeBackendAvailability: LLMProviderAvailability = .ready
    /// Live state of a user-triggered MLX download (`ModelDownloadView`).
    private(set) var modelDownloadState: MLXModelState = .unloaded
    /// The resolved model preset (persisted override, else RAM-aware default).
    private(set) var currentModelPreset: ModelPreset

    /// Guards the FM-rate-limited→MLX fallback so it only ever fires once per
    /// "episode" (reset when the toggle is flipped, so re-enabling gives it a
    /// fresh chance without needing an app restart).
    private var didApplyRateLimitFallback = false

    static let backendPreferenceKey = "TypoFreeBackendPreference"
    static let fallbackOnRateLimitKey = "TypoFreeFallbackOnRateLimit"

    var currentBackendPreference: LLMBackendPreference {
        let raw = UserDefaults.standard.string(forKey: Self.backendPreferenceKey)
            ?? LLMBackendPreference.auto.rawValue
        return LLMBackendPreference(rawValue: raw) ?? .auto
    }

    /// FM `.rateLimited` fallback toggle (DECISIONS.md 2026-07-18 user-Q2:
    /// "限流时回落本地模型", default OFF). `UserDefaults.bool(forKey:)` on an
    /// unset key already returns `false`, which IS the desired default — no
    /// separate "has this ever been set" bit needed.
    var fallbackOnRateLimitEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.fallbackOnRateLimitKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.fallbackOnRateLimitKey)
            didApplyRateLimitFallback = false
            Task { await self.applyRateLimitPolicyIfNeeded() }
        }
    }

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

        // M8: the RAM-aware dual preset (DECISIONS "MLX bake-off results"),
        // persisted-override-first. `defaultModelID`/`modelIDKey` (a bare model
        // id string) are gone — the preset IS the persisted unit now.
        let preset = ModelPresetResolver.resolve()
        self.currentModelPreset = preset
        self.mlxManager = MLXModelManager(modelID: preset.modelID, cacheDirectory: Self.modelCacheDirectory())

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

    // MARK: - M8: backend selection + status (BackendPickerView, MenuBarView)

    private func resolveBackend() async {
        let factory = LLMProviderFactory(mlxManager: mlxManager)
        let provider = await factory.makeProvider(preference: currentBackendPreference)
        await coordinator.setProvider(provider)
        activeBackend = provider.id
        activeBackendAvailability = await provider.availability()
    }

    /// The Settings backend list (FM / MLX / Off) with live availability.
    func probeBackends() async -> [LLMBackendStatus] {
        await LLMProviderFactory(mlxManager: mlxManager).probeBackends()
    }

    /// Persist a new backend preference and re-resolve + hot-swap immediately
    /// (releasing the old MLX model first, if it was MLX — DESIGN §3).
    func setBackendPreference(_ preference: LLMBackendPreference) async {
        UserDefaults.standard.set(preference.rawValue, forKey: Self.backendPreferenceKey)
        await resolveBackend()
    }

    /// Re-poll the active provider's status — the menu bar calls this whenever
    /// its content appears, and Settings calls it after any change. Also applies
    /// the FM rate-limit fallback policy if it now qualifies (see below).
    func refreshBackendStatus() async {
        let (id, availability) = await coordinator.currentBackendStatus()
        activeBackend = id
        activeBackendAvailability = availability
        await applyRateLimitPolicyIfNeeded()
    }

    // MARK: - M8: model preset (BackendPickerView)

    /// Switch the MLX model preset: build a fresh manager for the new model,
    /// persist the choice, and re-resolve (which hot-swaps the coordinator onto
    /// it if MLX is the active/resolved backend, releasing the OLD MLX
    /// provider's memory first via `setProvider`'s existing contract).
    ///
    /// `mlxManager.unload()` on the OLD manager first also cancels any in-flight
    /// `downloadModelIfNeeded()` load task belonging to it — otherwise a
    /// preset switch mid-download would leave that old download's progress
    /// callback (captured `[weak self]`, still the live `AppEnvironment`) free to
    /// keep overwriting `modelDownloadState` with stale progress for a model the
    /// user no longer selected.
    func applyModelPreset(_ preset: ModelPreset) async {
        ModelPresetResolver.persist(preset)
        currentModelPreset = preset
        await mlxManager.unload()
        mlxManager = MLXModelManager(modelID: preset.modelID, cacheDirectory: Self.modelCacheDirectory())
        modelDownloadState = .unloaded
        await resolveBackend()
    }

    // MARK: - M8: model download (ModelDownloadView)

    /// Whether the next download would be satisfied entirely from a local cache
    /// (no network) — the honest "local-cache-hit state" the view shows.
    func willHitLocalModelCache() async -> Bool {
        await mlxManager.wouldHitLocalCache()
    }

    /// User-triggered MLX weight fetch + load (Settings — NOT implicit on every
    /// keystroke). Publishes live progress through `modelDownloadState`.
    func downloadModelIfNeeded() async {
        modelDownloadState = .downloading(fraction: 0)
        do {
            try await mlxManager.loadIfNeeded { [weak self] fraction in
                Task { @MainActor in self?.modelDownloadState = .downloading(fraction: fraction) }
            }
            modelDownloadState = .ready
            await resolveBackend() // reflect the newly loaded model if MLX is active
        } catch {
            modelDownloadState = .failed(reason: String(describing: error))
        }
    }

    /// Cancel an in-flight download (best-effort — cancellation is cooperative).
    /// `MLXModelManager.unload()` already cancels any in-flight load task before
    /// dropping state, so it doubles as "cancel" with no separate method needed.
    func cancelModelDownload() async {
        await mlxManager.unload()
        modelDownloadState = .unloaded
    }

    // MARK: - M8: FM rate-limit fallback policy (DECISIONS.md user-Q2)

    /// Default (toggle OFF): stay on FM — `FoundationModelsCorrectionProvider`
    /// already silently returns `nil` for the rest of the session once
    /// rate-limited, so slot#1 degrades to `engineBest` with zero extra wiring.
    /// Toggle ON: hot-swap to MLX the next time status is checked (menu-bar
    /// open, Settings change, or the toggle being flipped) so slot#1 keeps
    /// getting corrections instead of going quiet for the rest of the session.
    private func applyRateLimitPolicyIfNeeded() async {
        guard RateLimitFallbackPolicy.shouldFallBackToMLX(
            activeBackend: activeBackend, activeAvailability: activeBackendAvailability,
            toggleEnabled: fallbackOnRateLimitEnabled, alreadyApplied: didApplyRateLimitFallback
        ) else { return }
        didApplyRateLimitFallback = true
        let provider = LLMProviderFactory(mlxManager: mlxManager).makeMLXProvider()
        await coordinator.setProvider(provider)
        activeBackend = provider.id
        activeBackendAvailability = await provider.availability()
    }

    // MARK: - M8: clear learned data (SettingsView)

    /// Wipe the durable user dictionary AND the in-memory overlay the hot path
    /// reads (DESIGN §6 "一键清除学习数据"; tasks.md §M8 "OverlayHost reset to
    /// empty"). Order matters: clear the durable store first — if that throws,
    /// the in-memory overlay (still reflecting prior learning) is left alone
    /// rather than silently diverging from a partially-cleared store.
    func clearLearnedData() async throws {
        try await userDict.clearAll()
        overlayHost.replaceAll(.empty)
    }

    private static func modelCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("com.soleilyu.inputmethod.TypoFree/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
