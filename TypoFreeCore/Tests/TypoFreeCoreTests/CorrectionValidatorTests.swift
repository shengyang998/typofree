import XCTest
@testable import TypoFreeCore

/// M4 (DESIGN.md §2.4/§9, MF#2/#3) — the D12 gate `CorrectionValidator`. The
/// five mandated cases plus edges. Codes are derived from the real
/// `ShuangpinDecoder.encode`, and heteronym coverage rides the real bundled
/// `readings.bin`, so multi-reading acceptance is proven against production data.
final class CorrectionValidatorTests: XCTestCase {
    private func validator() throws -> CorrectionValidator { try LLMTestFactory.realValidator() }
    private func codes(_ s: [String]) -> String { LLMTestFactory.codes(s) }

    // MARK: 1. accept a homophone correction

    func testAcceptsHomophoneCorrection() throws {
        let v = try validator()
        // user typed yi+jing, engine mis-picked 以经; 已经 is the homophone fix.
        let raw = codes(["yi", "jing"])
        XCTAssertFalse(raw.isEmpty)
        let req = CorrectionRequest(id: 1, precedingContext: "", rawPinyin: raw, engineBest: "以经")
        let out = v.validate(CorrectionResult(text: "已经", backend: .mlx), against: req)
        XCTAssertEqual(out, "已经")
    }

    /// A candidate that is already correct passes through unchanged.
    func testAcceptsUnchangedCorrectCandidate() throws {
        let v = try validator()
        let raw = codes(["jin", "tian", "tian", "qi"])
        let req = CorrectionRequest(id: 2, precedingContext: "", rawPinyin: raw, engineBest: "今天天气")
        XCTAssertEqual(v.validate(CorrectionResult(text: "今天天气", backend: .mlx), against: req), "今天天气")
    }

    // MARK: 2. reject non-hanzi (latin) contamination

    func testRejectsLatinPrefix() throws {
        let v = try validator()
        let raw = codes(["yi", "jing"])
        let req = CorrectionRequest(id: 3, precedingContext: "", rawPinyin: raw, engineBest: "以经")
        XCTAssertNil(v.validate(CorrectionResult(text: "OK已经", backend: .mlx), against: req))
        XCTAssertNil(v.validate(CorrectionResult(text: "已经!", backend: .mlx), against: req),
                     "ASCII '!' is not in the allowed punctuation set")
    }

    // MARK: 3. reject length drift (> maxLengthDelta)

    func testRejectsLengthDrift() throws {
        let v = try validator()
        let raw = codes(["ni", "hao"]) // 2 syllables
        let req = CorrectionRequest(id: 4, precedingContext: "", rawPinyin: raw, engineBest: "你好")
        // 4 hanzi vs 2 syllables → delta 2 > 1.
        XCTAssertNil(v.validate(CorrectionResult(text: "你好世界", backend: .mlx), against: req))
    }

    // MARK: 4. reject a hallucination (right length, all hanzi, wrong sounds)

    func testRejectsHallucination() throws {
        let v = try validator()
        let raw = codes(["ni", "hao"]) // sounds ni + hao
        let req = CorrectionRequest(id: 5, precedingContext: "", rawPinyin: raw, engineBest: "你好")
        // 世界 = shi + jie: neither is a homophone of ni/hao → hit rate 0 < 0.5.
        XCTAssertNil(v.validate(CorrectionResult(text: "世界", backend: .mlx), against: req))
    }

    // MARK: 5. heteronym must NOT be mis-rejected (multi-reading data source)

    func testHeteronymNotMisRejected() throws {
        let v = try validator()
        // 银行: 行's SECOND reading "hang" (first is "xing"). A first-reading-only
        // index would false-reject; the real readings.bin has ["xing","hang","heng"].
        let bankRaw = codes(["yin", "hang"])
        XCTAssertFalse(bankRaw.isEmpty)
        let bankReq = CorrectionRequest(id: 6, precedingContext: "", rawPinyin: bankRaw, engineBest: "银行")
        XCTAssertEqual(v.validate(CorrectionResult(text: "银行", backend: .mlx), against: bankReq), "银行")

        // 得 typed as "dei" (its 得/dei reading, not the first "de").
        let deiRaw = codes(["dei"])
        XCTAssertFalse(deiRaw.isEmpty)
        let deiReq = CorrectionRequest(id: 7, precedingContext: "", rawPinyin: deiRaw, engineBest: "得")
        XCTAssertEqual(v.validate(CorrectionResult(text: "得", backend: .mlx), against: deiReq), "得")
    }

    // MARK: edges

    func testRejectsEmptyAndWhitespace() throws {
        let v = try validator()
        let req = CorrectionRequest(id: 8, precedingContext: "", rawPinyin: codes(["ni", "hao"]), engineBest: "你好")
        XCTAssertNil(v.validate(CorrectionResult(text: "", backend: .mlx), against: req))
        XCTAssertNil(v.validate(CorrectionResult(text: "   \n ", backend: .mlx), against: req))
    }

    func testTrimsSurroundingWhitespaceOnAccept() throws {
        let v = try validator()
        let req = CorrectionRequest(id: 9, precedingContext: "", rawPinyin: codes(["ni", "hao"]), engineBest: "你好")
        XCTAssertEqual(v.validate(CorrectionResult(text: "  你好 \n", backend: .mlx), against: req), "你好")
    }

    /// Interior allowed punctuation is tolerated and preserved on accept.
    func testAllowsInteriorPunctuation() throws {
        let v = try validator()
        let raw = codes(["ni", "hao", "shi", "jie"])
        let req = CorrectionRequest(id: 10, precedingContext: "", rawPinyin: raw, engineBest: "你好世界")
        XCTAssertEqual(v.validate(CorrectionResult(text: "你好，世界", backend: .mlx), against: req), "你好，世界")
    }

    /// A fallback-bearing composition anchors on a rawPinyin whose length no
    /// longer equals 2×(hanzi count); the gate conservatively rejects (the M3
    /// handoff gotcha).
    func testRejectsWhenAnchorLengthCannotAlign() throws {
        let v = try validator()
        // 3 syllables of codes, but a 2-hanzi correction → 6 vs 2 → delta 1?
        // No: n = 3, coreChars = 2, |2-3| = 1 ≤ 1 passes length; homophones then
        // decide. Use a genuinely un-decodable-length anchor instead:
        let req = CorrectionRequest(id: 11, precedingContext: "", rawPinyin: "abc", engineBest: "你")
        XCTAssertNil(v.validate(CorrectionResult(text: "你", backend: .mlx), against: req),
                     "odd-length rawPinyin (3 chars) can't be 2-per-syllable codes")
    }
}
