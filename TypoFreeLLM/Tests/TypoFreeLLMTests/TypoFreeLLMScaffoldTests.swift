import XCTest
import TypoFreeLLM

/// M0 scaffold test. M4 (tasks.md §M4) adds the real `LLMBackendResolverTests`
/// (fake two-branch, zero network) and `MLXModelManagerLiveTests` (gated on
/// `TYPOFREE_MLX_LIVE_TEST=1`) alongside this file.
final class TypoFreeLLMScaffoldTests: XCTestCase {
    func testScaffoldSummaryMentionsCoreSchemeId() {
        XCTAssertEqual(TypoFreeLLMScaffold.scaffoldSummary(), "TypoFreeLLM scaffold OK (Core schemeId=1)")
    }
}
