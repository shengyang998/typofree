// OverlayHost + BoostUpdate — the immutable-snapshot side of the user-boost
// overlay. DESIGN.md §2.8 (MF#8 decision: an immutable snapshot atomically
// swapped in, NOT a lock-guarded cache).
//
// The write side (`UserDictStore`, an actor) produces a durable count bump and
// returns a `BoostUpdate` delta; the MainActor `OverlayHost` rebuilds a fresh
// `UserBoostOverlay` with that delta merged and swaps its `current` reference in
// one assignment. The conversion hot path only ever reads that one immutable
// reference (through `SessionDependencies.overlayProvider`), lock-free — part 2
// wires the provider closure to `OverlayHost.snapshot`.

/// A durable boost delta: `word` now boosts by `boost` (= `log(1+count)`) under
/// `keySeq`. Produced by `UserDictStore` once an occurrence reaches the ≥2
/// promotion threshold; consumed by `OverlayHost.apply`.
public struct BoostUpdate: Sendable, Equatable {
    public let keySeq: String
    public let word: String
    public let boost: Double
    public init(keySeq: String, word: String, boost: Double) {
        self.keySeq = keySeq
        self.word = word
        self.boost = boost
    }
}

/// Holds the current immutable `UserBoostOverlay` and swaps a fresh snapshot in
/// atomically on every reload. MainActor-isolated: the hot path reads `current`
/// on the MainActor with no lock.
@MainActor public final class OverlayHost {
    public private(set) var current: UserBoostOverlay

    public init(initial: UserBoostOverlay = .empty) {
        self.current = initial
    }

    /// The immutable snapshot for the conversion hot path — the value
    /// `SessionDependencies.overlayProvider` returns.
    public func snapshot() -> UserBoostOverlay { current }

    /// Merge one durable delta and atomically swap in a fresh snapshot. Rebuilds
    /// rather than mutating so any reference already handed out stays unchanged.
    public func apply(_ update: BoostUpdate) {
        var boosts = current.boosts
        boosts[update.keySeq, default: [:]][update.word] = Float(update.boost)
        current = UserBoostOverlay(boosts: boosts)
    }

    /// Replace the whole overlay atomically — used on a full reload from
    /// `UserDictStore.loadBoostOverlay()` (e.g. after `clearAll`).
    public func replaceAll(_ overlay: UserBoostOverlay) {
        current = overlay
    }
}
