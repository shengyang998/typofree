import CSQLite

/// M0 scaffold: proves the `CSQLite` system-library shim (`module.modulemap`
/// + `shim.h`, `link "sqlite3"`) actually resolves *and* links, ahead of
/// `UserDictStore` becoming the real sqlite3 consumer in M7 (DESIGN.md §2.8).
enum CSQLiteLinkCheck {
    /// The linked libsqlite3's version string, e.g. "3.45.0". Non-empty iff
    /// the system library actually linked (not just resolved at the header
    /// level).
    static func sqliteVersion() -> String {
        String(cString: sqlite3_libversion())
    }
}
