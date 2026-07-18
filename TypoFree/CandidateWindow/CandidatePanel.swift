import AppKit
import TypoFreeCore

// CandidatePanel — the one shared non-activating NSPanel that hosts the
// self-drawn candidate bar (DESIGN.md §2.5, MF#11; IMKSwift README §5/§6:
// avoid IMKCandidates' LiquidGlass glitches, consolidate into a single NSWindow).
// It conforms to Core's `CandidateRendering`; `updateSlot1` redraws ONLY the
// content in place and never resizes the panel, so a late async correction never
// reflows the bar (fixed slot geometry lives in `CandidateBarView`).
@MainActor final class CandidatePanel: NSObject, CandidateRendering {
    private let panel: NSPanel
    private let barView: CandidateBarView

    override init() {
        let initial = NSRect(x: 0, y: 0, width: 320, height: CandidateBarView.barHeight)
        barView = CandidateBarView(frame: initial)
        panel = NSPanel(contentRect: initial,
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = barView
        super.init()
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ model: CandidateBarModel, at caret: CGRect) {
        barView.model = model
        let size = barView.intrinsicSize()
        panel.setContentSize(size)
        panel.setFrameOrigin(placement(for: caret, size: size))
        barView.needsDisplay = true
        panel.orderFront(nil)          // non-activating — never steals key focus
    }

    func updateSlot1(_ state: Slot1State) {
        guard barView.model != nil else { return }
        barView.model?.slot1 = state
        barView.needsDisplay = true    // fixed geometry ⇒ redraw in place, NO reflow
    }

    func moveHighlight(to index: Int) {
        guard barView.model != nil else { return }
        barView.model?.highlighted = index
        barView.needsDisplay = true
    }

    func hide() {
        panel.orderOut(nil)
        barView.model = nil
    }

    // MARK: - Placement

    /// Below the caret by default, flipping above / clamping horizontally to keep
    /// the bar on the caret's screen.
    private func placement(for caret: CGRect, size: NSSize) -> NSPoint {
        let gap: CGFloat = 4
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
        var x = caret.minX
        var y = caret.minY - size.height - gap      // below the caret
        if let visible = screen?.visibleFrame {
            if y < visible.minY { y = caret.maxY + gap }               // flip above
            x = min(max(x, visible.minX), visible.maxX - size.width)   // clamp
        }
        return NSPoint(x: x, y: y)
    }
}
