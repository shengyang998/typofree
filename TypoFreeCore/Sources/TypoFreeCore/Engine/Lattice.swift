// Lattice — the pure max-score Viterbi over a word lattice, plus the tuning
// constants (`LatticeConfig`) and the internal edge type (`SpanEdge`).
// DESIGN.md §2.3. This file knows nothing about the lexicon or the overlay;
// `ConversionEngine` builds the edges (merging base postings + user boosts) and
// hands them here. Keeping the DP lexicon-agnostic makes it unit-testable with
// hand-built edges and keeps the whole thing a pure, synchronous, sub-ms value
// computation (full recompute per keystroke — DECISIONS.md "conversion").

/// Tuning constants for the conversion lattice. All `var` so the app shell can
/// calibrate against real typing (DESIGN.md flags `lengthBonusPerSyllable` and
/// `floorLogFreq` as UX-load-bearing). A value type — mutation copies.
public struct LatticeConfig: Sendable {
    /// Added per extra syllable a single word covers, biasing the segmentation
    /// toward fewer, longer words. `lengthBonus(len) = perSyllable * (len - 1)`.
    public var lengthBonusPerSyllable: Double = 2.0
    /// Score of a synthetic single-syllable fallback edge. Must be below any
    /// real `logFreq` (which is `ln(1 + rawCount) >= 0`) so a real word always
    /// beats the connectivity fallback.
    public var floorLogFreq: Double = -1.0
    /// Longest span (in syllables) the Viterbi will consider as one word.
    public var maxSpanSyllables: Int = 8
    /// Longest candidate span offered to the UI for the focused segment.
    public var maxCandidateSyllables: Int = 4
    /// Minimum hanzi before the LLM correction gate is even eligible (§2.4).
    public var minCharsForLLM: Int = 4
    /// Characters that end a clause — drive `EngineResult.endsAtClauseBoundary`
    /// (LLM fires immediately, skipping debounce, at a clause end).
    public var clauseBoundary: Set<Character> = ["，", "。", "！", "？", "、", "；", "：", ",", ".", "!", "?"]

    public init() {}

    /// The length bonus for a word covering `len` syllables (0 for a single
    /// syllable). Internal — only the engine and edges consult it.
    func lengthBonus(_ len: Int) -> Double {
        lengthBonusPerSyllable * Double(len - 1)
    }
}

/// One lattice edge: the span `[start, end)` resolved to its single best word,
/// with the frequencies needed both to score the path and to break ties
/// deterministically. Internal — an implementation detail of `ConversionEngine`
/// / `Lattice`, reachable from tests via `@testable import`.
struct SpanEdge: Sendable, Equatable {
    let start: Int
    let end: Int
    let word: String
    /// Concatenated 小鹤 keystrokes for `[start, end)` = the lexicon key.
    let code: String
    /// The chosen word's **base** logFreq (0 for an overlay-only OOV word,
    /// `floorLogFreq` for a fallback) — a tie-break axis, never boosted.
    let logFreq: Double
    /// `logFreq` plus any additive user-boost delta — the scored quantity.
    let boostedLogFreq: Double
    let source: CandidateSource

    var length: Int { end - start }

    /// The path-scoring weight of taking this edge: boosted frequency plus the
    /// length bonus for how many syllables it spans.
    func weight(_ config: LatticeConfig) -> Double {
        boostedLogFreq + config.lengthBonus(length)
    }

    /// Deterministic candidate ordering (DESIGN.md §2.3 global tie-break):
    /// weight desc, then base logFreq desc, then length desc, then word
    /// (Unicode) ascending. Total order over distinct edges, so sorting and
    /// max-selection are reproducible run to run.
    func isBetterCandidate(than other: SpanEdge, config: LatticeConfig) -> Bool {
        let w = weight(config), ow = other.weight(config)
        if w != ow { return w > ow }
        if logFreq != other.logFreq { return logFreq > other.logFreq }
        if length != other.length { return length > other.length }
        return word < other.word
    }
}

/// Pure max-score Viterbi over forward edges. Lexicon-agnostic: the caller
/// (`ConversionEngine`) has already resolved each span to its best `SpanEdge`
/// and guaranteed connectivity (every node `j` in `1...n` has at least the
/// `[j-1, j)` edge), so a full 0→n path always exists.
enum Lattice {
    /// Returns the highest-scoring 0→n path as an ordered `[SpanEdge]`.
    /// `edgesByEnd[j]` holds every edge whose `end == j`. Empty for `n == 0`.
    static func bestPath(nodeCount n: Int, edgesByEnd: [[SpanEdge]], config: LatticeConfig) -> [SpanEdge] {
        guard n > 0 else { return [] }
        var best = [Double](repeating: -.infinity, count: n + 1)
        var backEdge = [SpanEdge?](repeating: nil, count: n + 1)
        best[0] = 0

        for j in 1...n {
            for edge in edgesByEnd[j] {
                let start = edge.start
                guard best[start] > -.infinity else { continue }
                let total = best[start] + edge.weight(config)
                if let current = backEdge[j] {
                    if isBetterPath(newTotal: total, newEdge: edge,
                                    oldTotal: best[j], oldEdge: current) {
                        best[j] = total
                        backEdge[j] = edge
                    }
                } else {
                    best[j] = total
                    backEdge[j] = edge
                }
            }
        }

        var path: [SpanEdge] = []
        var j = n
        while j > 0, let edge = backEdge[j] {
            path.append(edge)
            j = edge.start
        }
        return path.reversed()
    }

    /// Global tie-break for two competing ways to reach the same node: total
    /// path score desc, then the final edge's base logFreq desc, length desc,
    /// word ascending. Mirrors `SpanEdge.isBetterCandidate` on the last edge so
    /// the whole engine is reproducible.
    private static func isBetterPath(newTotal: Double, newEdge: SpanEdge,
                                     oldTotal: Double, oldEdge: SpanEdge) -> Bool {
        if newTotal != oldTotal { return newTotal > oldTotal }
        if newEdge.logFreq != oldEdge.logFreq { return newEdge.logFreq > oldEdge.logFreq }
        if newEdge.length != oldEdge.length { return newEdge.length > oldEdge.length }
        return newEdge.word < oldEdge.word
    }
}
