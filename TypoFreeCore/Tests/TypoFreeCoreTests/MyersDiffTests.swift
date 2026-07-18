import XCTest
@testable import TypoFreeCore

// MyersDiff basics (DESIGN.md §2.7). Char-level shortest edit script, grouped
// into equal/insert/delete runs; deterministic. A substitution surfaces as an
// adjacent delete-run / insert-run pair (delete-then-insert with this greedy
// tie-break), which is exactly what `DiffLearner` pairs up.
final class MyersDiffTests: XCTestCase {

    private func diff(_ a: String, _ b: String) -> [MyersDiff.Operation] {
        MyersDiff.diff(a, b)
    }

    func testIdenticalInputsAreOneEqualRun() {
        XCTAssertEqual(diff("abc", "abc"), [.equal(["a", "b", "c"])])
    }

    func testPureInsertion() {
        XCTAssertEqual(diff("", "abc"), [.insert(["a", "b", "c"])])
        XCTAssertEqual(diff("ac", "abc"), [.equal(["a"]), .insert(["b"]), .equal(["c"])])
    }

    func testPureDeletion() {
        XCTAssertEqual(diff("abc", ""), [.delete(["a", "b", "c"])])
        XCTAssertEqual(diff("abc", "ac"), [.equal(["a"]), .delete(["b"]), .equal(["c"])])
    }

    func testSingleCharSubstitutionIsDeleteThenInsert() {
        // 的 → 得: no common char, so delete-run then insert-run.
        XCTAssertEqual(diff("的", "得"), [.delete(["的"]), .insert(["得"])])
    }

    func testSubstitutionWithTrailingEqualContext() {
        // 在见 → 再见: 在→再 substitution, 见 preserved.
        XCTAssertEqual(diff("在见", "再见"),
                       [.delete(["在"]), .insert(["再"]), .equal(["见"])])
    }

    func testTwoSeparatedSubstitutions() {
        // abc → xby: a→x, b equal, c→y — two substitutions split by an equal run.
        XCTAssertEqual(diff("abc", "xby"),
                       [.delete(["a"]), .insert(["x"]), .equal(["b"]),
                        .delete(["c"]), .insert(["y"])])
    }

    func testUnequalLengthSubstitutionGroupsAsOneDeleteOneInsert() {
        // ab → xyz with no common char: whole delete run + whole insert run.
        XCTAssertEqual(diff("ab", "xyz"), [.delete(["a", "b"]), .insert(["x", "y", "z"])])
    }

    func testDeterministicAcrossRuns() {
        // Same inputs → byte-identical output (the learning loop must be reproducible).
        XCTAssertEqual(diff("你好世界", "你号世界"), diff("你好世界", "你号世界"))
        XCTAssertEqual(diff("你好世界", "你号世界"),
                       [.equal(["你"]), .delete(["好"]), .insert(["号"]), .equal(["世", "界"])])
    }
}
