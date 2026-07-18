// ConversionEngine + EngineResult — the single deterministic engine entry
// point and its single (superset) result type. DESIGN.md §2.3, MF#5/#8.
//
// `convert(_:overlay:focus:)` is a pure, synchronous, full recompute per
// keystroke: decode the raw keys into syllables, build a word lattice from the
// base lexicon merged with the immutable user-boost overlay, run max-score
// Viterbi, and assemble everything the three consumers need — slot #2's
// `engineBest`, learning's per-word `bestPath`, and IMK's hybrid
// `preeditDisplay`. The overlay is a required parameter (`.empty` when cold) so
// a learned boost can never be stranded outside the lattice (MF#3/#8).

/// The one engine result type — a superset of all six original drafts. Carries
/// the LLM gate fields (`hanziCount`, `endsAtClauseBoundary`), learning's
/// `bestPath`, and IMK's inline `preeditDisplay`/`preeditCursor`.
public struct EngineResult: Sendable, Equatable {
    /// The complete 2-key syllables decoded from the raw buffer.
    public let syllables: [Syllable]
    /// Slot #2 — the deterministic 1-best whole-sentence conversion (the
    /// concatenated `bestPath` words; excludes any trailing incomplete key).
    public let engineBest: String
    /// The 1-best path as per-word spans, for learning keySeq attribution.
    public let bestPath: [WordSpan]
    /// The syllable index the candidate bar is focused on (slot #3+ source).
    public let focus: Int
    /// Candidates for the segment starting at `focus`, deterministically ranked.
    public let focusCandidates: [Candidate]
    /// A trailing half-syllable key (odd buffer length), else nil.
    public let incompleteTail: String?
    /// The inline marked text: hybrid preedit (user-Q3) — completed syllables
    /// as converted hanzi, the trailing incomplete syllable as raw letters.
    public let preeditDisplay: String
    /// Caret position within `preeditDisplay`, in Characters (end of buffer).
    public let preeditCursor: Int
    /// Count of hanzi in `engineBest` (fallback syllables excluded) — the LLM
    /// correction gate requires `>= minCharsForLLM`.
    public let hanziCount: Int
    /// Number of complete syllables decoded.
    public let syllableCount: Int
    /// True when `engineBest` ends at a clause boundary — LLM fires immediately,
    /// skipping the debounce.
    public let endsAtClauseBoundary: Bool

    public init(syllables: [Syllable], engineBest: String, bestPath: [WordSpan], focus: Int,
                focusCandidates: [Candidate], incompleteTail: String?, preeditDisplay: String,
                preeditCursor: Int, hanziCount: Int, syllableCount: Int, endsAtClauseBoundary: Bool) {
        self.syllables = syllables
        self.engineBest = engineBest
        self.bestPath = bestPath
        self.focus = focus
        self.focusCandidates = focusCandidates
        self.incompleteTail = incompleteTail
        self.preeditDisplay = preeditDisplay
        self.preeditCursor = preeditCursor
        self.hanziCount = hanziCount
        self.syllableCount = syllableCount
        self.endsAtClauseBoundary = endsAtClauseBoundary
    }
}

/// The deterministic conversion engine — decoder + lexicon + lattice, all pure.
/// A `Sendable` value: the lexicon is an immutable `Sendable` store, the scheme
/// and config are value types. Safe to hold anywhere and call on any actor.
public struct ConversionEngine: Sendable {
    public let scheme: SchemeDefinition
    public let decoder: ShuangpinDecoder
    public let lexicon: LexiconStore
    public let config: LatticeConfig

    public init(lexicon: LexiconStore, scheme: SchemeDefinition, config: LatticeConfig) {
        self.scheme = scheme
        self.decoder = ShuangpinDecoder(scheme: scheme)
        self.lexicon = lexicon
        self.config = config
    }

    /// Full per-keystroke recompute. Pure and synchronous (sub-ms). `overlay`
    /// is required (`.empty` when cold) so its additive boosts always reach the
    /// lattice (MF#8). `focus` selects which segment's alternatives populate
    /// `focusCandidates`.
    public func convert(_ keys: String, overlay: UserBoostOverlay, focus: Int) -> EngineResult {
        let decoded = decoder.decode(keys)
        let syllables = decoded.syllables
        let tail = decoded.incompleteTail
        let n = syllables.count

        guard n > 0 else {
            // Nothing to convert yet — only a trailing half-syllable (or empty).
            let tailStr = tail ?? ""
            return EngineResult(
                syllables: [], engineBest: "", bestPath: [], focus: focus,
                focusCandidates: [], incompleteTail: tail, preeditDisplay: tailStr,
                preeditCursor: tailStr.count, hanziCount: 0, syllableCount: 0,
                endsAtClauseBoundary: false)
        }

        let codes = syllables.map(\.code)

        // Build the lattice: the single best edge per span, plus a synthetic
        // single-syllable fallback whenever a syllable has no dictionary word,
        // so every node j in 1...n has at least the [j-1, j) edge (connectivity).
        var edgesByEnd = [[SpanEdge]](repeating: [], count: n + 1)
        for i in 0..<n {
            let maxEnd = min(i + config.maxSpanSyllables, n)
            for j in (i + 1)...maxEnd {
                let key = codes[i..<j].joined()
                if let edge = bestSpanEdge(start: i, end: j, key: key, overlay: overlay) {
                    edgesByEnd[j].append(edge)
                } else if j == i + 1 {
                    edgesByEnd[j].append(fallbackEdge(at: i, syllable: syllables[i]))
                }
            }
        }

        let path = Lattice.bestPath(nodeCount: n, edgesByEnd: edgesByEnd, config: config)

        let bestPath = path.map { WordSpan(word: $0.word, code: $0.code, range: $0.start..<$0.end) }
        let engineBest = path.map(\.word).joined()
        // Fallback (non-hanzi) syllables never count toward the LLM gate.
        let hanziCount = path.reduce(0) { $0 + ($1.source == .fallback ? 0 : $1.word.count) }
        let tailStr = tail ?? ""
        let preeditDisplay = engineBest + tailStr
        let endsAtClause = engineBest.last.map { config.clauseBoundary.contains($0) } ?? false
        let focusCandidates = candidates(at: focus, syllableCodes: codes, overlay: overlay)

        return EngineResult(
            syllables: syllables, engineBest: engineBest, bestPath: bestPath, focus: focus,
            focusCandidates: focusCandidates, incompleteTail: tail, preeditDisplay: preeditDisplay,
            preeditCursor: preeditDisplay.count, hanziCount: hanziCount, syllableCount: n,
            endsAtClauseBoundary: endsAtClause)
    }

    /// Cheap re-query of the focused segment's candidates without re-running
    /// decode/Viterbi — used when the UI only moves the focus. Returns all
    /// candidate spans starting at `focus` (up to `maxCandidateSyllables`),
    /// globally ranked, `id` = rank. Guarantees at least one option for the
    /// single-syllable segment (a fallback when it has no dictionary word).
    public func candidates(at focus: Int, syllableCodes: [String], overlay: UserBoostOverlay) -> [Candidate] {
        let n = syllableCodes.count
        guard focus >= 0, focus < n else { return [] }

        var edges: [SpanEdge] = []
        let maxEnd = min(focus + config.maxCandidateSyllables, n)
        for j in (focus + 1)...maxEnd {
            let key = syllableCodes[focus..<j].joined()
            edges.append(contentsOf: spanCandidates(start: focus, end: j, key: key, overlay: overlay))
        }
        if !edges.contains(where: { $0.end == focus + 1 }) {
            let code = syllableCodes[focus]
            edges.append(SpanEdge(
                start: focus, end: focus + 1, word: decoder.decodeSyllable(code) ?? code, code: code,
                logFreq: config.floorLogFreq, boostedLogFreq: config.floorLogFreq, source: .fallback))
        }
        edges.sort { $0.isBetterCandidate(than: $1, config: config) }
        return edges.enumerated().map { index, edge in
            Candidate(id: index, word: edge.word, code: edge.code, syllableCount: edge.length,
                      score: edge.weight(config), source: edge.source)
        }
    }

    // MARK: - Span resolution (base lexicon merged with the additive overlay)

    /// All candidate edges for one span key — base postings merged with any
    /// overlay boosts for that key. Unsorted. Empty when the key is unknown to
    /// both. A word in both sums (base logFreq + delta); an overlay-only word
    /// is scored as base 0 + delta.
    private func spanEdges(start: Int, end: Int, key: String, overlay: UserBoostOverlay) -> [SpanEdge] {
        let basePostings = lexicon.postings(forKey: key)
        let overlayMap = overlay.boostMap(forKey: key)

        guard let overlayMap, !overlayMap.isEmpty else {
            // Fast path: no overlay for this key — every candidate is pure base.
            return basePostings.map {
                SpanEdge(start: start, end: end, word: $0.word, code: key,
                         logFreq: Double($0.logFreq), boostedLogFreq: Double($0.logFreq), source: .base)
            }
        }

        var edges: [SpanEdge] = []
        edges.reserveCapacity(basePostings.count + overlayMap.count)
        var seen = Set<String>()
        for posting in basePostings {
            let delta = overlayMap[posting.word]
            let base = Double(posting.logFreq)
            edges.append(SpanEdge(
                start: start, end: end, word: posting.word, code: key,
                logFreq: base, boostedLogFreq: base + Double(delta ?? 0),
                source: delta != nil ? .userOverlay : .base))
            seen.insert(posting.word)
        }
        for (word, delta) in overlayMap where !seen.contains(word) {
            edges.append(SpanEdge(
                start: start, end: end, word: word, code: key,
                logFreq: 0, boostedLogFreq: Double(delta), source: .userOverlay))
        }
        return edges
    }

    /// The single best edge for a span, or nil when neither base nor overlay
    /// knows the key. One pass (no sort) — this is the Viterbi hot path.
    private func bestSpanEdge(start: Int, end: Int, key: String, overlay: UserBoostOverlay) -> SpanEdge? {
        let edges = spanEdges(start: start, end: end, key: key, overlay: overlay)
        guard var best = edges.first else { return nil }
        for edge in edges.dropFirst() where edge.isBetterCandidate(than: best, config: config) {
            best = edge
        }
        return best
    }

    /// The sorted candidate list for a span (best first).
    private func spanCandidates(start: Int, end: Int, key: String, overlay: UserBoostOverlay) -> [SpanEdge] {
        spanEdges(start: start, end: end, key: key, overlay: overlay)
            .sorted { $0.isBetterCandidate(than: $1, config: config) }
    }

    /// The synthetic connectivity edge for a syllable with no dictionary word:
    /// shows its readable pinyin when the combination is legal, else the raw
    /// keystrokes; scored at `floorLogFreq` so any real word outranks it.
    private func fallbackEdge(at i: Int, syllable: Syllable) -> SpanEdge {
        SpanEdge(start: i, end: i + 1, word: syllable.pinyin ?? syllable.code, code: syllable.code,
                 logFreq: config.floorLogFreq, boostedLogFreq: config.floorLogFreq, source: .fallback)
    }
}
