import XCTest
@testable import TypoFreeCore

/// M2 (DESIGN.md §2.2, MF#2) — `PinyinReadingIndex` / TFXR `readings.bin`.
/// All test classes are named `Lexicon*` so `swift test --filter Lexicon`
/// catches the whole milestone alongside `LexiconStoreTests.swift`.
///
/// Reading lists below are recomputed 2026-07-18 from the real, rebuilt
/// `data/readings.bin` (via `tools/build_lexicon.py`'s own
/// `build_readings_map`) — not guessed.
final class LexiconReadingIndexRealDataTests: XCTestCase {
    private let decoder = ShuangpinDecoder(scheme: FlypyScheme.flypy)

    func testHeteronymReadingsMatchRealPinyinTxt() throws {
        let index = try PinyinReadingIndex.loadBundled()
        // 行: xíng/háng/héng/xìng/hàng -> toneless dedup [xing, hang, heng].
        // tasks.md M2 cites exactly this character: "行→[xk,hh]" (the
        // shuangpin codes for xing/hang, exercised in canRead below).
        XCTAssertEqual(index.readings(of: "行"), ["xing", "hang", "heng"])
        // 得: dé/de/děi -> toneless dedup [de, dei] — matches tasks.md's
        // "得→[de,dei]" example verbatim.
        XCTAssertEqual(index.readings(of: "得"), ["de", "dei"])
        // 女: nǚ/nǜ/rǔ -> toneless dedup [nü, ru]. Keeps the precomposed
        // U+00FC "ü" (not ASCII "v") — the sharp edge M1's handoff flagged:
        // ShuangpinDecoder.decodeSyllable("nv") returns "nü", not "nv".
        XCTAssertEqual(index.readings(of: "女"), ["nü", "ru"])
    }

    func testUnknownCharacterReturnsEmptyReadings() throws {
        let index = try PinyinReadingIndex.loadBundled()
        XCTAssertEqual(index.readings(of: "🎉"), [], "unknown char = conservative rejection, per DESIGN.md §2.2")
    }

    func testHangReadingsBothCodesFromTasksMdExample() throws {
        let index = try PinyinReadingIndex.loadBundled()
        // tasks.md M2: "readings.bin 多音字覆盖(行→[xk,hh]...)".
        XCTAssertTrue(index.canRead("行", asShuangpinCodes: "xk", decoder: decoder), "xk decodes to xing")
        XCTAssertTrue(index.canRead("行", asShuangpinCodes: "hh", decoder: decoder), "hh decodes to hang")
    }

    /// The ü/v reconciliation flagged by M1's handoff, exercised end to end:
    /// `readings.bin` must store "nü" (U+00FC) to match what
    /// `ShuangpinDecoder.decodeSyllable` actually produces for the "nv" key
    /// sequence — a readings.bin built with the ASCII "v" convention
    /// (`strip_tone`, used internally by the shuangpin *encode* tables) would
    /// never match and every nü/lü/nüe/lüe correction would false-reject.
    func testNuCanReadUmlautCodeNotAsciiVSpelling() throws {
        let index = try PinyinReadingIndex.loadBundled()
        XCTAssertTrue(index.canRead("女", asShuangpinCodes: "nv", decoder: decoder),
            "'nv' keys decode to pinyin 'nü' (precomposed U+00FC), one of 女's readings")
        XCTAssertTrue(index.canRead("女", asShuangpinCodes: "ru", decoder: decoder))
        // "nu" (n+u keys) decodes to the *different*, legal toneless syllable
        // "nu" (as in 努/奴), which is NOT one of 女's readings (["nü","ru"]) —
        // must be rejected. Proves the ü/v reconciliation isn't accidentally
        // permissive (i.e. it isn't silently treating "nu" and "nü" as equal).
        XCTAssertFalse(index.canRead("女", asShuangpinCodes: "nu", decoder: decoder))
    }

    func testCanReadRejectsWrongCodeLength() throws {
        let index = try PinyinReadingIndex.loadBundled()
        XCTAssertFalse(index.canRead("你好", asShuangpinCodes: "nihcxx", decoder: decoder), "3 codes for 2 chars")
        XCTAssertFalse(index.canRead("你好", asShuangpinCodes: "ni", decoder: decoder), "half a code for 2 chars")
        XCTAssertFalse(index.canRead("", asShuangpinCodes: "ni", decoder: decoder), "codes present for empty text")
    }

    func testCanReadRejectsSchemeLegalButSemanticallyWrongCode() throws {
        let index = try PinyinReadingIndex.loadBundled()
        // "zk" decodes to a real (non-word) syllable "zuai" (FlypyScheme's
        // documented non-word decode leniency — see its header comment) that
        // is not among 行's readings, so this must still be false.
        XCTAssertFalse(index.canRead("行", asShuangpinCodes: "zk", decoder: decoder))
    }

    func testIsAllHanzi() throws {
        let index = try PinyinReadingIndex.loadBundled()
        XCTAssertTrue(index.isAllHanzi("你好", allowing: []))
        XCTAssertTrue(index.isAllHanzi("你好，世界", allowing: ["，"]))
        XCTAssertFalse(index.isAllHanzi("你好，世界", allowing: []), "punctuation not in the allow-set must reject")
        XCTAssertFalse(index.isAllHanzi("hello", allowing: []))
        XCTAssertFalse(index.isAllHanzi("你hello", allowing: []), "mixed script must reject")
        XCTAssertTrue(index.isAllHanzi("", allowing: []), "vacuously true — emptiness is a separate, prior D12 check")
    }
}

/// Controlled `init(map:)` logic tests, independent of real `readings.bin`
/// content — exercises `canRead`'s documented "任一读音" (any one reading per
/// character, no cross-character combinatorial constraint) contract with
/// synthetic heteronym data. Codes are derived via the real
/// `ShuangpinDecoder.encode(syllable:)` rather than hand-computed, so this
/// stays correct-by-construction if the scheme tables ever change.
final class LexiconReadingIndexLogicTests: XCTestCase {
    private let decoder = ShuangpinDecoder(scheme: FlypyScheme.flypy)

    func testCanReadPicksIndependentReadingPerCharacter() throws {
        let index = PinyinReadingIndex(map: [
            "甲": ["jia", "xia"],
            "乙": ["yi", "yin"],
        ])
        let jiaCode = try XCTUnwrap(decoder.encode(syllable: "jia"))
        let xiaCode = try XCTUnwrap(decoder.encode(syllable: "xia"))
        let yiCode = try XCTUnwrap(decoder.encode(syllable: "yi"))
        let yinCode = try XCTUnwrap(decoder.encode(syllable: "yin"))
        let wrongCode = try XCTUnwrap(decoder.encode(syllable: "zuo")) // neither jia nor xia

        // DESIGN.md §2.2: "处理多音字: 只要存在一组读音组合匹配即真" — each
        // character's reading choice is independent; both combinations below
        // must succeed.
        XCTAssertTrue(index.canRead("甲乙", asShuangpinCodes: jiaCode + yinCode, decoder: decoder))
        XCTAssertTrue(index.canRead("甲乙", asShuangpinCodes: xiaCode + yiCode, decoder: decoder))
        // Neither of 甲's readings matches `wrongCode` — must fail regardless
        // of what 乙's code is.
        XCTAssertFalse(index.canRead("甲乙", asShuangpinCodes: wrongCode + yiCode, decoder: decoder))
    }

    func testUnknownCharacterMeansConservativeRejection() {
        let index = PinyinReadingIndex(map: [:])
        XCTAssertEqual(index.readings(of: "甲"), [])
        XCTAssertFalse(index.canRead("甲", asShuangpinCodes: "jx", decoder: decoder))
    }
}

/// Byte-level TFXR error paths — hand-crafted `Data`, no dependency on any
/// bundled resource. Same discipline as `LexiconBlobFormatErrorTests`: every
/// declared `ParseError` case must be a catchable `throw`, never a
/// `loadUnaligned` trap/crash.
final class LexiconReadingsBlobFormatErrorTests: XCTestCase {
    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func validHeaderBytes(version: UInt16 = 1, charCount: UInt32 = 0) -> [UInt8] {
        Array("TFXR".utf8) + le16(version) + le32(charCount) + le16(0)
    }

    func testBadMagicThrows() {
        let bytes: [UInt8] = Array("XXXX".utf8) + le16(1) + le32(0) + le16(0)
        XCTAssertThrowsError(try TFXRBlobFormat.parse(Data(bytes))) {
            XCTAssertEqual($0 as? TFXRBlobFormat.ParseError, .badMagic)
        }
    }

    func testUnsupportedFormatVersionThrows() {
        let bytes = validHeaderBytes(version: 2)
        XCTAssertThrowsError(try TFXRBlobFormat.parse(Data(bytes))) {
            XCTAssertEqual($0 as? TFXRBlobFormat.ParseError, .unsupportedFormatVersion(2))
        }
    }

    func testTruncatedHeaderThrows() {
        let bytes = Array("TFXR".utf8) + [1, 0] // 6 bytes total, header needs 12
        XCTAssertThrowsError(try TFXRBlobFormat.parse(Data(bytes))) {
            XCTAssertEqual($0 as? TFXRBlobFormat.ParseError, .truncated)
        }
    }

    func testTruncatedBodyThrows() {
        var bytes = validHeaderBytes(charCount: 1)
        bytes += [3] // charUTF8Len=3, but no char bytes follow
        XCTAssertThrowsError(try TFXRBlobFormat.parse(Data(bytes))) {
            XCTAssertEqual($0 as? TFXRBlobFormat.ParseError, .truncated)
        }
    }

    func testTruncatedMidReadingThrows() {
        var bytes = validHeaderBytes(charCount: 1)
        let charBytes = Array("行".utf8)
        bytes += [UInt8(charBytes.count)] + charBytes
        bytes += [1] // readingCount=1
        bytes += [4, 0x78, 0x69] // readingLen=4 but only 2 bytes follow
        XCTAssertThrowsError(try TFXRBlobFormat.parse(Data(bytes))) {
            XCTAssertEqual($0 as? TFXRBlobFormat.ParseError, .truncated)
        }
    }

    func testEmptyBlobParsesToEmptyMap() throws {
        let bytes = validHeaderBytes(charCount: 0)
        let map = try TFXRBlobFormat.parse(Data(bytes))
        XCTAssertTrue(map.isEmpty)
    }

    func testRoundTripsHandwrittenBlob() throws {
        var bytes = validHeaderBytes(charCount: 1)
        let charBytes = Array("行".utf8)
        bytes += [UInt8(charBytes.count)] + charBytes
        bytes += [2] // readingCount
        for reading in ["xing", "hang"] {
            let rb = Array(reading.utf8)
            bytes += [UInt8(rb.count)] + rb
        }
        let map = try TFXRBlobFormat.parse(Data(bytes))
        XCTAssertEqual(map["行"], ["xing", "hang"])
    }
}
