import XCTest
@testable import TypoFreeCore

// Context-capture decision suite (DESIGN.md §2.7/§6, tasks.md §M6): the
// bundle-id denylist, suppression-reason priority, and source-tier resolution —
// all pure, zero live AX.
final class ContextCaptureTests: XCTestCase {

    // MARK: - Denylist (Terminal / iTerm2 defaults)

    func testDefaultDenylistCoversTerminals() {
        XCTAssertTrue(CaptureDenylist.contains("com.apple.Terminal"))
        XCTAssertTrue(CaptureDenylist.contains("com.googlecode.iterm2"))
    }

    func testNonDenylistedAppsPass() {
        XCTAssertFalse(CaptureDenylist.contains("com.apple.Safari"))
        XCTAssertFalse(CaptureDenylist.contains("com.apple.MobileSMS"))
        XCTAssertFalse(CaptureDenylist.contains(nil))          // no bundle id → not denylisted
    }

    func testUserExtendedDenylist() {
        let extended = CaptureDenylist.defaults.union(["com.example.secret"])
        XCTAssertTrue(CaptureDenylist.contains("com.example.secret", denylist: extended))
        XCTAssertFalse(CaptureDenylist.contains("com.example.secret"))   // not in defaults
    }

    // MARK: - Suppression-reason priority

    func testDenylistWinsOverEverything() {
        let r = ContextSnapshot.resolveSuppression(
            bundleId: "com.apple.Terminal", isSystemSecureInputActive: true,
            isSecureField: true, hasSource: true)
        XCTAssertEqual(r, .denylisted)
    }

    func testSystemSecureThenSecureFieldThenNoSourceThenNone() {
        XCTAssertEqual(ContextSnapshot.resolveSuppression(
            bundleId: "com.apple.Safari", isSystemSecureInputActive: true,
            isSecureField: false, hasSource: true), .systemSecureInput)
        XCTAssertEqual(ContextSnapshot.resolveSuppression(
            bundleId: "com.apple.Safari", isSystemSecureInputActive: false,
            isSecureField: true, hasSource: true), .secureField)
        XCTAssertEqual(ContextSnapshot.resolveSuppression(
            bundleId: "com.apple.Safari", isSystemSecureInputActive: false,
            isSecureField: false, hasSource: false), .noSourceAvailable)
        XCTAssertEqual(ContextSnapshot.resolveSuppression(
            bundleId: "com.apple.Safari", isSystemSecureInputActive: false,
            isSecureField: false, hasSource: true), CaptureSuppressionReason.none)
    }

    func testPrivacySuppressionDiscardsLearning() {
        XCTAssertTrue(CaptureSuppressionReason.denylisted.isPrivacySuppression)
        XCTAssertTrue(CaptureSuppressionReason.systemSecureInput.isPrivacySuppression)
        XCTAssertTrue(CaptureSuppressionReason.secureField.isPrivacySuppression)
        XCTAssertFalse(CaptureSuppressionReason.noSourceAvailable.isPrivacySuppression)
        XCTAssertFalse(CaptureSuppressionReason.none.isPrivacySuppression)

        let secure = ContextSnapshot(before: "", after: "", suppressionReason: .secureField)
        XCTAssertTrue(secure.suppressesLearning)
        let ok = ContextSnapshot(before: "上文", after: "")
        XCTAssertFalse(ok.suppressesLearning)
    }

    // MARK: - Source-tier resolution (IMKTextInput → AX → sentence-only)

    func testTierResolution() {
        XCTAssertEqual(
            ContextSourceTier.resolve(accessibilityAvailable: true, imkTextInputAvailable: true),
            .accessibility)
        XCTAssertEqual(
            ContextSourceTier.resolve(accessibilityAvailable: false, imkTextInputAvailable: true),
            .imkTextInput)
        XCTAssertEqual(
            ContextSourceTier.resolve(accessibilityAvailable: false, imkTextInputAvailable: false),
            .sentenceOnly)
    }
}
