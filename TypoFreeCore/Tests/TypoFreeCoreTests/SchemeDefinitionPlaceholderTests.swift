import XCTest
import TypoFreeCore

/// M0 scaffold test for the placeholder `SchemeDefinition` (see that file's
/// doc comment). M1 replaces both the type and this test with the real
/// Appendix-A-backed `FlypyScheme.flypy` + the 8-trap/regular-control suite
/// (tasks.md §M1).
final class SchemeDefinitionPlaceholderTests: XCTestCase {
    func testConstructsAndCarriesTFX1SchemeId() {
        let scheme = SchemeDefinition(schemeId: 1, displayName: "小鹤双拼")
        XCTAssertEqual(scheme.schemeId, 1, "must match the TFX1 lexicon header's schemeId")
        XCTAssertEqual(scheme.displayName, "小鹤双拼")
    }

    func testEquatable() {
        let a = SchemeDefinition(schemeId: 1, displayName: "小鹤双拼")
        let b = SchemeDefinition(schemeId: 1, displayName: "小鹤双拼")
        let c = SchemeDefinition(schemeId: 2, displayName: "other")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
