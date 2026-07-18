import Foundation

// ModelPreset — the RAM-aware dual-preset MLX model choice (tasks.md §M8,
// research/DECISIONS.md "MLX bake-off results" 2026-07-18). The bake-off found
// two viable configurations, not one fixed model:
//   - quality: mlx-community/Qwen2.5-1.5B-Instruct-4bit — 4/7 net corrections
//     after the D12 gate, zero format breakage, 600-730ms steady on M2 Pro
//     (~1.0-1.1GB while loaded). Default when installed RAM >= 16GB.
//   - light: mlx-community/Qwen3-0.6B-4bit — word-level typos only, noisy but
//     gate-safe, ~500-650MB loaded. Default below 16GB (the 8GB target device).
// M4 only parametrized `MLXModelManager`/`MLXQwenRunner` with a bare `modelID`
// string; this is the M8 policy layer on top — display names must derive from
// the live model id (DESIGN's must_fix: "displayName 不再硬编码 0.6B").
public enum ModelPreset: String, Sendable, Codable, CaseIterable {
    case quality
    case light

    public var modelID: String {
        switch self {
        case .quality: return "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        case .light: return "mlx-community/Qwen3-0.6B-4bit"
        }
    }

    public var displayName: String {
        switch self {
        case .quality: return "Qwen2.5 1.5B（高质量）"
        case .light: return "Qwen3 0.6B（轻量）"
        }
    }

    /// Bake-off-measured footprint while loaded — informational only (§ModelDownloadView).
    public var approxMemoryDescription: String {
        switch self {
        case .quality: return "约 1.0–1.1 GB（用时加载，闲时释放）"
        case .light: return "约 500–650 MB（用时加载，闲时释放）"
        }
    }

    /// The 16GB line the bake-off drew: `quality` needs headroom the 8GB
    /// deployment floor does not have; `light` is the one the target device runs.
    public static let ramThresholdBytes: UInt64 = 16 * 1024 * 1024 * 1024

    /// The RAM-aware default (no persisted override yet applied).
    public static func ramAwareDefault(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> ModelPreset {
        physicalMemoryBytes >= ramThresholdBytes ? .quality : .light
    }

    /// Reverse lookup: which preset (if any) a live `modelID` corresponds to —
    /// lets `MLXModelManager`'s actual configured id drive display text instead
    /// of a hardcoded literal.
    public init?(modelID: String) {
        guard let match = ModelPreset.allCases.first(where: { $0.modelID == modelID }) else { return nil }
        self = match
    }

    /// Best-effort display name for an arbitrary model id — falls back to the
    /// raw id for a manually overridden model that isn't one of the two presets
    /// (never hardcodes "0.6B").
    public static func displayName(forModelID modelID: String) -> String {
        ModelPreset(modelID: modelID)?.displayName ?? modelID
    }
}

/// UserDefaults persistence for the user's explicit preset override (tasks.md
/// §M8: "UserDefaults 持久化"). Absent an override, `resolve` falls through to
/// the RAM-aware default — so a fresh install picks correctly with zero UI
/// interaction, and Settings' picker only needs to write one key.
public enum ModelPresetResolver {
    public static let userDefaultsKey = "TypoFreeModelPreset"

    /// The effective preset: a persisted override if present and valid, else the
    /// RAM-aware default.
    public static func resolve(
        userDefaults: UserDefaults = .standard,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> ModelPreset {
        if let raw = userDefaults.string(forKey: userDefaultsKey),
           let override = ModelPreset(rawValue: raw) {
            return override
        }
        return ModelPreset.ramAwareDefault(physicalMemoryBytes: physicalMemoryBytes)
    }

    /// Persist an explicit user choice (Settings' picker).
    public static func persist(_ preset: ModelPreset, userDefaults: UserDefaults = .standard) {
        userDefaults.set(preset.rawValue, forKey: userDefaultsKey)
    }

    /// Drop back to the RAM-aware default.
    public static func clearOverride(userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: userDefaultsKey)
    }
}
