import XCTest

/// M0 scaffold: proves `Fixtures/mini-lexicon.bin` (a hand-written TFX1 blob,
/// see `tools/make_mini_lexicon_fixture.py`) is embedded by SwiftPM's test
/// resource copying and is byte-decodable end to end — i.e. this is a real
/// decode of real bytes, not a hardcoded assertion.
///
/// The parser below is deliberately private to this test file, not part of
/// the public `TypoFreeCore` API: M2 (DESIGN.md §2.2, MF#1) replaces it with
/// the real, header-validating, error-throwing
/// `LexiconBlobFormat.parse(_:expectedSchemeId:)` + `LexiconStore`.
final class MiniLexiconFixtureTests: XCTestCase {
    private struct DecodedEntry: Equatable {
        let word: String
        let logFreq: Float
    }

    private struct DecodedBlob {
        let formatVersion: UInt16
        let schemeId: UInt16
        let keyCount: UInt32
        let postingCount: UInt32
        let byKey: [String: [DecodedEntry]]
        let keyOrder: [String]
    }

    private func loadFixtureData() throws -> Data {
        // `.copy("Fixtures")` preserves the directory in the resource bundle,
        // so the file lands at "Fixtures/mini-lexicon.bin", not the bundle root.
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "mini-lexicon", withExtension: "bin", subdirectory: "Fixtures"),
            "Fixtures/mini-lexicon.bin must be embedded by SwiftPM resource copying"
        )
        return try Data(contentsOf: url)
    }

    /// Hand-rolled TFX1 walk mirroring DESIGN.md §2.2's byte layout:
    /// `HEADER(16B) | keyCount x { keyLen:UInt8 | keyBytes | postingCount:UInt16
    /// | postingCount x { wordLen:UInt8 | wordBytes | logFreq:Float32 } }`.
    /// Every multi-byte field goes through `loadUnaligned`, since variable-length
    /// key/word runs break natural alignment for everything after them
    /// (DESIGN.md §2.2's explicit warning: plain `load` would trap).
    private func decode(_ data: Data) -> DecodedBlob {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> DecodedBlob in
            let base = raw.baseAddress!
            func u8(_ offset: Int) -> UInt8 { base.loadUnaligned(fromByteOffset: offset, as: UInt8.self) }
            func u16(_ offset: Int) -> UInt16 { base.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
            func u32(_ offset: Int) -> UInt32 { base.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            func f32(_ offset: Int) -> Float { Float(bitPattern: u32(offset)) }

            let magicBytes = (0..<4).map { u8($0) }
            XCTAssertEqual(magicBytes, Array("TFX1".utf8), "bad magic")

            let formatVersion = u16(4)
            let schemeId = u16(6)
            let keyCount = u32(8)
            let postingCount = u32(12)

            var offset = 16
            var byKey: [String: [DecodedEntry]] = [:]
            var keyOrder: [String] = []
            for _ in 0..<keyCount {
                let keyLen = Int(u8(offset)); offset += 1
                let keyBytes = (0..<keyLen).map { u8(offset + $0) }
                offset += keyLen
                let key = String(decoding: keyBytes, as: UTF8.self)

                let postings = Int(u16(offset)); offset += 2
                var entries: [DecodedEntry] = []
                entries.reserveCapacity(postings)
                for _ in 0..<postings {
                    let wordLen = Int(u8(offset)); offset += 1
                    let wordBytes = (0..<wordLen).map { u8(offset + $0) }
                    offset += wordLen
                    let word = String(decoding: wordBytes, as: UTF8.self)
                    let logFreq = f32(offset); offset += 4
                    entries.append(DecodedEntry(word: word, logFreq: logFreq))
                }
                byKey[key] = entries
                keyOrder.append(key)
            }
            XCTAssertEqual(offset, data.count, "trailing/short bytes after walking every record")

            return DecodedBlob(
                formatVersion: formatVersion, schemeId: schemeId,
                keyCount: keyCount, postingCount: postingCount,
                byKey: byKey, keyOrder: keyOrder
            )
        }
    }

    func testRealByteDecodeOfHandwrittenFixture() throws {
        let blob = decode(try loadFixtureData())

        XCTAssertEqual(blob.formatVersion, 1)
        XCTAssertEqual(blob.schemeId, 1, "must match flypy's TFX1 schemeId")
        XCTAssertEqual(blob.keyCount, 3)
        XCTAssertEqual(blob.postingCount, 4)

        // "aa": postings sorted by descending rawCount (5000, 120) per
        // DESIGN.md §2.2's posting-order convention.
        XCTAssertEqual(blob.byKey["aa"]?.map(\.word), ["啊", "阿"])
        XCTAssertEqual(blob.byKey["aa"]?[0].logFreq ?? 0, Float(log(1.0 + 5000.0)), accuracy: 1e-4)
        XCTAssertEqual(blob.byKey["aa"]?[1].logFreq ?? 0, Float(log(1.0 + 120.0)), accuracy: 1e-4)

        XCTAssertEqual(blob.byKey["hc"]?.map(\.word), ["好"])
        XCTAssertEqual(blob.byKey["hc"]?[0].logFreq ?? 0, Float(log(1.0 + 8000.0)), accuracy: 1e-4)

        XCTAssertEqual(blob.byKey["nihc"]?.map(\.word), ["你好"])
        XCTAssertEqual(blob.byKey["nihc"]?[0].logFreq ?? 0, Float(log(1.0 + 300.0)), accuracy: 1e-4)
    }

    func testKeysAreStrictlyAscendingByteOrder() throws {
        let blob = decode(try loadFixtureData())
        // DESIGN.md §2.2 requires the real blob's keys to be strictly
        // ascending; the fixture generator honors that too, so on-disk
        // order should already equal the sorted order.
        XCTAssertEqual(blob.keyOrder, blob.keyOrder.sorted())
        XCTAssertEqual(blob.keyOrder, ["aa", "hc", "nihc"])
    }
}
