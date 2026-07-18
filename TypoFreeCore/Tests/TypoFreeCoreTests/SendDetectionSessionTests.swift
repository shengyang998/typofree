import XCTest
@testable import TypoFreeCore

// SendDetectionSession suite (DESIGN.md §2.7/§4, tasks.md §M6). Pure state
// machine, no timers. The core contract: an unresolved element == an empty
// string == `sessionEnded`.
final class SendDetectionSessionTests: XCTestCase {

    private func sig(_ width: Int = 100) -> IdentitySignature {
        FieldSignature(bundleId: "com.apple.MobileSMS", pid: 42, role: "AXTextArea",
                       subrole: nil, roundedFrame: RoundedFrame(x: 0, y: 0, width: width, height: 20))
    }

    // MARK: - The spec'd equivalence: unresolved == empty == sessionEnded

    func testUnresolvedEmptyAndSessionEndedAreEquivalent() {
        let s = sig()
        // Unresolved element (nil signature).
        var a = SendDetectionSession(signature: s, text: "你好")
        XCTAssertEqual(a.poll(signature: nil, newText: "你好"), .sessionEnded)
        // Unresolved value (nil text).
        var b = SendDetectionSession(signature: s, text: "你好")
        XCTAssertEqual(b.poll(signature: s, newText: nil), .sessionEnded)
        // Empty string.
        var c = SendDetectionSession(signature: s, text: "你好")
        XCTAssertEqual(c.poll(signature: s, newText: ""), .sessionEnded)
    }

    func testUnchangedWhenSameSignatureAndText() {
        let s = sig()
        var session = SendDetectionSession(signature: s, text: "你好")
        XCTAssertEqual(session.poll(signature: s, newText: "你好"), .unchanged)
        XCTAssertEqual(session.currentText, "你好")
    }

    func testTextChangedAccumulatesNewValue() {
        let s = sig()
        var session = SendDetectionSession(signature: s, text: "你好")
        XCTAssertEqual(session.poll(signature: s, newText: "你好世界"), .textChanged("你好世界"))
        XCTAssertEqual(session.currentText, "你好世界")
        // Then unchanged against the accumulated value.
        XCTAssertEqual(session.poll(signature: s, newText: "你好世界"), .unchanged)
    }

    func testDifferentFieldIdentityEndsSession() {
        var session = SendDetectionSession(signature: sig(100), text: "你好")
        XCTAssertEqual(session.poll(signature: sig(999), newText: "别的"), .sessionEnded)
    }

    func testSessionEndIsSticky() {
        let s = sig()
        var session = SendDetectionSession(signature: s, text: "你好")
        XCTAssertEqual(session.poll(signature: s, newText: ""), .sessionEnded)
        // Even a subsequent valid reading stays ended.
        XCTAssertEqual(session.poll(signature: s, newText: "你好"), .sessionEnded)
    }

    func testIdentitySignatureIsFieldSignature() {
        // IdentitySignature is the field-identity value type (DESIGN §2.7).
        let a: IdentitySignature = sig(100)
        let b: FieldSignature = sig(100)
        XCTAssertEqual(a, b)
    }
}
