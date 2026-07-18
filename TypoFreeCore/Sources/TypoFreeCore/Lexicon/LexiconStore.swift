import Foundation

/// In-memory base lexicon. Loads a TFX1 blob once (bundled production blob,
/// or an arbitrary `Data` for tests/fixtures) and serves `postings(forKey:)`
/// lookups. DESIGN.md §2.2.
///
/// Immutable after construction — `final class` + all-`let` storage makes
/// `Sendable` conformance checkable by the compiler, not `@unchecked`.
public final class LexiconStore: Sendable {
    public enum LoadError: Error, Equatable { case resourceNotFound(String) }

    private let table: [String: [LexiconPosting]]

    /// Number of distinct shuangpin keys in the loaded blob.
    public let keyCount: Int
    /// Longest key's syllable count (`keyLen / 2`); every key is an even
    /// number of ASCII bytes — one 2-char shuangpin code per syllable.
    public let maxSyllables: Int

    /// Loads `Bundle.module`'s bundled `lexicon.bin` (the real, compiled
    /// production blob — `data/lexicon.bin` / `tools/build_lexicon.py`).
    public static func loadBundled(scheme: SchemeDefinition) throws -> LexiconStore {
        guard let url = Bundle.module.url(forResource: "lexicon", withExtension: "bin") else {
            throw LoadError.resourceNotFound("lexicon.bin")
        }
        let data = try Data(contentsOf: url)
        return try LexiconStore(data: data, scheme: scheme)
    }

    /// Test/fixture entry point: parse an arbitrary TFX1 `Data` blob.
    public init(data: Data, scheme: SchemeDefinition) throws {
        table = try LexiconBlobFormat.parse(data, expectedSchemeId: scheme.schemeId)
        keyCount = table.count
        maxSyllables = table.keys.map { $0.count / 2 }.max() ?? 0
    }

    /// Base-lexicon postings for `key`, already in on-disk order (descending
    /// rawCount). Empty when the key has no entries — never throws.
    public func postings(forKey key: String) -> [LexiconPosting] {
        table[key] ?? []
    }
}
