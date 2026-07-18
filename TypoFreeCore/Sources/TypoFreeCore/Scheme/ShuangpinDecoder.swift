// ShuangpinDecoder — key sequence <-> toneless-pinyin, both directions.
// DESIGN.md §2.1. Pure value logic; no state, no I/O.
//
// `Syllable`/`DecodeResult` are the decoder's result types. DESIGN.md §1's file
// tree nominally lists `Syllable` under Engine/, but §2.1 defines it alongside
// the decoder and M1 owns it; it lives here so M1 is self-contained. Types are
// module-level in TypoFreeCore, so the file location does not affect imports —
// M3 (Engine) consumes these directly.

/// One 2-key double-pinyin unit.
public struct Syllable: Sendable, Equatable {
    /// The 2-char 小鹤 code, e.g. "hc".
    public let code: String
    /// The decoded toneless pinyin ("hao"); nil when `code` is not a legal
    /// (initial, final) combination for this scheme.
    public let pinyin: String?
    /// false = only half a syllable was typed (a lone initial). Entries produced
    /// by `decode` are always full 2-key units (true); a lone trailing key is
    /// surfaced via `DecodeResult.incompleteTail`, not here.
    public let isComplete: Bool

    public init(code: String, pinyin: String?, isComplete: Bool) {
        self.code = code
        self.pinyin = pinyin
        self.isComplete = isComplete
    }
}

public struct DecodeResult: Sendable, Equatable {
    /// The complete 2-key syllables, in order.
    public let syllables: [Syllable]
    /// A trailing single key (half a syllable) when the input length is odd;
    /// otherwise nil. The hybrid preedit (user-Q3) renders this as raw letters.
    public let incompleteTail: String?

    public init(syllables: [Syllable], incompleteTail: String?) {
        self.syllables = syllables
        self.incompleteTail = incompleteTail
    }

    /// The 2-char codes of the complete syllables (lexicon lookup keys).
    public var codes: [String] { syllables.map(\.code) }
}

public struct ShuangpinDecoder: Sendable {
    public let scheme: SchemeDefinition

    public init(scheme: SchemeDefinition) {
        self.scheme = scheme
    }

    /// Chunk a raw key buffer into complete 2-key syllables plus an optional
    /// trailing half-syllable key. Illegal 2-key chunks are kept (as syllables
    /// with `pinyin == nil`) so callers can still show/position them.
    public func decode(_ keys: String) -> DecodeResult {
        let chars = Array(keys)
        var syllables: [Syllable] = []
        var i = 0
        while i + 2 <= chars.count {
            let code = String(chars[i ..< i + 2])
            syllables.append(Syllable(code: code, pinyin: decodeSyllable(code), isComplete: true))
            i += 2
        }
        let tail: String? = (i < chars.count) ? String(chars[i]) : nil
        return DecodeResult(syllables: syllables, incompleteTail: tail)
    }

    /// A single 2-char code -> toneless pinyin, or nil for an illegal combination.
    public func decodeSyllable(_ twoKeys: String) -> String? {
        let chars = Array(twoKeys)
        guard chars.count == 2 else { return nil }
        let k1 = chars[0]
        // Zero-initial syllables are looked up whole (their spellings cannot be
        // derived by initial+final concatenation, EXPLORE.md Appendix A.3).
        if scheme.zeroInitialLeadKeys.contains(k1) {
            return scheme.zeroDecodeTable[twoKeys]
        }
        let k2 = chars[1]
        guard let initial = scheme.keyToInitial[k1],
              let cls = scheme.initialToClass[initial],
              let final = scheme.finalTable[cls]?[k2] else { return nil }
        return initial + final
    }

    /// Reverse: a single toneless-pinyin syllable -> 2-char code, or nil.
    public func encode(syllable pinyin: String) -> String? {
        // Zero-initial syllables start with a vowel / y / w and are never a
        // consonant-initial spelling, so this branch is unambiguous.
        if let code = scheme.zeroEncodeTable[pinyin] { return code }
        // Split initial + final, preferring the 2-char compressed initials
        // (zh/ch/sh) over their 1-char prefixes (z/c/s).
        for initialLen in [2, 1] where pinyin.count > initialLen {
            let initial = String(pinyin.prefix(initialLen))
            guard let k1 = scheme.initialToKey[initial],
                  let cls = scheme.initialToClass[initial] else { continue }
            let final = String(pinyin.dropFirst(initialLen))
            guard let k2 = scheme.finalReverse[cls]?[final] else { continue }
            return String([k1, k2])
        }
        return nil
    }

    /// Reverse for a whole word: encode each syllable and concatenate. nil if any
    /// syllable is not encodable (the whole word is then unusable as a key).
    public func encode(tonelessSyllables: [String]) -> String? {
        var result = ""
        for syllable in tonelessSyllables {
            guard let code = encode(syllable: syllable) else { return nil }
            result += code
        }
        return result
    }
}
