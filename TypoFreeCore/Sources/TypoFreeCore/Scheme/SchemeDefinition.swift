// Scheme model for double-pinyin (双拼) decoding — DESIGN.md §2.1.
//
// The core lattice/Viterbi/lexicon are 100% scheme-agnostic (DECISIONS.md
// "Architecture invariants"): decoding is data-driven by a `SchemeDefinition`.
// v1 ships exactly one instance, `FlypyScheme.flypy` (小鹤双拼). Decoding is a
// JOINT `(initialClass, finalKey) -> final` lookup plus a 35-entry zero-initial
// table — NOT two independent tables (EXPLORE.md Appendix A implementation note).

/// The minimal 5-way partition of flypy initials (EXPLORE.md Appendix A). The
/// meaning of an overloaded second key (o/k/l/s/x/v/t) is decided by which class
/// the leading initial belongs to, so `finalTable` is keyed by `InitialClass`.
public struct InitialClass: Sendable, Equatable, Hashable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

extension InitialClass {
    public static let bpmf   = InitialClass(rawValue: "bpmf")   // b p m f
    public static let dt     = InitialClass(rawValue: "dt")     // d t
    public static let nl     = InitialClass(rawValue: "nl")     // n l
    public static let jqx    = InitialClass(rawValue: "jqx")    // j q x
    public static let gkhzh  = InitialClass(rawValue: "gkhzh")  // g k h zh ch sh r z c s
}

/// Data-only description of a double-pinyin scheme. Holds the forward decode
/// tables; the `init` inverts them into the reverse tables used by `encode`,
/// asserting each inversion is injective (a scheme that maps two keys to the
/// same syllable/final could not round-trip).
public struct SchemeDefinition: Sendable, Equatable {
    /// Must equal the TFX1 lexicon blob header's `schemeId` (flypy = 1, §2.2).
    public let schemeId: UInt16
    public let displayName: String
    /// Keys that begin a zero-initial syllable: {a, e, o, w, y}. When a 2-key
    /// chunk starts with one of these, decoding goes straight to `zeroDecodeTable`.
    public let zeroInitialLeadKeys: Set<Character>
    /// First key -> initial (21 entries): the 18 literal initials plus the three
    /// compressed ones v->zh, i->ch, u->sh.
    public let keyToInitial: [Character: String]
    public let initialToClass: [String: InitialClass]
    /// JOINT final table: `finalTable[class][secondKey] = final`. A missing entry
    /// means the (initial, key) pair is not a legal syllable.
    public let finalTable: [InitialClass: [Character: String]]
    /// 2-char code -> zero-initial syllable (35 entries, EXPLORE.md Appendix A.3).
    public let zeroDecodeTable: [String: String]

    // Reverse tables, derived in `init` (injectivity checked), used by `encode`.
    public let initialToKey: [String: Character]
    public let finalReverse: [InitialClass: [String: Character]]
    public let zeroEncodeTable: [String: String]

    public init(schemeId: UInt16,
                displayName: String,
                zeroInitialLeadKeys: Set<Character>,
                keyToInitial: [Character: String],
                initialToClass: [String: InitialClass],
                finalTable: [InitialClass: [Character: String]],
                zeroDecodeTable: [String: String]) {
        self.schemeId = schemeId
        self.displayName = displayName
        self.zeroInitialLeadKeys = zeroInitialLeadKeys
        self.keyToInitial = keyToInitial
        self.initialToClass = initialToClass
        self.finalTable = finalTable
        self.zeroDecodeTable = zeroDecodeTable

        // initialToKey = invert keyToInitial (must be injective on initials).
        var initialToKey: [String: Character] = [:]
        for (key, initial) in keyToInitial {
            precondition(initialToKey[initial] == nil,
                "keyToInitial not injective: initial '\(initial)' produced by multiple keys")
            initialToKey[initial] = key
        }
        self.initialToKey = initialToKey

        // finalReverse = per-class invert of finalTable (injective within a class).
        var finalReverse: [InitialClass: [String: Character]] = [:]
        for (cls, table) in finalTable {
            var rev: [String: Character] = [:]
            for (key, final) in table {
                precondition(rev[final] == nil,
                    "finalTable[\(cls.rawValue)] not injective: final '\(final)' produced by multiple keys")
                rev[final] = key
            }
            finalReverse[cls] = rev
        }
        self.finalReverse = finalReverse

        // zeroEncodeTable = invert zeroDecodeTable (injective on syllables).
        var zeroEncodeTable: [String: String] = [:]
        for (code, syllable) in zeroDecodeTable {
            precondition(zeroEncodeTable[syllable] == nil,
                "zeroDecodeTable not injective: syllable '\(syllable)' produced by multiple codes")
            zeroEncodeTable[syllable] = code
        }
        self.zeroEncodeTable = zeroEncodeTable
    }

    /// The initial class of a first key, or nil if the key is not a real initial
    /// (i.e. it is a zero-initial lead key, or not a scheme key at all).
    public func initialClass(ofKey k1: Character) -> InitialClass? {
        guard let initial = keyToInitial[k1] else { return nil }
        return initialToClass[initial]
    }
}
