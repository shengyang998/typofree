// DiffLearner — pure classification of a commit→final-field edit into learnable
// signals. DESIGN.md §2.7 (diff→learn algorithm + thresholds), MF#7. No I/O, no
// AX, no sqlite: it takes what the IME committed and what the field ended up
// holding, and returns the homophone corrections + OOV insertions worth
// persisting. The `UserDictStore` (M7) durably records whatever this emits; the
// occurrence≥2 promotion and the base-lexicon "is this really OOV" filter are
// downstream concerns (part 2 wires them), so a candidate here is a *proposal*,
// not yet a boost.
//
// Algorithm (thresholds are DESIGN §2.7 verbatim):
//  1. Empty guards, then a **session-level reject gate FIRST** — an edit that
//     rewrote most of the text (`editRatio > 0.5`) or changed its length wildly
//     (`lengthDelta > 0.6`) is a semantic rewrite, not a correction: discard it.
//     A tiny commit (`committed.count ≤ 4`) is EXEMPT from the gate (its ratios
//     are unreliable on a 1–2 char denominator) so single-char swaps like 的→得
//     still get classified.
//  2. Group the char-level Myers diff into runs and walk them: an adjacent
//     delete-run / insert-run pair is a **substitution**; a lone insert-run is a
//     pure **insertion**.
//  3. A substitution of equal length ≤ 4 whose every position shares a toneless
//     reading between old and new (`PinyinReadingIndex`, ANY reading) is a
//     homophone correction → emit a boost for `new` under the shared-reading
//     keySeq plus a (contextPinyin, wrong, right) correction pair.
//  4. A lone insertion that is all-Han, ≤ 20 chars (the privacy span cap), and
//     fully re-encodable is a pending OOV → emit its reverse-lookup keySeq (the
//     zero-initial traps must come out right: 外→wd, 王→wh).
//  5. Everything else (pure deletions, unequal-length or non-homophone
//     substitutions, non-Han or over-long insertions) is ignored.
public enum DiffLearner {

    /// A homophone correction: under `keySeq` the user typed `wrong` but meant
    /// `right`. `contextPinyin` is the shared toneless reading per character (the
    /// disambiguating phonetic context); `keySeq` is its 小鹤 encoding — the key
    /// under which `right` earns a ranking boost.
    public struct CorrectionCandidate: Equatable, Sendable {
        public let keySeq: String
        public let wrong: String
        public let right: String
        public let contextPinyin: [String]
        public init(keySeq: String, wrong: String, right: String, contextPinyin: [String]) {
            self.keySeq = keySeq; self.wrong = wrong; self.right = right
            self.contextPinyin = contextPinyin
        }
    }

    /// A pending out-of-vocabulary word the user inserted, with the 小鹤 keySeq it
    /// would be typed as (reverse-lookup over its per-character readings).
    public struct OOVCandidate: Equatable, Sendable {
        public let keySeq: String
        public let word: String
        public init(keySeq: String, word: String) {
            self.keySeq = keySeq; self.word = word
        }
    }

    /// Why a whole edit was discarded before any per-op classification.
    public enum RejectReason: Equatable, Sendable {
        case editRatio(Double)
        case lengthDelta(Double)
        case emptyBase
        case emptyFinal
    }

    public struct Outcome: Equatable, Sendable {
        public let corrections: [CorrectionCandidate]
        public let oovCandidates: [OOVCandidate]
        public let rejected: RejectReason?
        public init(corrections: [CorrectionCandidate] = [],
                    oovCandidates: [OOVCandidate] = [],
                    rejected: RejectReason? = nil) {
            self.corrections = corrections
            self.oovCandidates = oovCandidates
            self.rejected = rejected
        }
    }

    /// DESIGN §2.7 thresholds — a value type so tests can pin the boundaries.
    public struct Config: Sendable {
        /// Reject the whole edit when the changed fraction exceeds this.
        public var editRatioLimit: Double = 0.5
        /// Reject the whole edit when |Δlength|/committed exceeds this.
        public var lengthDeltaLimit: Double = 0.6
        /// A commit no longer than this is exempt from the session-level gate.
        public var gateExemptionMaxChars: Int = 4
        /// A homophone substitution may be at most this many characters.
        public var substitutionMaxChars: Int = 4
        /// The privacy span cap — no learned span (OOV word) longer than this.
        public var spanMaxChars: Int = 20
        public init() {}
    }

    /// Classify the edit from `committedText` (what the IME put in) to
    /// `finalFieldText` (what the field held after the user's manual edits).
    /// `index` supplies toneless readings; `encoder` reverse-encodes them to 小鹤
    /// codes. Pure and deterministic.
    public static func evaluate(committedText: String,
                                finalFieldText: String,
                                index: PinyinReadingIndex,
                                encoder: ShuangpinDecoder,
                                config: Config = .init()) -> Outcome {
        let committed = Array(committedText)
        let final = Array(finalFieldText)
        guard !committed.isEmpty else { return Outcome(rejected: .emptyBase) }
        guard !final.isEmpty else { return Outcome(rejected: .emptyFinal) }

        let ops = MyersDiff.diff(committed, final)

        // Reject gate FIRST — but a tiny commit is exempt (unreliable ratios).
        if committed.count > config.gateExemptionMaxChars {
            var deleteCount = 0, insertCount = 0
            for op in ops {
                switch op {
                case .delete(let cs): deleteCount += cs.count
                case .insert(let cs): insertCount += cs.count
                case .equal: break
                }
            }
            let editRatio = Double(max(deleteCount, insertCount))
                / Double(max(committed.count, final.count, 1))
            if editRatio > config.editRatioLimit { return Outcome(rejected: .editRatio(editRatio)) }
            let lengthDelta = Double(abs(final.count - committed.count)) / Double(max(committed.count, 1))
            if lengthDelta > config.lengthDeltaLimit { return Outcome(rejected: .lengthDelta(lengthDelta)) }
        }

        var corrections: [CorrectionCandidate] = []
        var oovCandidates: [OOVCandidate] = []
        var i = 0
        while i < ops.count {
            switch ops[i] {
            case .equal:
                i += 1
            case .delete(let old):
                if i + 1 < ops.count, case .insert(let new) = ops[i + 1] {
                    classifySubstitution(old: old, new: new, index: index,
                                         encoder: encoder, config: config, into: &corrections)
                    i += 2                     // consumed delete + insert as a substitution
                } else {
                    i += 1                     // pure deletion — ignored
                }
            case .insert(let new):
                if i + 1 < ops.count, case .delete(let old) = ops[i + 1] {
                    classifySubstitution(old: old, new: new, index: index,
                                         encoder: encoder, config: config, into: &corrections)
                    i += 2
                } else {
                    classifyInsertion(new, index: index, encoder: encoder,
                                      config: config, into: &oovCandidates)
                    i += 1
                }
            }
        }
        return Outcome(corrections: corrections, oovCandidates: oovCandidates, rejected: nil)
    }

    // MARK: - Per-op classification

    private static func classifySubstitution(old: [Character], new: [Character],
                                             index: PinyinReadingIndex,
                                             encoder: ShuangpinDecoder,
                                             config: Config,
                                             into corrections: inout [CorrectionCandidate]) {
        guard old.count == new.count, old.count <= config.substitutionMaxChars else { return }
        var contextPinyin: [String] = []
        var keySeq = ""
        for (o, n) in zip(old, new) {
            // A homophone position: some reading of `new` is also a reading of
            // `old` AND is encodable. Iterate `new`'s readings in file order for a
            // deterministic pick.
            let oldReadings = index.readings(of: o)
            guard let shared = index.readings(of: n).first(where: { r in
                oldReadings.contains(r) && encoder.encode(syllable: r) != nil
            }), let code = encoder.encode(syllable: shared) else { return }
            contextPinyin.append(shared)
            keySeq += code
        }
        corrections.append(CorrectionCandidate(keySeq: keySeq, wrong: String(old),
                                               right: String(new), contextPinyin: contextPinyin))
    }

    private static func classifyInsertion(_ new: [Character],
                                          index: PinyinReadingIndex,
                                          encoder: ShuangpinDecoder,
                                          config: Config,
                                          into oovCandidates: inout [OOVCandidate]) {
        guard new.count <= config.spanMaxChars else { return }          // span > 20 not stored
        guard index.isAllHanzi(String(new), allowing: []) else { return }
        var keySeq = ""
        for ch in new {
            // First encodable reading (file order) for this character.
            guard let code = index.readings(of: ch).lazy
                .compactMap({ encoder.encode(syllable: $0) }).first else { return }
            keySeq += code
        }
        oovCandidates.append(OOVCandidate(keySeq: keySeq, word: String(new)))
    }
}
