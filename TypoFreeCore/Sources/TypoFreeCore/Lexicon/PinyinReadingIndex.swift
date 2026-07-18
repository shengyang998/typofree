import Foundation

/// TFXR v1 multi-reading sidecar reader — DESIGN.md §2.2 (MF#2). The base
/// lexicon blob (TFX1) resolves each WORD to a single reading, and even a
/// single Han CHARACTER only carries its first `pinyin.txt` reading
/// (`build_lexicon.py`'s `load_pinyin_chars`) — for 6,992 characters with
/// more than one distinct toneless reading (8,624 counting readings that
/// differ only by tone), that first-reading-only view would make the D12
/// correction-validation gate (`CorrectionValidator`, M4) false-reject a
/// legitimate homophone swap (的/地/得-class corrections). `readings.bin`
/// fixes this: EVERY toneless reading of EVERY character in `pinyin.txt`
/// (44,435 chars), independent of the lexicon's word list or any script
/// (Simplified/Traditional) filtering.
///
/// Toneless-reading convention: readings are toneless pinyin **strings**
/// (not shuangpin keystroke codes), matching `ShuangpinDecoder.decodeSyllable`
/// output exactly — including the ü-family, which stays on the precomposed
/// scalar U+00FC ("ü") rather than collapsing to the ASCII "v" spelling used
/// internally by `build_lexicon.py`'s shuangpin *encode* tables. See
/// "readings.bin toneless convention" in `data/README.md` for the full
/// rationale; `canRead` below is written against this convention (it
/// compares `decoder.decodeSyllable(...)`'s output directly against
/// `readings(of:)`, so both sides must and do agree on "ü" vs "v").
public struct PinyinReadingIndex: Sendable {
    public enum LoadError: Error, Equatable { case resourceNotFound(String) }

    private let map: [Character: [String]]

    /// Loads `Bundle.module`'s bundled `readings.bin`.
    public static func loadBundled() throws -> PinyinReadingIndex {
        guard let url = Bundle.module.url(forResource: "readings", withExtension: "bin") else {
            throw LoadError.resourceNotFound("readings.bin")
        }
        let data = try Data(contentsOf: url)
        let map = try TFXRBlobFormat.parse(data)
        return PinyinReadingIndex(map: map)
    }

    public init(map: [Character: [String]]) {
        self.map = map
    }

    /// All known toneless readings of `ch`; empty when `ch` is unknown to
    /// `readings.bin` — callers must treat that as a conservative rejection,
    /// never as "no constraint".
    public func readings(of ch: Character) -> [String] {
        map[ch] ?? []
    }

    /// True iff, picking any one reading per character (independently —
    /// heteronyms never create cross-character combinatorial constraints in
    /// this scheme: each position's reading choice is free, so "some
    /// combination of per-char readings matches" reduces exactly to "every
    /// position has at least one matching reading"), `text` could have been
    /// typed as the shuangpin keystroke sequence `codes` — a concatenation
    /// of 2-char codes, one per character in `text`. Returns false (not a
    /// trap) when `codes.count != text.count * 2`.
    public func canRead(_ text: String, asShuangpinCodes codes: String, decoder: ShuangpinDecoder) -> Bool {
        let chars = Array(text)
        let codeChars = Array(codes)
        guard codeChars.count == chars.count * 2 else { return false }
        for (i, ch) in chars.enumerated() {
            let twoKeyCode = String(codeChars[(i * 2)..<(i * 2 + 2)])
            guard let pinyin = decoder.decodeSyllable(twoKeyCode) else { return false }
            guard readings(of: ch).contains(pinyin) else { return false }
        }
        return true
    }

    /// True iff every character in `text` is either in `punctuation` or a
    /// Han ideograph (CJK Unified Ideographs + common extension/compat
    /// blocks). Used by the D12 gate to reject non-Chinese LLM output early
    /// (e.g. a stray Latin/English response) before the per-character
    /// `canRead` walk.
    public func isAllHanzi(_ text: String, allowing punctuation: Set<Character>) -> Bool {
        text.allSatisfy { punctuation.contains($0) || Self.isHanziCharacter($0) }
    }

    private static func isHanziCharacter(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0xF900...0xFAFF,   // CJK Compatibility Ideographs
                 0x20000...0x2A6DF, // CJK Unified Ideographs Extension B
                 0x2A700...0x2EBEF, // CJK Unified Ideographs Extension C-F
                 0x2F800...0x2FA1F: // CJK Compatibility Ideographs Supplement
                return true
            default:
                return false
            }
        }
    }
}

/// TFXR v1 binary reader — private to this file, not part of the module's
/// public API (mirroring how `LexiconBlobFormat` is the only *public* blob
/// parser; TFXR is small/single-purpose enough not to need its own public
/// surface — `@testable import` still reaches it directly for unit tests).
/// Format — DESIGN.md §2.2:
///   HEADER (12B, LE): magic "TFXR"(4) | version:UInt16=1 | charCount:UInt32
///                    | reserved:UInt16
///   BODY: charCount x { charUTF8Len:UInt8 | charUTF8 | readingCount:UInt8
///                      | readingCount x { readingLen:UInt8 | readingUTF8 } }
/// Same bounds-checked-before-`loadUnaligned` discipline as
/// `LexiconBlobFormat` — `.truncated` must be a catchable `throw`, not a trap.
enum TFXRBlobFormat {
    static let magic: [UInt8] = Array("TFXR".utf8)
    static let supportedFormatVersion: UInt16 = 1
    static let headerSize = 12

    enum ParseError: Error, Equatable {
        case badMagic
        case unsupportedFormatVersion(UInt16)
        case truncated
    }

    static func parse(_ data: Data) throws -> [Character: [String]] {
        guard data.count >= headerSize else { throw ParseError.truncated }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Character: [String]] in
            let base = raw.baseAddress!
            let magicBytes = (0..<4).map { base.loadUnaligned(fromByteOffset: $0, as: UInt8.self) }
            guard magicBytes.elementsEqual(magic) else { throw ParseError.badMagic }
            let formatVersion = base.loadUnaligned(fromByteOffset: 4, as: UInt16.self)
            guard formatVersion == supportedFormatVersion else {
                throw ParseError.unsupportedFormatVersion(formatVersion)
            }
            let charCount = Int(base.loadUnaligned(fromByteOffset: 6, as: UInt32.self))
            // bytes 10..<12 are `reserved`, intentionally unread.

            let total = data.count
            var offset = headerSize
            func need(_ n: Int) throws {
                guard offset + n <= total else { throw ParseError.truncated }
            }

            var result: [Character: [String]] = [:]
            result.reserveCapacity(charCount)
            for _ in 0..<charCount {
                try need(1)
                let charLen = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                offset += 1
                guard charLen > 0 else { throw ParseError.truncated }
                try need(charLen)
                let charString = String(
                    decoding: UnsafeRawBufferPointer(start: base + offset, count: charLen),
                    as: UTF8.self)
                offset += charLen
                guard let ch = charString.first else { throw ParseError.truncated }

                try need(1)
                let readingCount = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                offset += 1

                var readings: [String] = []
                readings.reserveCapacity(readingCount)
                for _ in 0..<readingCount {
                    try need(1)
                    let readingLen = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                    offset += 1
                    try need(readingLen)
                    let reading = String(
                        decoding: UnsafeRawBufferPointer(start: base + offset, count: readingLen),
                        as: UTF8.self)
                    offset += readingLen
                    readings.append(reading)
                }
                result[ch] = readings
            }
            return result
        }
    }
}
