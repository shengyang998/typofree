import AppKit
import TypoFreeCore

// CandidateBarView — the self-drawn candidate bar (DESIGN.md §2.5, MF#11). A
// plain `NSView.draw(_:)` (no SwiftUI, no IMKCandidates) so macOS-26 LiquidGlass
// can't turn it into a transparent white block. FIXED slot geometry: slot#1 has
// a constant width, so when the async LLM correction lands it only repaints its
// own cell — the bar never reflows and slot#2/#3+ never shift.
@MainActor final class CandidateBarView: NSView {
    static let barHeight: CGFloat = 34
    private static let slot1Width: CGFloat = 168      // fixed → no reflow on async land
    private static let outerInset: CGFloat = 10
    private static let cellGap: CGFloat = 6
    private static let cellPadding: CGFloat = 8
    private static let corner: CGFloat = 8

    private static let candidateFont = NSFont.systemFont(ofSize: 16)
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    var model: CandidateBarModel?

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    // MARK: - Cell model (flat visual order: 0 = slot#1, 1 = engineBest, 2+ = words)

    private struct Cell {
        let label: String
        let text: String
        let fixedWidth: CGFloat?
        let mark: String?
    }

    private func cells(for model: CandidateBarModel) -> [Cell] {
        var out: [Cell] = []
        let slot1Text: String
        let slot1Mark: String?
        switch model.slot1 {
        case .computing(let provisional):
            slot1Text = provisional; slot1Mark = "⋯"     // spinner placeholder (static; M8 animates)
        case .landed(let corrected):
            slot1Text = corrected; slot1Mark = "✦"       // validated LLM correction
        case .unavailable:
            slot1Text = model.engineBest; slot1Mark = nil // no LLM → recommended == engineBest
        }
        out.append(Cell(label: "1", text: slot1Text, fixedWidth: Self.slot1Width, mark: slot1Mark))
        out.append(Cell(label: "2", text: model.engineBest, fixedWidth: nil, mark: nil))
        for (i, word) in model.words.enumerated() {
            out.append(Cell(label: "\(i + 3)", text: word.word, fixedWidth: nil, mark: nil))
        }
        return out
    }

    // MARK: - Sizing

    func intrinsicSize() -> NSSize {
        guard let model else { return NSSize(width: 96, height: Self.barHeight) }
        var width = Self.outerInset
        for cell in cells(for: model) {
            width += cellWidth(cell) + Self.cellGap
        }
        width += Self.outerInset - Self.cellGap
        return NSSize(width: max(width, 96), height: Self.barHeight)
    }

    private func cellWidth(_ cell: Cell) -> CGFloat {
        if let fixed = cell.fixedWidth { return fixed }
        return measuredWidth(cell)
    }

    private func measuredWidth(_ cell: Cell) -> CGFloat {
        let label = NSString(string: cell.label).size(withAttributes: [.font: Self.labelFont])
        var text = NSString(string: cell.text).size(withAttributes: [.font: Self.candidateFont])
        if let mark = cell.mark {
            text.width += NSString(string: mark + " ").size(withAttributes: [.font: Self.candidateFont]).width
        }
        return Self.cellPadding + label.width + 4 + text.width + Self.cellPadding
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        NSColor.clear.set()
        dirtyRect.fill()

        // Rounded background.
        let bg = NSBezierPath(roundedRect: bounds, xRadius: Self.corner, yRadius: Self.corner)
        NSColor.windowBackgroundColor.withAlphaComponent(0.98).setFill()
        bg.fill()
        NSColor.separatorColor.setStroke()
        bg.lineWidth = 1
        bg.stroke()

        var x = Self.outerInset
        let laid = cells(for: model)
        for (index, cell) in laid.enumerated() {
            let width = cellWidth(cell)
            let cellRect = NSRect(x: x, y: 0, width: width, height: bounds.height)
            draw(cell, in: cellRect, highlighted: index == model.highlighted)
            x += width + Self.cellGap
        }
    }

    private func draw(_ cell: Cell, in rect: NSRect, highlighted: Bool) {
        if highlighted {
            let hl = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 4), xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            hl.fill()
        }

        var cursorX = rect.minX + Self.cellPadding

        // Number label.
        let label = NSString(string: cell.label)
        let labelSize = label.size(withAttributes: [.font: Self.labelFont])
        label.draw(at: NSPoint(x: cursorX, y: (rect.height - labelSize.height) / 2),
                   withAttributes: [.font: Self.labelFont, .foregroundColor: NSColor.secondaryLabelColor])
        cursorX += labelSize.width + 4

        // Optional smart-slot mark.
        if let mark = cell.mark {
            let markStr = NSString(string: mark + " ")
            let markSize = markStr.size(withAttributes: [.font: Self.candidateFont])
            markStr.draw(at: NSPoint(x: cursorX, y: (rect.height - markSize.height) / 2),
                         withAttributes: [.font: Self.candidateFont, .foregroundColor: NSColor.controlAccentColor])
            cursorX += markSize.width
        }

        // Candidate text (clipped to the fixed slot width — that is what prevents
        // reflow when a longer correction lands in slot#1).
        let text = NSString(string: cell.text)
        let textSize = text.size(withAttributes: [.font: Self.candidateFont])
        let textColor: NSColor = highlighted ? .controlAccentColor : .labelColor
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        text.draw(at: NSPoint(x: cursorX, y: (rect.height - textSize.height) / 2),
                  withAttributes: [.font: Self.candidateFont, .foregroundColor: textColor])
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
