import XCTest
@testable import TypoFreeCore

/// Note: this file intentionally never references `Bundle.module` directly —
/// `TypoFreeCoreTests` synthesizes its own `Bundle.module` (for `Fixtures/`)
/// and `@testable import TypoFreeCore` brings in that module's separate
/// `Bundle.module` too; writing the bare identifier here would be ambiguous
/// between the two. Going through `LexiconResourceCheck` (which resolves
/// `TypoFreeCore`'s own `Bundle.module` internally) sidesteps that.
final class LexiconResourceCheckTests: XCTestCase {
    func testBundledLexiconResourceLoadsRealBytesThroughSwiftPMResourceBundle() throws {
        let probe = try LexiconResourceCheck.loadBundledLexiconHeaderProbe()

        // Not hardcoding the exact byte count: M2 regenerates this file
        // (readings.bin sidecar + build-time OpenCC 繁→简), which changes it.
        // A dangling/broken resource would load 0 bytes or throw before
        // reaching this point at all.
        XCTAssertGreaterThan(probe.byteCount, 1_000_000, "lexicon.bin should be a multi-MB blob, not a stub")
        XCTAssertEqual(probe.first4, Array("TFX1".utf8), "magic must be TFX1 (DESIGN.md §2.2)")
    }
}
