import XCTest
import Foundation
@testable import TypoFreeCore

/// M3 (DESIGN.md §2.3, MF#3/#5/#8) — `ConversionEngine` lattice + Viterbi +
/// user-boost overlay. All test classes are named `Engine*` so
/// `swift test --filter Engine` catches the whole milestone (mirroring M1's
/// `Scheme*` / M2's `Lexicon*` convention).
///
/// Most tests drive a hand-built TFX1 fixture (`TFX1Fixture`) so the frequencies
/// — and therefore the exact Viterbi outcome — are fully controlled; a couple
/// exercise the real bundled `lexicon.bin` end to end (smoke + perf).

/// Serializes `[key: [(word, rawCount)]]` into a TFX1 blob byte-for-byte the way
/// `tools/build_lexicon.py` / `LexiconBlobFormat` expect, so tests can mint a
/// lexicon with exactly the frequencies a given scenario needs.
enum TFX1Fixture {
    static func build(_ entries: [String: [(word: String, rawCount: Double)]]) -> Data {
        var body = Data()
        var totalPostings = 0
        for key in entries.keys.sorted() {
            let postings = entries[key]!
            let keyBytes = Array(key.utf8)
            body.append(UInt8(keyBytes.count))
            body.append(contentsOf: keyBytes)
            appendLE16(&body, UInt16(postings.count))
            totalPostings += postings.count
            for (word, rawCount) in postings {
                let wordBytes = Array(word.utf8)
                body.append(UInt8(wordBytes.count))
                body.append(contentsOf: wordBytes)
                appendLE32(&body, Float(log(1.0 + rawCount)).bitPattern)
            }
        }
        var header = Data()
        header.append(contentsOf: Array("TFX1".utf8))
        appendLE16(&header, 1) // formatVersion
        appendLE16(&header, 1) // schemeId (flypy)
        appendLE32(&header, UInt32(entries.count))
        appendLE32(&header, UInt32(totalPostings))
        return header + body
    }

    private static func appendLE16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func appendLE32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

/// Engine factory helpers, scoped to an enum so they don't add surface to the
/// shared `XCTestCase` namespace that later milestones' test files extend.
enum EngineTestFactory {
    static func fixtureEngine(_ entries: [String: [(word: String, rawCount: Double)]],
                             config: LatticeConfig = LatticeConfig()) throws -> ConversionEngine {
        let scheme = FlypyScheme.flypy
        let lexicon = try LexiconStore(data: TFX1Fixture.build(entries), scheme: scheme)
        return ConversionEngine(lexicon: lexicon, scheme: scheme, config: config)
    }

    static func realBlobEngine(config: LatticeConfig = LatticeConfig()) throws -> ConversionEngine {
        let scheme = FlypyScheme.flypy
        let lexicon = try LexiconStore.loadBundled(scheme: scheme)
        return ConversionEngine(lexicon: lexicon, scheme: scheme, config: config)
    }
}

// MARK: - Phrase vs. single-character segmentation

final class EnginePhraseVsSingleTests: XCTestCase {
    /// A common phrase whose length-bonused weight exceeds the sum of two rare
    /// singles is chosen as one span (你好), not split.
    func testPhraseBeatsSingleChars() throws {
        let engine = try EngineTestFactory.fixtureEngine([
            "nihc": [("你好", 50000)],
            "ni": [("妮", 10)],
            "hc": [("耗", 10)],
        ])
        let result = engine.convert("nihc", overlay: .empty, focus: 0)

        XCTAssertEqual(result.engineBest, "你好")
        XCTAssertEqual(result.bestPath, [WordSpan(word: "你好", code: "nihc", range: 0..<2)])
        XCTAssertEqual(result.syllableCount, 2)
        XCTAssertEqual(result.hanziCount, 2)
    }

    /// The mirror image: a rare phrase yields to two common singles, so the
    /// path splits into 妮 + 耗 (distinct chars, so `engineBest` differs from
    /// the phrase word 你好 and the choice is observable).
    func testRarePhraseYieldsToSingleChars() throws {
        let engine = try EngineTestFactory.fixtureEngine([
            "nihc": [("你好", 5)],
            "ni": [("妮", 5000)],
            "hc": [("耗", 5000)],
        ])
        let result = engine.convert("nihc", overlay: .empty, focus: 0)

        XCTAssertEqual(result.engineBest, "妮耗")
        XCTAssertEqual(result.bestPath, [
            WordSpan(word: "妮", code: "ni", range: 0..<1),
            WordSpan(word: "耗", code: "hc", range: 1..<2),
        ])
        XCTAssertEqual(result.hanziCount, 2)
    }
}

// MARK: - Deterministic tie-break

final class EngineTieBreakTests: XCTestCase {
    /// Two words sharing a key with identical frequency resolve by word
    /// (Unicode) ascending — regardless of their order in the blob. The fixture
    /// lists 阿 before 啊; the engine must still surface 啊 first.
    func testEqualFrequencyResolvesByWordAscending() throws {
        let engine = try EngineTestFactory.fixtureEngine(["aa": [("阿", 100), ("啊", 100)]])
        let candidates = engine.candidates(at: 0, syllableCodes: ["aa"], overlay: .empty)
        XCTAssertEqual(candidates.map(\.word), ["啊", "阿"])
        XCTAssertEqual(candidates.map(\.id), [0, 1])
    }

    /// Full recompute is reproducible: the same input yields an identical
    /// `EngineResult` (Equatable) across runs.
    func testConvertIsReproducible() throws {
        let engine = try EngineTestFactory.fixtureEngine([
            "nihc": [("你好", 500)], "ni": [("你", 1000)], "hc": [("好", 1000)],
        ])
        let a = engine.convert("nihc", overlay: .empty, focus: 0)
        let b = engine.convert("nihc", overlay: .empty, focus: 0)
        XCTAssertEqual(a, b)
    }
}

// MARK: - Fallback connectivity for unknown / illegal syllables

final class EngineFallbackTests: XCTestCase {
    /// An illegal 2-key combo (`br` — `r` is absent from the bpmf final table,
    /// so it decodes to nil) still yields a connected path: 你好 + the raw "br"
    /// keystrokes, and the fallback syllable is excluded from `hanziCount`.
    func testIllegalSyllableKeepsPathConnected() throws {
        let engine = try EngineTestFactory.fixtureEngine(["ni": [("你", 1000)], "hc": [("好", 1000)]])
        let result = engine.convert("nihcbr", overlay: .empty, focus: 0)

        XCTAssertEqual(result.engineBest, "你好br")
        XCTAssertEqual(result.bestPath, [
            WordSpan(word: "你", code: "ni", range: 0..<1),
            WordSpan(word: "好", code: "hc", range: 1..<2),
            WordSpan(word: "br", code: "br", range: 2..<3),
        ])
        XCTAssertEqual(result.syllableCount, 3)
        XCTAssertEqual(result.hanziCount, 2, "the fallback 'br' must not count as a hanzi")
    }

    /// A legal-but-absent syllable (`nj` -> "nan", no dictionary word) falls
    /// back to its readable pinyin, not the raw keystrokes.
    func testAbsentLegalSyllableFallsBackToPinyin() throws {
        let engine = try EngineTestFactory.fixtureEngine([:])
        let result = engine.convert("nj", overlay: .empty, focus: 0)

        XCTAssertEqual(result.engineBest, "nan")
        XCTAssertEqual(result.bestPath, [WordSpan(word: "nan", code: "nj", range: 0..<1)])
        XCTAssertEqual(result.hanziCount, 0)
        XCTAssertEqual(result.focusCandidates.first?.word, "nan")
        XCTAssertEqual(result.focusCandidates.first?.source, .fallback)
    }
}

// MARK: - Hybrid inline preedit (user-Q3)

final class EnginePreeditTests: XCTestCase {
    /// Completed syllables render as converted hanzi; a trailing half-syllable
    /// key renders as raw letters. `engineBest` excludes the raw tail.
    func testHybridPreeditIsHanziPlusRawTail() throws {
        let engine = try EngineTestFactory.fixtureEngine(["ni": [("你", 1000)], "hc": [("好", 1000)]])
        let result = engine.convert("nihcx", overlay: .empty, focus: 0)

        XCTAssertEqual(result.engineBest, "你好")
        XCTAssertEqual(result.incompleteTail, "x")
        XCTAssertEqual(result.preeditDisplay, "你好x")
        XCTAssertEqual(result.preeditCursor, 3)
        XCTAssertEqual(result.syllableCount, 2)
    }

    /// A lone half-syllable key: no syllables, preedit is just the raw letter.
    func testPureIncompleteTail() throws {
        let engine = try EngineTestFactory.fixtureEngine(["ni": [("你", 1000)]])
        let result = engine.convert("x", overlay: .empty, focus: 0)

        XCTAssertEqual(result.syllables, [])
        XCTAssertEqual(result.engineBest, "")
        XCTAssertEqual(result.incompleteTail, "x")
        XCTAssertEqual(result.preeditDisplay, "x")
        XCTAssertEqual(result.preeditCursor, 1)
        XCTAssertEqual(result.syllableCount, 0)
        XCTAssertTrue(result.focusCandidates.isEmpty)
    }

    /// Empty buffer: an all-empty result, no trap.
    func testEmptyBuffer() throws {
        let engine = try EngineTestFactory.fixtureEngine(["ni": [("你", 1000)]])
        let result = engine.convert("", overlay: .empty, focus: 0)

        XCTAssertEqual(result.engineBest, "")
        XCTAssertEqual(result.preeditDisplay, "")
        XCTAssertEqual(result.preeditCursor, 0)
        XCTAssertNil(result.incompleteTail)
        XCTAssertEqual(result.bestPath, [])
    }
}

// MARK: - User-boost overlay (MF#8)

final class EngineOverlayTests: XCTestCase {
    /// The mandated regression: an additive overlay boost re-ranks candidates.
    /// Base ranking puts 啊 first; boosting 阿 past it flips both `engineBest`
    /// and the candidate list, and the boosted winner is tagged `.userOverlay`.
    func testAdditiveBoostChangesRanking() throws {
        let engine = try EngineTestFactory.fixtureEngine(["aa": [("啊", 100), ("阿", 50)]])

        let base = engine.convert("aa", overlay: .empty, focus: 0)
        XCTAssertEqual(base.engineBest, "啊")
        XCTAssertEqual(base.focusCandidates.first?.word, "啊")
        XCTAssertEqual(base.focusCandidates.first?.source, .base)

        let overlay = UserBoostOverlay(boosts: ["aa": ["阿": 2.0]])
        let boosted = engine.convert("aa", overlay: overlay, focus: 0)
        XCTAssertEqual(boosted.engineBest, "阿")
        XCTAssertEqual(boosted.focusCandidates.first?.word, "阿")
        XCTAssertEqual(boosted.focusCandidates.first?.source, .userOverlay)
        // 啊 is still present, now ranked below the boosted 阿.
        XCTAssertEqual(boosted.focusCandidates.map(\.word), ["阿", "啊"])
    }

    /// The overlay can inject a word absent from the base lexicon (a learned
    /// OOV): with no base posting for "aa", the overlay word beats the
    /// synthetic pinyin fallback.
    func testOverlayInjectsOOVWord() throws {
        let engine = try EngineTestFactory.fixtureEngine([:])

        let cold = engine.convert("aa", overlay: .empty, focus: 0)
        XCTAssertEqual(cold.engineBest, "a", "with no lexicon entry, 'aa' falls back to its pinyin 'a'")

        let overlay = UserBoostOverlay(boosts: ["aa": ["嗄": 2.0]])
        let learned = engine.convert("aa", overlay: overlay, focus: 0)
        XCTAssertEqual(learned.engineBest, "嗄")
        XCTAssertEqual(learned.hanziCount, 1)
        XCTAssertEqual(learned.bestPath, [WordSpan(word: "嗄", code: "aa", range: 0..<1)])
    }
}

// MARK: - CandidateEngine wire protocol (MF#3)

/// A minimal main-actor conformer standing in for M5's app-shell engine — it
/// holds the candidate focus and forwards to the pure `ConversionEngine`. Its
/// only purpose here is to prove the overlay flows *through the wire boundary*
/// into the lattice.
@MainActor
private final class WireEngineHarness: CandidateEngine {
    let engine: ConversionEngine
    var focus: Int
    init(engine: ConversionEngine, focus: Int = 0) {
        self.engine = engine
        self.focus = focus
    }
    func recompute(rawKeys: String, overlay: UserBoostOverlay) -> EngineResult {
        engine.convert(rawKeys, overlay: overlay, focus: focus)
    }
}

@MainActor
final class EngineWireProtocolTests: XCTestCase {
    /// MF#3: the overlay passed to `CandidateEngine.recompute` reaches the
    /// lattice and changes the ranking — the exact gap the wire-protocol
    /// overlay parameter was added to close.
    func testOverlayFlowsThroughRecomputeAndChangesRanking() throws {
        let engine = try EngineTestFactory.fixtureEngine(["aa": [("啊", 100), ("阿", 50)]])
        let harness: CandidateEngine = WireEngineHarness(engine: engine)

        let base = harness.recompute(rawKeys: "aa", overlay: .empty)
        XCTAssertEqual(base.engineBest, "啊")

        let boosted = harness.recompute(rawKeys: "aa", overlay: UserBoostOverlay(boosts: ["aa": ["阿": 2.0]]))
        XCTAssertEqual(boosted.engineBest, "阿")
    }
}

// MARK: - Focus candidates / candidates(at:)

final class EngineFocusCandidatesTests: XCTestCase {
    /// Candidates for the focused segment span multiple lengths (single char +
    /// the phrase that starts there), globally ranked.
    func testFocusCandidatesSpanMultipleLengths() throws {
        let engine = try EngineTestFactory.fixtureEngine([
            "nihc": [("你好", 500)], "ni": [("你", 1000)], "hc": [("好", 1000)],
        ])
        let result = engine.convert("nihc", overlay: .empty, focus: 0)
        let words = result.focusCandidates.map(\.word)
        XCTAssertTrue(words.contains("你好"))
        XCTAssertTrue(words.contains("你"))
        let phrase = try XCTUnwrap(result.focusCandidates.first { $0.word == "你好" })
        XCTAssertEqual(phrase.syllableCount, 2)
    }

    /// Moving the focus re-queries the later segment cheaply.
    func testCandidatesAtNonZeroFocus() throws {
        let engine = try EngineTestFactory.fixtureEngine([
            "nihc": [("你好", 500)], "ni": [("你", 1000)], "hc": [("好", 1000)],
        ])
        let candidates = engine.candidates(at: 1, syllableCodes: ["ni", "hc"], overlay: .empty)
        XCTAssertEqual(candidates.first?.word, "好")
        XCTAssertEqual(candidates.first?.code, "hc")
    }

    /// Out-of-range focus is safe (empty, no trap).
    func testFocusOutOfRangeReturnsEmpty() throws {
        let engine = try EngineTestFactory.fixtureEngine(["ni": [("你", 1000)]])
        XCTAssertEqual(engine.candidates(at: 5, syllableCodes: ["ni"], overlay: .empty), [])
        XCTAssertEqual(engine.candidates(at: -1, syllableCodes: ["ni"], overlay: .empty), [])
    }
}

// MARK: - Clause boundary flag

final class EngineClauseBoundaryTests: XCTestCase {
    /// `endsAtClauseBoundary` is true when the converted text ends on a clause
    /// punctuation mark (the LLM immediate-trigger signal).
    func testEndsAtClauseBoundaryWhenLastCharIsPunctuation() throws {
        let engine = try EngineTestFactory.fixtureEngine(["aa": [("。", 100)]])
        let result = engine.convert("aa", overlay: .empty, focus: 0)
        XCTAssertEqual(result.engineBest, "。")
        XCTAssertTrue(result.endsAtClauseBoundary)
    }

    func testDoesNotEndAtClauseBoundaryForPlainHanzi() throws {
        let engine = try EngineTestFactory.fixtureEngine(["ni": [("你", 1000)], "hc": [("好", 1000)]])
        let result = engine.convert("nihc", overlay: .empty, focus: 0)
        XCTAssertFalse(result.endsAtClauseBoundary)
    }
}

// MARK: - Real bundled lexicon (smoke + performance)

final class EngineRealBlobTests: XCTestCase {
    /// End-to-end against the real `lexicon.bin`: "nihc" surfaces 你好 as a
    /// 2-syllable candidate and produces a non-empty hanzi conversion.
    func testRealBlobNihcSurfacesNihao() throws {
        let engine = try EngineTestFactory.realBlobEngine()
        let result = engine.convert("nihc", overlay: .empty, focus: 0)

        XCTAssertGreaterThan(result.hanziCount, 0)
        XCTAssertEqual(result.syllableCount, 2)
        let nihao = try XCTUnwrap(result.focusCandidates.first { $0.word == "你好" })
        XCTAssertEqual(nihao.syllableCount, 2)
    }

    /// Performance sanity (tasks.md M3): a 20-syllable convert against the real
    /// blob must stay well under 5ms; the assertion is deliberately generous
    /// (50ms) to avoid CI flake, but the actual timing is PRINTED.
    func testConvert20SyllablesIsFast() throws {
        let engine = try EngineTestFactory.realBlobEngine()
        let keys = String(repeating: "nihc", count: 10) // 40 keys = 20 syllables
        _ = engine.convert(keys, overlay: .empty, focus: 0) // warm up

        let iterations = 50
        let start = Date()
        for _ in 0..<iterations {
            _ = engine.convert(keys, overlay: .empty, focus: 0)
        }
        let msPerConvert = Date().timeIntervalSince(start) / Double(iterations) * 1000
        print(String(format: "‼️ [M3 perf] 20-syllable convert = %.4f ms (avg of %d)", msPerConvert, iterations))

        XCTAssertEqual(engine.convert(keys, overlay: .empty, focus: 0).syllableCount, 20)
        XCTAssertLessThan(msPerConvert, 50.0, "20-syllable convert took \(msPerConvert)ms, budget 50ms")
    }
}
