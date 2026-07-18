import XCTest
@testable import TypoFreeLLM

/// M8 (tasks.md §M8, DECISIONS.md "MLX bake-off results") — the RAM-aware
/// dual-preset resolution: the 16GB threshold, the persisted-override precedence,
/// and the id↔displayName round trip that keeps `LLMProviderFactory` from ever
/// hardcoding "0.6B". Zero network, zero Metal — pure `ProcessInfo`/`UserDefaults`
/// inputs are injected so nothing depends on the actual dev machine's RAM.
final class ModelPresetTests: XCTestCase {
    private let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
    private let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
    private let thirtyTwoGB: UInt64 = 32 * 1024 * 1024 * 1024

    /// A fresh, isolated `UserDefaults` suite per test so persisted-override
    /// assertions never leak into other tests or the real `.standard` domain.
    private func freshDefaults() -> UserDefaults {
        let suiteName = "TypoFreeModelPresetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Capture only the (Sendable) name, not the `UserDefaults` instance
        // itself — domain removal targets the shared defaults database by name,
        // so any instance can perform it.
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    // MARK: RAM-aware default

    func testRAMAwareDefaultPicksQualityAtOrAbove16GB() {
        XCTAssertEqual(ModelPreset.ramAwareDefault(physicalMemoryBytes: sixteenGB), .quality)
        XCTAssertEqual(ModelPreset.ramAwareDefault(physicalMemoryBytes: thirtyTwoGB), .quality)
    }

    func testRAMAwareDefaultPicksLightBelow16GB() {
        XCTAssertEqual(ModelPreset.ramAwareDefault(physicalMemoryBytes: eightGB), .light)
        XCTAssertEqual(ModelPreset.ramAwareDefault(physicalMemoryBytes: sixteenGB - 1), .light)
    }

    // MARK: resolve() = override-if-present else RAM-aware default

    func testResolveWithNoOverrideFallsBackToRAMAwareDefault() {
        let defaults = freshDefaults()
        XCTAssertEqual(ModelPresetResolver.resolve(userDefaults: defaults, physicalMemoryBytes: eightGB), .light)
        XCTAssertEqual(ModelPresetResolver.resolve(userDefaults: defaults, physicalMemoryBytes: thirtyTwoGB), .quality)
    }

    func testPersistedOverrideWinsRegardlessOfRAM() {
        let defaults = freshDefaults()
        ModelPresetResolver.persist(.quality, userDefaults: defaults)
        // Even on an 8GB box, an explicit user override to `quality` sticks —
        // the picker (M8) lets the user opt into the heavier model.
        XCTAssertEqual(ModelPresetResolver.resolve(userDefaults: defaults, physicalMemoryBytes: eightGB), .quality)

        ModelPresetResolver.persist(.light, userDefaults: defaults)
        XCTAssertEqual(ModelPresetResolver.resolve(userDefaults: defaults, physicalMemoryBytes: thirtyTwoGB), .light)
    }

    func testClearOverrideRestoresRAMAwareDefault() {
        let defaults = freshDefaults()
        ModelPresetResolver.persist(.quality, userDefaults: defaults)
        XCTAssertEqual(ModelPresetResolver.resolve(userDefaults: defaults, physicalMemoryBytes: eightGB), .quality)

        ModelPresetResolver.clearOverride(userDefaults: defaults)
        XCTAssertEqual(ModelPresetResolver.resolve(userDefaults: defaults, physicalMemoryBytes: eightGB), .light)
    }

    func testMalformedPersistedValueIsIgnored() {
        let defaults = freshDefaults()
        defaults.set("not-a-real-preset", forKey: ModelPresetResolver.userDefaultsKey)
        XCTAssertEqual(ModelPresetResolver.resolve(userDefaults: defaults, physicalMemoryBytes: eightGB), .light)
    }

    // MARK: id <-> displayName (must never hardcode "0.6B")

    func testModelIDsAreDistinctAndRoundTrip() {
        XCTAssertNotEqual(ModelPreset.quality.modelID, ModelPreset.light.modelID)
        XCTAssertEqual(ModelPreset(modelID: ModelPreset.quality.modelID), .quality)
        XCTAssertEqual(ModelPreset(modelID: ModelPreset.light.modelID), .light)
    }

    func testDisplayNameForKnownModelIDsDerivesFromPreset() {
        XCTAssertEqual(ModelPreset.displayName(forModelID: ModelPreset.light.modelID), ModelPreset.light.displayName)
        XCTAssertEqual(ModelPreset.displayName(forModelID: ModelPreset.quality.modelID), ModelPreset.quality.displayName)
    }

    func testDisplayNameForUnknownModelIDFallsBackToRawID() {
        // A manually overridden / future model id that isn't one of the two
        // presets must not crash or silently mislabel as "0.6B" — it shows the
        // raw id verbatim.
        let custom = "mlx-community/Some-Other-Model-4bit"
        XCTAssertNil(ModelPreset(modelID: custom))
        XCTAssertEqual(ModelPreset.displayName(forModelID: custom), custom)
    }
}
