import XCTest
import TypoFreeCore

/// M0 scaffold test for the placeholder `NullProvider` (see that file's doc
/// comment). M4 replaces both the type and this test with the full
/// `LLMCorrectionProvider` conformance + D12-gate + coordinator suite
/// (tasks.md §M4, MF#3).
final class NullProviderPlaceholderTests: XCTestCase {
    func testAlwaysDeclines() async {
        let provider = NullProvider()
        let result = await provider.correct()
        XCTAssertNil(result, "NullProvider must decline (nil), never fabricate text")
    }
}
