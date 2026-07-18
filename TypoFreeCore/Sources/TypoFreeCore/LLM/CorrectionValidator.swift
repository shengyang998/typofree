import Foundation

// The D12 gate — the single `CorrectionValidator` (DESIGN.md §2.4, MF#2/#3).
// It runs once, in the coordinator, backend-agnostically. The comparison space
// is unified on CODES (concatenated 小鹤 keystrokes; the anchor is
// `request.rawPinyin`). Multi-reading safety comes from `PinyinReadingIndex`
// (`readings.bin`): a character is a homophone of a code if ANY of its toneless
// readings matches — this is what stops the 的/地/得-class false-rejects.

public struct CorrectionConfig: Sendable {
    /// Max allowed |correctedHanziCount - syllableCount|.
    public var maxLengthDelta: Int = 1
    /// Minimum fraction of positions whose corrected character is a homophone
    /// of the typed code (derived from D8's edit-ratio ≤ 0.5 at equal length).
    public var minHomophoneRatio: Double = 0.5
    /// Punctuation tolerated inside an otherwise all-hanzi correction (stripped
    /// before the length + homophone alignment).
    public var allowedPunctuation: Set<Character> = ["，", "。", "！", "？", "、", "；", "："]

    public init() {}
}

public struct CorrectionValidator: Sendable {
    public let index: PinyinReadingIndex
    public let decoder: ShuangpinDecoder

    public init(index: PinyinReadingIndex, decoder: ShuangpinDecoder) {
        self.index = index
        self.decoder = decoder
    }

    /// Returns the trimmed accepted string on pass, else `nil` (caller silently
    /// falls back to `engineBest`). Order (DESIGN.md §2.4):
    ///   1. non-empty (after trim)
    ///   2. all-hanzi (allowing `config.allowedPunctuation`)
    ///   3. length ±`maxLengthDelta` vs the syllable count `N = rawPinyin/2`
    ///   4. per-character homophone hit-rate ≥ `minHomophoneRatio` — each core
    ///      hanzi re-pinyinized (any reading) against its aligned code.
    public func validate(_ result: CorrectionResult, against req: CorrectionRequest,
                         config: CorrectionConfig = .init()) -> String? {
        // 1. non-empty
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 2. all-hanzi (allowing punctuation)
        guard index.isAllHanzi(trimmed, allowing: config.allowedPunctuation) else { return nil }

        // Core = hanzi only (strip allowed punctuation) for length + alignment.
        let coreChars = Array(trimmed).filter { !config.allowedPunctuation.contains($0) }

        // 3. length ±maxLengthDelta vs the number of typed syllables.
        let codeChars = Array(req.rawPinyin)
        let n = codeChars.count / 2
        guard n > 0, codeChars.count == n * 2 else { return nil }
        guard abs(coreChars.count - n) <= config.maxLengthDelta else { return nil }

        // 4. per-character homophone hit-rate against the typed codes (any
        //    reading). Denominator is N (the anchor), so an insertion/deletion
        //    that misaligns naturally depresses the rate.
        let aligned = min(coreChars.count, n)
        var hits = 0
        for i in 0..<aligned {
            let code = String(codeChars[(i * 2)..<(i * 2 + 2)])
            guard let pinyin = decoder.decodeSyllable(code) else { continue }
            if index.readings(of: coreChars[i]).contains(pinyin) { hits += 1 }
        }
        let ratio = Double(hits) / Double(n)
        guard ratio >= config.minHomophoneRatio else { return nil }

        return trimmed
    }
}
