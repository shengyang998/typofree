import XCTest
@testable import TypoFreeCore

// SecureFieldGuard suite (DESIGN.md §2.7/§6, tasks.md §M6). Pure marker logic —
// zero live AX. The dynamic system-secure-input authority is injected as a
// closure (the shell wires the real Carbon call in part 2).
final class SecureFieldGuardTests: XCTestCase {

    private func markers(role: String? = nil, subrole: String? = nil,
                         roleDescription: String? = nil, title: String? = nil,
                         descriptionLabel: String? = nil) -> SecureFieldGuard.Markers {
        SecureFieldGuard.Markers(role: role, subrole: subrole,
                                 roleDescription: roleDescription, title: title,
                                 descriptionLabel: descriptionLabel)
    }

    // MARK: - The four spec'd cases

    func testAXSecureTextFieldSubroleIsSensitive() {
        XCTAssertTrue(SecureFieldGuard.isSensitiveElement(markers(subrole: "AXSecureTextField")))
    }

    func testOneTimeCodeRoleDescriptionIsSensitive() {
        XCTAssertTrue(SecureFieldGuard.isSensitiveElement(markers(roleDescription: "one-time code")))
    }

    func testOpinionIsNotSensitive() {
        XCTAssertFalse(SecureFieldGuard.isSensitiveElement(markers(roleDescription: "Opinion")))
    }

    func testPinyinIsNotSensitive() {
        XCTAssertFalse(SecureFieldGuard.isSensitiveElement(markers(roleDescription: "Pinyin")))
    }

    // MARK: - Whole-word short tokens vs substring long markers

    func testShortTokensMatchOnWholeWordOnly() {
        // Whole-word short tokens → sensitive.
        XCTAssertTrue(SecureFieldGuard.isSensitiveElement(markers(title: "Enter PIN")))
        XCTAssertTrue(SecureFieldGuard.isSensitiveElement(markers(roleDescription: "6-digit OTP")))
        XCTAssertTrue(SecureFieldGuard.isSensitiveElement(markers(roleDescription: "CVV")))
        // "pin" embedded inside a larger word must NOT match.
        XCTAssertFalse(SecureFieldGuard.isSensitiveElement(markers(title: "spinning")))
        XCTAssertFalse(SecureFieldGuard.isSensitiveElement(markers(title: "typing")))
    }

    func testLongMarkersMatchAsSubstringCaseInsensitive() {
        XCTAssertTrue(SecureFieldGuard.isSensitiveElement(markers(title: "Your Password")))
        XCTAssertTrue(SecureFieldGuard.isSensitiveElement(markers(roleDescription: "Verification Code")))
        XCTAssertFalse(SecureFieldGuard.isSensitiveElement(markers(role: "AXTextField", title: "Username")))
    }

    // MARK: - Dynamic authority OR static markers (injected closure)

    func testDynamicSystemSecureInputForcesSecure() {
        let m = markers(role: "AXTextField")   // not sensitive by markers alone
        XCTAssertTrue(SecureFieldGuard.isSecure(markers: m, isSecureEventInputEnabled: { true }))
        XCTAssertFalse(SecureFieldGuard.isSecure(markers: m, isSecureEventInputEnabled: { false }))
    }

    func testStaticMarkerSecureWithoutDynamicAuthority() {
        let m = markers(subrole: "AXSecureTextField")
        XCTAssertTrue(SecureFieldGuard.isSecure(markers: m, isSecureEventInputEnabled: { false }))
    }
}
