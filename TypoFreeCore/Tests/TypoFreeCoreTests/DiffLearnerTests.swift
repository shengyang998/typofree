import XCTest
@testable import TypoFreeCore

// DiffLearner (DESIGN.md §2.7). Uses the REAL bundled `readings.bin` + flypy
// decoder so the homophone intersection (的/得, 在/再) and the zero-initial OOV
// traps (外→wd, 王→wh) are exercised end to end, not against a hand-built map.
final class DiffLearnerTests: XCTestCase {

    private var index: PinyinReadingIndex!
    private var decoder: ShuangpinDecoder!

    override func setUpWithError() throws {
        index = try PinyinReadingIndex.loadBundled()
        decoder = ShuangpinDecoder(scheme: FlypyScheme.flypy)
    }

    private func evaluate(_ committed: String, _ final: String,
                          config: DiffLearner.Config = .init()) -> DiffLearner.Outcome {
        DiffLearner.evaluate(committedText: committed, finalFieldText: final,
                             index: index, encoder: decoder, config: config)
    }

    // MARK: - Homophone substitution learns (≤4, same reading)

    func testHomophoneSubstitutionInContextLearns() {
        // 在见 → 再见: 在→再 (both zài), 见 preserved.
        let out = evaluate("在见", "再见")
        XCTAssertNil(out.rejected)
        XCTAssertTrue(out.oovCandidates.isEmpty)
        XCTAssertEqual(out.corrections.count, 1)
        let c = out.corrections[0]
        XCTAssertEqual(c.wrong, "在")
        XCTAssertEqual(c.right, "再")
        XCTAssertEqual(c.contextPinyin, ["zai"])
        XCTAssertEqual(c.keySeq, decoder.encode(tonelessSyllables: ["zai"]))
        XCTAssertFalse(c.keySeq.isEmpty)
    }

    func testSingleCharSwapSavedByExemption() {
        // 的 → 得: committed.count == 1 is EXEMPT from the reject gate (editRatio
        // would be 1.0), so the 的/得 homophone swap is still learned.
        let out = evaluate("的", "得")
        XCTAssertNil(out.rejected)
        XCTAssertEqual(out.corrections.count, 1)
        XCTAssertEqual(out.corrections[0].wrong, "的")
        XCTAssertEqual(out.corrections[0].right, "得")
        XCTAssertEqual(out.corrections[0].contextPinyin, ["de"])
        XCTAssertEqual(out.corrections[0].keySeq, decoder.encode(tonelessSyllables: ["de"]))
    }

    func testNonHomophoneSubstitutionIgnored() {
        // 天气 → 心情: same length, ≤4, but no shared reading → not a correction.
        let out = evaluate("今天天气", "今天心情")
        XCTAssertNil(out.rejected)
        XCTAssertTrue(out.corrections.isEmpty)
        XCTAssertTrue(out.oovCandidates.isEmpty)
    }

    // MARK: - Reject gate: editRatio > 0.5

    func testMajorityRewriteRejectsViaEditRatio() {
        // 6 chars, 4 changed (午未 preserved) → editRatio 4/6 ≈ 0.667 > 0.5.
        let out = evaluate("甲乙丙丁午未", "子丑寅卯午未")
        guard case .editRatio(let r)? = out.rejected else {
            return XCTFail("expected editRatio reject, got \(String(describing: out.rejected))")
        }
        XCTAssertGreaterThan(r, 0.5)
        XCTAssertTrue(out.corrections.isEmpty)
        XCTAssertTrue(out.oovCandidates.isEmpty)
    }

    func testSemanticRewriteFullyDiscarded() {
        // Total rewrite, nothing in common → editRatio 1.0 → discard, learn nothing.
        let out = evaluate("今天天气不错", "我们出去吃饭")
        guard case .editRatio? = out.rejected else {
            return XCTFail("expected editRatio reject, got \(String(describing: out.rejected))")
        }
        XCTAssertTrue(out.corrections.isEmpty)
        XCTAssertTrue(out.oovCandidates.isEmpty)
    }

    // MARK: - Reject gate: lengthDelta boundary (0.6 passes vs 0.7 rejects)

    func testLengthDelta060Passes() {
        // committed 5, final 8 → |Δ|/committed = 3/5 = 0.6, NOT > 0.6 → passes.
        // The 3-char all-Han insertion becomes a pending OOV.
        let out = evaluate("甲乙丙丁戊", "甲乙丙丁戊己庚辛")
        XCTAssertNil(out.rejected)
        XCTAssertEqual(out.oovCandidates.count, 1)
        XCTAssertEqual(out.oovCandidates[0].word, "己庚辛")
    }

    func testLengthDelta070Rejects() {
        // committed 10, final 17 → 7/10 = 0.7 > 0.6 → reject (editRatio 7/17 < 0.5).
        let out = evaluate("子丑寅卯辰巳午未申酉", "子丑寅卯辰巳午未申酉戌亥甲乙丙丁戊")
        guard case .lengthDelta(let d)? = out.rejected else {
            return XCTFail("expected lengthDelta reject, got \(String(describing: out.rejected))")
        }
        XCTAssertGreaterThan(d, 0.6)
        XCTAssertTrue(out.oovCandidates.isEmpty)
    }

    // MARK: - OOV insertion + zero-initial trap keySeq

    func testOOVInsertionTrapKeySeq() {
        // Insert 外王 after a single-char anchor → OOV word 外王, keySeq wd+wh.
        let out = evaluate("他", "他外王")
        XCTAssertNil(out.rejected)
        XCTAssertTrue(out.corrections.isEmpty)
        XCTAssertEqual(out.oovCandidates, [DiffLearner.OOVCandidate(keySeq: "wdwh", word: "外王")])
    }

    func testOOVTrapsIndividually() {
        XCTAssertEqual(evaluate("他", "他外").oovCandidates,
                       [DiffLearner.OOVCandidate(keySeq: "wd", word: "外")])   // 外 → wd
        XCTAssertEqual(evaluate("他", "他王").oovCandidates,
                       [DiffLearner.OOVCandidate(keySeq: "wh", word: "王")])   // 王 → wh
    }

    // MARK: - Privacy span cap: > 20 chars not stored

    func testInsertionOver20NotStored() {
        // 35-char anchor + 21-char insert: passes the gate (editRatio 0.375,
        // lengthDelta 0.6) but the 21-char span exceeds the ≤20 cap → dropped.
        let anchor = String(repeating: "好", count: 35)
        let out = evaluate(anchor, anchor + String(repeating: "外", count: 21))
        XCTAssertNil(out.rejected)
        XCTAssertTrue(out.oovCandidates.isEmpty)
    }

    func testInsertionExactly20Stored() {
        // The boundary the other side: a 20-char insertion is within the cap.
        let anchor = String(repeating: "好", count: 35)
        let out = evaluate(anchor, anchor + String(repeating: "外", count: 20))
        XCTAssertNil(out.rejected)
        XCTAssertEqual(out.oovCandidates.count, 1)
        XCTAssertEqual(out.oovCandidates[0].word, String(repeating: "外", count: 20))
    }

    // MARK: - Empty guards

    func testEmptyInputsRejected() {
        XCTAssertEqual(evaluate("", "你好").rejected, .emptyBase)
        XCTAssertEqual(evaluate("你好", "").rejected, .emptyFinal)
    }
}
