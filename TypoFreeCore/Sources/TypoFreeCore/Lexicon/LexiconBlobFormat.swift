import Foundation

/// TFX1 binary lexicon blob reader — DESIGN.md §2.2 (MF#1: TFX1 is the
/// **only** supported format; the earlier `TFLX` design draft was deleted).
///
/// Layout: 16-byte header, then `keyCount` records of
/// `[keyLen:UInt8][keyBytes][postingCount:UInt16]`, each followed by
/// `postingCount` records of `[wordLen:UInt8][wordBytes][logFreq:Float32]`,
/// all little-endian. Keys are strictly ascending ASCII a-z.
/// `tools/build_lexicon.py` is the byte-exact writer (see its module
/// docstring for the canonical format spec this mirrors).
///
/// Every multi-byte field is read via `loadUnaligned(fromByteOffset:as:)`:
/// variable-length key/word runs break natural alignment for everything
/// after them, so a plain `load` would trap. Every offset is bounds-checked
/// against `data.count` **before** the corresponding `loadUnaligned` call —
/// the raw-pointer API itself does not bounds-check (it traps/crashes on an
/// out-of-range read), and `.truncated` must be a catchable `throw`, never a
/// process crash.
public enum LexiconBlobFormat {
    public static let magic: [UInt8] = Array("TFX1".utf8)
    public static let supportedFormatVersion: UInt16 = 1
    static let headerSize = 16

    public enum ParseError: Error, Equatable {
        case badMagic
        case unsupportedFormatVersion(UInt16)
        case schemeMismatch(expected: UInt16, found: UInt16)
        case truncated
    }

    public struct Header: Sendable, Equatable {
        public let formatVersion: UInt16
        public let schemeId: UInt16
        public let keyCount: UInt32
        public let postingCount: UInt32
    }

    /// Validates + reads just the 16-byte header (magic, format version,
    /// scheme, counts). Cheap — does not walk the body.
    public static func parseHeader(_ data: Data, expectedSchemeId: UInt16) throws -> Header {
        guard data.count >= headerSize else { throw ParseError.truncated }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Header in
            let base = raw.baseAddress!
            let magicBytes = (0..<4).map { base.loadUnaligned(fromByteOffset: $0, as: UInt8.self) }
            guard magicBytes.elementsEqual(magic) else { throw ParseError.badMagic }
            let formatVersion = base.loadUnaligned(fromByteOffset: 4, as: UInt16.self)
            guard formatVersion == supportedFormatVersion else {
                throw ParseError.unsupportedFormatVersion(formatVersion)
            }
            let schemeId = base.loadUnaligned(fromByteOffset: 6, as: UInt16.self)
            guard schemeId == expectedSchemeId else {
                throw ParseError.schemeMismatch(expected: expectedSchemeId, found: schemeId)
            }
            let keyCount = base.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            let postingCount = base.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            return Header(formatVersion: formatVersion, schemeId: schemeId,
                          keyCount: keyCount, postingCount: postingCount)
        }
    }

    /// Full body walk: header + every key's posting list. `expectedSchemeId`
    /// must match `SchemeDefinition.schemeId` (flypy = 1) — a blob built for
    /// a different scheme is rejected rather than silently misread.
    public static func parse(_ data: Data, expectedSchemeId: UInt16) throws -> [String: [LexiconPosting]] {
        let header = try parseHeader(data, expectedSchemeId: expectedSchemeId)
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [String: [LexiconPosting]] in
            let base = raw.baseAddress!
            let total = data.count
            var offset = headerSize
            func need(_ n: Int) throws {
                guard offset + n <= total else { throw ParseError.truncated }
            }

            var result: [String: [LexiconPosting]] = [:]
            result.reserveCapacity(Int(header.keyCount))

            for _ in 0..<header.keyCount {
                try need(1)
                let keyLen = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                offset += 1
                try need(keyLen)
                let key = String(
                    decoding: UnsafeRawBufferPointer(start: base + offset, count: keyLen),
                    as: UTF8.self)
                offset += keyLen

                try need(2)
                let postingCount = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                offset += 2

                var postings: [LexiconPosting] = []
                postings.reserveCapacity(postingCount)
                for _ in 0..<postingCount {
                    try need(1)
                    let wordLen = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                    offset += 1
                    try need(wordLen)
                    let word = String(
                        decoding: UnsafeRawBufferPointer(start: base + offset, count: wordLen),
                        as: UTF8.self)
                    offset += wordLen

                    try need(4)
                    let bits = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                    offset += 4

                    postings.append(LexiconPosting(word: word, logFreq: Float(bitPattern: bits)))
                }
                result[key] = postings
            }
            return result
        }
    }
}
