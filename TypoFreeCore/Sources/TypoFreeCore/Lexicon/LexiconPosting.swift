// LexiconPosting — one (word, frequency) entry inside a lexicon key's posting
// list. DESIGN.md §2.2.

/// One base-lexicon candidate for a given shuangpin key: the word text and
/// its pre-computed `logFreq = ln(1 + rawCount)`. This is **not** combined
/// with any length bonus — that combination is `ConversionEngine`'s Viterbi
/// concern (M3), not the lexicon layer's.
public struct LexiconPosting: Sendable, Equatable {
    public let word: String
    public let logFreq: Float

    public init(word: String, logFreq: Float) {
        self.word = word
        self.logFreq = logFreq
    }
}
