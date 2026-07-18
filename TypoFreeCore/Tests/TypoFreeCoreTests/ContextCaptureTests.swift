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

    // MARK: - Commit-snapshot assembly (the ladder's pure decision, M6 part 2)

    private let sig = FieldSignature(bundleId: "com.apple.TextEdit", pid: 42,
                                     role: "AXTextArea", subrole: nil,
                                     roundedFrame: RoundedFrame(x: 0, y: 0, width: 100, height: 20))

    func testAssembleAXPathKeepsContextAndSignature() {
        let snap = ContextSnapshot.assemble(
            bundleId: "com.apple.TextEdit", axPrecedingText: "你好世界",
            imkPrecedingText: "", fieldSignature: sig,
            isSystemSecureInputActive: false, isSecureField: false, maxChars: 20)
        XCTAssertEqual(snap.before, "你好世界")
        XCTAssertEqual(snap.sourceTier, .accessibility)
        XCTAssertEqual(snap.suppressionReason, .none)
        XCTAssertEqual(snap.fieldSignature, sig)
        XCTAssertFalse(snap.suppressesLearning)
    }

    func testAssembleFallsBackToIMKWhenAXAbsent() {
        let snap = ContextSnapshot.assemble(
            bundleId: "com.apple.Safari", axPrecedingText: nil,
            imkPrecedingText: "hello", fieldSignature: nil,
            isSystemSecureInputActive: false, isSecureField: false, maxChars: 20)
        XCTAssertEqual(snap.before, "hello")
        XCTAssertEqual(snap.sourceTier, .imkTextInput)
        XCTAssertEqual(snap.suppressionReason, .none)
    }

    func testAssembleNoSourceDegradesToSentenceOnly() {
        let snap = ContextSnapshot.assemble(
            bundleId: "com.apple.Safari", axPrecedingText: nil,
            imkPrecedingText: "", fieldSignature: nil,
            isSystemSecureInputActive: false, isSecureField: false, maxChars: 20)
        XCTAssertEqual(snap.before, "")
        XCTAssertEqual(snap.sourceTier, .sentenceOnly)
        XCTAssertEqual(snap.suppressionReason, .noSourceAvailable)
        XCTAssertFalse(snap.suppressesLearning)   // degraded read, not a privacy suppression
    }

    func testAssembleDenylistBlanksContextAndDropsSignature() {
        let snap = ContextSnapshot.assemble(
            bundleId: "com.apple.Terminal", axPrecedingText: "secret",
            imkPrecedingText: "secret", fieldSignature: sig,
            isSystemSecureInputActive: false, isSecureField: false, maxChars: 20)
        XCTAssertEqual(snap.before, "")
        XCTAssertEqual(snap.suppressionReason, .denylisted)
        XCTAssertNil(snap.fieldSignature)          // denylisted apps are never introspected
        XCTAssertTrue(snap.suppressesLearning)
    }

    func testAssembleSystemSecureInputBlanksContextButKeepsSignature() {
        let snap = ContextSnapshot.assemble(
            bundleId: "com.apple.Safari", axPrecedingText: "hunter2",
            imkPrecedingText: "hunter2", fieldSignature: sig,
            isSystemSecureInputActive: true, isSecureField: false, maxChars: 20)
        XCTAssertEqual(snap.before, "")            // learning inert
        XCTAssertEqual(snap.suppressionReason, .systemSecureInput)
        XCTAssertEqual(snap.fieldSignature, sig)   // identity is content-free, kept for send-detect
        XCTAssertTrue(snap.suppressesLearning)
    }

    func testAssembleSecureFieldBlanksContext() {
        let snap = ContextSnapshot.assemble(
            bundleId: "com.apple.Safari", axPrecedingText: "hunter2",
            imkPrecedingText: "", fieldSignature: sig,
            isSystemSecureInputActive: false, isSecureField: true, maxChars: 20)
        XCTAssertEqual(snap.before, "")
        XCTAssertEqual(snap.suppressionReason, .secureField)
        XCTAssertTrue(snap.suppressesLearning)
    }

    func testAssembleCapsPrecedingContextToMaxChars() {
        let long = String(repeating: "字", count: 50)
        let snap = ContextSnapshot.assemble(
            bundleId: "com.apple.TextEdit", axPrecedingText: long,
            imkPrecedingText: "", fieldSignature: nil,
            isSystemSecureInputActive: false, isSecureField: false, maxChars: 20)
        XCTAssertEqual(snap.before.count, 20)
        XCTAssertEqual(snap.before, String(repeating: "字", count: 20))
    }
}
