import XCTest
@testable import TypoFreeCore

/// M2 (DESIGN.md §2.2, MF#1) — real `LexiconBlobFormat`/`LexiconStore`
/// replacing M0's `MiniLexiconFixtureTests` hand-rolled decode. All test
/// classes are named `Lexicon*` so `swift test --filter Lexicon` catches the
/// whole milestone (mirrors M1's `Scheme*` convention).
///
/// Values below are recomputed from the real, rebuilt (post-OpenCC,
/// readings.bin-enriched) `data/lexicon.bin` — not carried over from the
/// pre-OpenCC blob DESIGN.md cites (`postings("aa")==[啊,阿,錒,嗄,锕]`), which
/// contained the Traditional character 錒. Recomputed 2026-07-18 via a
/// one-off run of `tools/build_lexicon.py`'s own resolution pipeline.
final class LexiconStoreRealBlobTests: XCTestCase {
    private let scheme = FlypyScheme.flypy

    func testPostingsAAMatchesPostOpenCCSimplifiedOrder() throws {
        let store = try LexiconStore.loadBundled(scheme: scheme)
        let postings = store.postings(forKey: "aa")

        // 錒 (Traditional, was postings[2] pre-OpenCC) converts to 锕 under
        // OpenCC t2s and its frequency merges into 锕's — so 錒 disappears
        // from the key entirely and 锕's count absorbs it.
        XCTAssertEqual(postings.map(\.word), ["啊", "阿", "锕", "嗄"])

        let expectedCounts: [(word: String, rawCount: Double)] = [
            ("啊", 84662), ("阿", 16273), ("锕", 802), ("嗄", 775),
        ]
        XCTAssertEqual(postings.count, expectedCounts.count)
        for (posting, expected) in zip(postings, expectedCounts) {
            XCTAssertEqual(posting.word, expected.word)
            XCTAssertEqual(posting.logFreq, Float(log(1.0 + expected.rawCount)), accuracy: 1e-4)
        }
    }

    func testPostingsNihcAppendixBWorkedExample() throws {
        let store = try LexiconStore.loadBundled(scheme: scheme)
        let postings = store.postings(forKey: "nihc")
        // 你好 leads; 妳好/逆号/拟号-family share the same "nihc" key by coincidence
        // of shuangpin collision, ranked strictly by rawCount descending.
        XCTAssertEqual(postings.map(\.word), ["你好", "妳好", "逆号", "拟好"])
    }

    /// The 8 counter-intuitive zero-initial trap syllables, verified end to
    /// end through a real dictionary character and the real lexicon blob
    /// (EXPLORE.md Appendix A.3 / DECISIONS.md "8 反直觉零声母陷阱").
    func test8TrapSyllableWordsResolveUnderExpectedKeys() throws {
        let store = try LexiconStore.loadBundled(scheme: scheme)
        let expectations: [(word: String, key: String)] = [
            ("歪", "wd"), ("位", "ww"), ("弯", "wj"), ("王", "wh"),
            ("腰", "yc"), ("有", "yz"), ("阳", "yh"), ("用", "ys"),
        ]
        for (word, key) in expectations {
            let postings = store.postings(forKey: key)
            XCTAssertTrue(
                postings.contains { $0.word == word },
                "expected '\(word)' among postings(forKey: '\(key)'), got \(postings.map(\.word))")
        }
    }

    func testKeyCountAndMaxSyllablesMatchRealBlob() throws {
        let store = try LexiconStore.loadBundled(scheme: scheme)
        // From tools/build_lexicon.py's post-OpenCC build report (2026-07-18):
        // "distinct flypy keys: 310654", "max key length (bytes): 38" (19 syllables).
        XCTAssertEqual(store.keyCount, 310654)
        XCTAssertEqual(store.maxSyllables, 19)
    }

    func testMissingKeyReturnsEmptyNotThrow() throws {
        let store = try LexiconStore.loadBundled(scheme: scheme)
        XCTAssertEqual(store.postings(forKey: "zzzzzzzz"), [])
    }

    /// Load-time budget regression guard (tasks.md M2: "载入时间预算"). The
    /// production blob is ~9MB of one linear `loadUnaligned` walk; on any
    /// dev machine this should be well under a second, but the bound here is
    /// deliberately generous to avoid CI flakiness while still catching a
    /// gross algorithmic regression (e.g. accidental O(n^2) parsing).
    func testLoadTimeBudget() throws {
        let start = Date()
        _ = try LexiconStore.loadBundled(scheme: scheme)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "loading+parsing the production blob took \(elapsed)s, budget is 2s")
    }
}

/// Fixture round-trip through the REAL parser (`LexiconBlobFormat.parse` /
/// `LexiconStore`), replacing M0's `MiniLexiconFixtureTests` hand-rolled
/// decode of the same `Fixtures/mini-lexicon.bin` — proves the production
/// parser produces exactly what that manual decode already validated.
final class LexiconStoreFixtureTests: XCTestCase {
    private func loadFixtureData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "mini-lexicon", withExtension: "bin", subdirectory: "Fixtures"),
            "Fixtures/mini-lexicon.bin must be embedded by SwiftPM resource copying")
        return try Data(contentsOf: url)
    }

    func testFixtureRoundTripsThroughRealParser() throws {
        let data = try loadFixtureData()
        let store = try LexiconStore(data: data, scheme: FlypyScheme.flypy)

        XCTAssertEqual(store.keyCount, 3)
        XCTAssertEqual(store.maxSyllables, 2) // "nihc" is 4 ASCII bytes -> 2 syllables

        let aa = store.postings(forKey: "aa")
        XCTAssertEqual(aa.map(\.word), ["啊", "阿"])
        XCTAssertEqual(aa[0].logFreq, Float(log(1.0 + 5000.0)), accuracy: 1e-4)
        XCTAssertEqual(aa[1].logFreq, Float(log(1.0 + 120.0)), accuracy: 1e-4)

        let hc = store.postings(forKey: "hc")
        XCTAssertEqual(hc.map(\.word), ["好"])
        XCTAssertEqual(hc[0].logFreq, Float(log(1.0 + 8000.0)), accuracy: 1e-4)

        let nihc = store.postings(forKey: "nihc")
        XCTAssertEqual(nihc.map(\.word), ["你好"])
        XCTAssertEqual(nihc[0].logFreq, Float(log(1.0 + 300.0)), accuracy: 1e-4)

        XCTAssertEqual(store.postings(forKey: "missing"), [])
    }
}

/// Byte-level `LexiconBlobFormat` error paths — hand-crafted `Data`, no
/// dependency on any bundled resource. Confirms every declared `ParseError`
/// case is a catchable `throw`, never a `loadUnaligned` trap/crash.
final class LexiconBlobFormatErrorTests: XCTestCase {
    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func validHeaderBytes(
        formatVersion: UInt16 = 1, schemeId: UInt16 = 1, keyCount: UInt32 = 0, postingCount: UInt32 = 0
    ) -> [UInt8] {
        Array("TFX1".utf8) + le16(formatVersion) + le16(schemeId) + le32(keyCount) + le32(postingCount)
    }

    func testBadMagicThrows() {
        let bytes: [UInt8] = Array("XXXX".utf8) + le16(1) + le16(1) + le32(0) + le32(0)
        XCTAssertThrowsError(try LexiconBlobFormat.parseHeader(Data(bytes), expectedSchemeId: 1)) {
            XCTAssertEqual($0 as? LexiconBlobFormat.ParseError, .badMagic)
        }
    }

    func testUnsupportedFormatVersionThrows() {
        let bytes = validHeaderBytes(formatVersion: 2)
        XCTAssertThrowsError(try LexiconBlobFormat.parseHeader(Data(bytes), expectedSchemeId: 1)) {
            XCTAssertEqual($0 as? LexiconBlobFormat.ParseError, .unsupportedFormatVersion(2))
        }
    }

    func testSchemeMismatchThrows() {
        let bytes = validHeaderBytes(schemeId: 99)
        XCTAssertThrowsError(try LexiconBlobFormat.parseHeader(Data(bytes), expectedSchemeId: 1)) {
            XCTAssertEqual($0 as? LexiconBlobFormat.ParseError, .schemeMismatch(expected: 1, found: 99))
        }
    }

    func testTruncatedHeaderThrows() {
        let bytes = Array("TFX1".utf8) + [0, 1] // 6 bytes total, header needs 16
        XCTAssertThrowsError(try LexiconBlobFormat.parseHeader(Data(bytes), expectedSchemeId: 1)) {
            XCTAssertEqual($0 as? LexiconBlobFormat.ParseError, .truncated)
        }
    }

    func testTruncatedBodyThrows() {
        // Valid 16-byte header claims 1 key; body has only the keyLen byte
        // (claims keyLen=2) with no key bytes following it.
        var bytes = validHeaderBytes(keyCount: 1, postingCount: 0)
        bytes += [2]
        XCTAssertThrowsError(try LexiconBlobFormat.parse(Data(bytes), expectedSchemeId: 1)) {
            XCTAssertEqual($0 as? LexiconBlobFormat.ParseError, .truncated)
        }
    }

    func testTruncatedMidPostingThrows() {
        // 1 key "aa", posting count claims 1, but the posting's wordLen byte
        // (3, for a 3-byte UTF-8 char) is followed by only 1 byte, not 3, and
        // no logFreq at all.
        var bytes = validHeaderBytes(keyCount: 1, postingCount: 1)
        bytes += [2] + Array("aa".utf8) // keyLen=2, "aa"
        bytes += le16(1) // postingCount=1
        bytes += [3, 0xE5] // wordLen=3 but only 1 byte follows
        XCTAssertThrowsError(try LexiconBlobFormat.parse(Data(bytes), expectedSchemeId: 1)) {
            XCTAssertEqual($0 as? LexiconBlobFormat.ParseError, .truncated)
        }
    }

    func testEmptyBlobParsesToEmptyTable() throws {
        let bytes = validHeaderBytes(keyCount: 0, postingCount: 0)
        let table = try LexiconBlobFormat.parse(Data(bytes), expectedSchemeId: 1)
        XCTAssertTrue(table.isEmpty)
    }
}
