import XCTest
@testable import TypoFreeCore

/// M0 scaffold: exercises `CSQLiteLinkCheck` (internal) via `@testable
/// import`, proving the `CSQLite` system-library target actually links
/// `libsqlite3`, not just that the module map parses.
final class CSQLiteLinkTests: XCTestCase {
    func testSQLite3LinksAndReportsAVersion() {
        let version = CSQLiteLinkCheck.sqliteVersion()
        XCTAssertFalse(version.isEmpty)
        // Sanity: looks like a dotted version number, e.g. "3.45.0".
        XCTAssertTrue(version.contains("."), "unexpected sqlite3_libversion() output: \(version)")
    }
}
