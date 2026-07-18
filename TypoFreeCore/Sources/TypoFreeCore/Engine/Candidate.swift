// Candidate / WordSpan / CandidateSource — the unified engine value types.
// DESIGN.md §2.3, MF#5. These are the single set of result building blocks all
// six original module drafts converge on: `WordSpan` carries what learning
// needs (per-word keySeq attribution), `Candidate` is what the candidate bar
// renders, and both are pure `Sendable` value types crossing the Core boundary.

/// Where a candidate/edge's score came from — drives the candidate bar's
/// visual treatment and (for `.fallback`) excludes synthetic connectivity
/// syllables from `EngineResult.hanziCount`.
public enum CandidateSource: Sendable, Equatable {
    /// A base-lexicon posting with no user-dictionary boost applied.
    case base
    /// A word the user-boost overlay contributed to (either boosted a base
    /// posting, or injected a learned OOV word not in the base lexicon).
    case userOverlay
    /// A synthetic single-syllable edge inserted only to keep the lattice
    /// connected when a syllable has no dictionary word (typo / OOV input).
    case fallback
}

/// One word occupying a contiguous run of syllables in the 1-best path.
/// Learning (M7) attributes the committed keystrokes to a word through this:
/// `code` is the concatenated 小鹤 keystrokes for `range`, in the same format
/// as a lexicon key.
public struct WordSpan: Sendable, Equatable {
    public let word: String
    /// The concatenated 小鹤 keystrokes covering `range` — same format as a
    /// lexicon blob key (2 chars per syllable).
    public let code: String
    /// The half-open syllable-index interval `[i, j)` this word covers.
    public let range: Range<Int>
    public var syllableCount: Int { range.count }

    public init(word: String, code: String, range: Range<Int>) {
        self.word = word
        self.code = code
        self.range = range
    }
}

/// One selectable candidate for the segment starting at the focused syllable
/// (candidate-bar slot #3+). `id` is its 0-based rank in the returned,
/// deterministically-sorted list; `score` is the full lattice edge weight
/// (boosted logFreq + length bonus) used for that ranking.
public struct Candidate: Sendable, Equatable, Identifiable {
    public let id: Int
    public let word: String
    /// Concatenated 小鹤 keystrokes for this candidate's span (lexicon-key format).
    public let code: String
    public let syllableCount: Int
    public let score: Double
    public let source: CandidateSource

    public init(id: Int, word: String, code: String, syllableCount: Int, score: Double, source: CandidateSource) {
        self.id = id
        self.word = word
        self.code = code
        self.syllableCount = syllableCount
        self.score = score
        self.source = source
    }
}
