// UserBoostOverlay — the user-dictionary boost layer. DESIGN.md §2.3 / §2.8,
// MF#8.
//
// Representation is an **immutable snapshot** (not a lock-guarded cache): the
// learning loop rebuilds a fresh snapshot from a `BoostUpdate` delta and swaps
// it in atomically on the MainActor (M7's `OverlayHost`). The conversion hot
// path only ever reads one immutable reference, lock-free. Every recompute
// takes an overlay (`.empty` when the user dictionary is cold), so a learned
// boost can never be "stranded" outside the lattice (the MF#3/MF#8 fix).
//
// `boosts[code][word]` is an **additive** log-domain delta layered onto the
// base lexicon's `logFreq` at query time. A word present here but absent from
// the base lexicon (a learned OOV) is treated as base `logFreq == 0` plus this
// delta, so it competes as a first-class candidate; a word present in both has
// its base `logFreq` and this delta summed.
public struct UserBoostOverlay: Sendable, Equatable {
    /// code (concatenated 小鹤 keystrokes, same format as a lexicon key)
    /// -> word -> additive log-boost delta.
    public let boosts: [String: [String: Float]]

    public init(boosts: [String: [String: Float]]) {
        self.boosts = boosts
    }

    /// The empty overlay — no learned boosts. The default passed on a cold
    /// user dictionary so `convert(_:overlay:focus:)` always has an overlay.
    public static let empty = UserBoostOverlay(boosts: [:])

    /// The per-word boost map for `key`, or nil when the key carries no boosts.
    /// Kept internal — the engine reads it directly on the hot path.
    func boostMap(forKey key: String) -> [String: Float]? {
        boosts[key]
    }
}
