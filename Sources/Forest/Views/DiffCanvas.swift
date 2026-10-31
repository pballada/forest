import AppKit
import ForestCore
import SwiftUI

/// Which hunk buttons the canvas offers.
enum HunkActions: Equatable {
    case none, unstaged, staged
}

/// Lets SwiftUI controls (the diff header) drive the AppKit canvas.
@MainActor
final class DiffCanvasController {
    fileprivate weak var document: DiffDocumentView?

    func nextChange() { document?.jumpToChange(forward: true) }
    func previousChange() { document?.jumpToChange(forward: false) }
}

/// A diff renderer that draws only what is on screen, so a 100 000-line `project.pbxproj` change
/// scrolls as smoothly as a one-liner. Unified or side-by-side, with wrapping, word highlights,
/// syntax colours, line selection for partial staging, and an overview ruler.
struct DiffCanvas: NSViewRepresentable {
    let diff: FileDiff
    let layout: DiffLayout
    let wrap: Bool
    let actions: HunkActions
    let selection: Set<Int>
    let controller: DiffCanvasController
    let onSelect: (Set<Int>) -> Void
    let onHunkAction: (DiffHunk, HunkAction) -> Void
    var onOpenInEditor: ((Int?) -> Void)?

    func makeNSView(context: Context) -> DiffContainerView {
        let view = DiffContainerView()
        controller.document = view.document
        return view
    }

    func updateNSView(_ view: DiffContainerView, context: Context) {
        controller.document = view.document
        let document = view.document
        document.onSelect = onSelect
        document.onHunkAction = { [diff] index, action in
            if let hunk = diff.hunks.first(where: { $0.id == index }) { onHunkAction(hunk, action) }
        }
        document.onOpenInEditor = onOpenInEditor
        document.update(diff: diff, layout: layout, wrap: wrap, actions: actions, selection: selection)
        view.ruler.needsDisplay = true
    }
}

final class DiffContainerView: NSView {
    let scrollView = NSScrollView()
    let document = DiffDocumentView()
    let ruler = DiffOverviewRuler()

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        addSubview(ruler)
        ruler.document = document
        document.ruler = ruler
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let rulerWidth: CGFloat = 12
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width - rulerWidth, height: bounds.height)
        ruler.frame = NSRect(x: bounds.width - rulerWidth, y: 0, width: rulerWidth, height: bounds.height)
        document.viewportChanged()
    }

    @objc private func scrolled() {
        ruler.needsDisplay = true
        document.horizontalScrollChanged()
    }
}

// MARK: - Document

final class DiffDocumentView: NSView, NSUserInterfaceValidations {
    weak var ruler: DiffOverviewRuler?
    var onSelect: ((Set<Int>) -> Void)?
    var onHunkAction: ((Int, HunkAction) -> Void)?
    var onOpenInEditor: ((Int?) -> Void)?

    private(set) var layoutData: DiffLayout?
    private var diff: FileDiff?
    private var wrap = false
    private var actions: HunkActions = .none
    private(set) var selection: Set<Int> = []
    private var anchorRow: Int?
    private var anchorSide: Side = .left
    private var highlighter: SyntaxHighlighter?

    /// y-offset of each row; `offsets[rows.count]` is the total height.
    private(set) var offsets: [CGFloat] = [0]
    private var laidOutWidth: CGFloat = -1
    private var cache: [Int: NSAttributedString] = [:]
    private var hoveredButton: (row: Int, action: HunkAction)?
    private var lastScrollX: CGFloat = 0
    private var identity = ""

    // Metrics
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let smallFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let headerFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private let buttonFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private let lineHeight: CGFloat = 19
    private let headerHeight: CGFloat = 30
    private let numberWidth: CGFloat = 46
    private let markerWidth: CGFloat = 18
    private let rightPadding: CGFloat = 24
    private lazy var charWidth: CGFloat = ("M" as NSString).size(withAttributes: [.font: font]).width
    private let maxDrawnColumns = 6000

    enum Side { case left, right }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    private var rows: [DiffRow] { layoutData?.rows ?? [] }
    private var isSplit: Bool { layoutData?.presentation == .split }
    private var viewportWidth: CGFloat { enclosingScrollView?.contentView.bounds.width ?? bounds.width }

    // MARK: Updating

    func update(diff: FileDiff, layout: DiffLayout, wrap: Bool, actions: HunkActions, selection: Set<Int>) {
        let newIdentity = "\(diff.path)|\(layout.presentation.rawValue)"
        let contentChanged = self.diff?.fingerprint != diff.fingerprint || self.layoutData?.presentation != layout.presentation
            || self.layoutData?.rows.count != layout.rows.count
        let fileChanged = newIdentity != identity
        identity = newIdentity
        if contentChanged || wrap != self.wrap {
            self.diff = diff
            self.layoutData = layout
            self.wrap = wrap
            highlighter = SyntaxHighlighter(path: diff.path)
            cache = [:]
            laidOutWidth = -1
            relayout()
        }
        if actions != self.actions { self.actions = actions; needsDisplay = true }
        if selection != self.selection {
            self.selection = selection
            needsDisplay = true
        }
        if fileChanged {
            anchorRow = nil
            scroll(NSPoint(x: 0, y: 0))
        }
    }

    func viewportChanged() {
        if wrap || abs(viewportWidth - laidOutWidth) > 0.5 { relayout() }
    }

    func horizontalScrollChanged() {
        // Hunk buttons stay pinned to the visible right edge.
        let x = visibleRect.minX
        if abs(x - lastScrollX) > 0.5 {
            lastScrollX = x
            needsDisplay = true
        }
    }

    private func relayout() {
        let width = viewportWidth
        laidOutWidth = width
        var offsets = [CGFloat]()
        offsets.reserveCapacity(rows.count + 1)
        var y: CGFloat = 0
        let wrapColumns = max(20, Int(textWidthForWrapping(viewport: width) / charWidth))
        for row in rows {
            offsets.append(y)
            if row.isHeader {
                y += headerHeight
            } else if wrap {
                let columns = row.lines.map { columnsOf($0) }.max() ?? 0
                let visualLines = max(1, Int(ceil(Double(min(columns, maxDrawnColumns * 5)) / Double(wrapColumns))))
                y += CGFloat(visualLines) * lineHeight
            } else {
                y += lineHeight
            }
        }
        offsets.append(y + 24)
        self.offsets = offsets

        let columns = CGFloat(min(layoutData?.maxColumns ?? 0, maxDrawnColumns))
        var contentWidth = width
        if !wrap {
            if isSplit {
                // Both sides always fit side by side; long lines are clipped (turn on wrapping to read them).
                contentWidth = width
            } else {
                contentWidth = max(width, unifiedTextX + columns * charWidth + rightPadding)
            }
        }
        setFrameSize(NSSize(width: contentWidth, height: max(offsets.last ?? 0, enclosingScrollView?.contentView.bounds.height ?? 0)))
        ruler?.rebuildMarks()
        needsDisplay = true
    }

    private func columnsOf(_ line: DiffLine) -> Int {
        var tabs = 0
        for byte in line.text.utf8 where byte == 9 { tabs += 1 }
        return line.text.utf16.count + tabs * (DiffLayout.tabWidth - 1)
    }

    private var unifiedTextX: CGFloat { numberWidth * 2 + markerWidth }
    private var sideTextX: CGFloat { numberWidth + markerWidth }
    private var sideWidth: CGFloat { bounds.width / 2 }

    private func textWidthForWrapping(viewport: CGFloat) -> CGFloat {
        isSplit ? viewport / 2 - sideTextX - 12 : viewport - unifiedTextX - 12
    }

    // MARK: Geometry

    func rowIndex(atY y: CGFloat) -> Int? {
        guard !rows.isEmpty, y >= 0 else { return rows.isEmpty ? nil : 0 }
        var low = 0, high = rows.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func height(of index: Int) -> CGFloat {
        let next = index + 1 < rows.count ? offsets[index + 1] : (offsets.last ?? 0) - 24
        return next - offsets[index]
    }

    // MARK: Drawing

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty, let first = rowIndex(atY: dirtyRect.minY) else { return }
        var index = first
        while index < rows.count, offsets[index] <= dirtyRect.maxY {
            let rect = NSRect(x: 0, y: offsets[index], width: bounds.width, height: height(of: index))
            if rows[index].isHeader {
                drawHeader(rows[index], index: index, in: rect)
            } else if isSplit {
                drawSplitRow(rows[index], in: rect)
            } else {
                drawUnifiedRow(rows[index], in: rect)
            }
            index += 1
        }
        if isSplit {
            DiffPalette.separator.setFill()
            NSRect(x: sideWidth - 0.5, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        }
    }

    private func drawUnifiedRow(_ row: DiffRow, in rect: NSRect) {
        guard let line = row.left else { return }
        let selected = selection.contains(line.id)
        background(for: line.kind)?.setFill()
        if line.kind != .context { rect.fill() }
        let gutterRect = NSRect(x: 0, y: rect.minY, width: numberWidth * 2, height: rect.height)
        (selected ? DiffPalette.selection : DiffPalette.gutter).setFill()
        gutterRect.fill(using: .sourceOver)
        if selected {
            DiffPalette.selection.withAlphaComponent(0.12).setFill()
            rect.fill(using: .sourceOver)
            NSColor.forestLeaf.setFill()
            NSRect(x: 0, y: rect.minY, width: 3, height: rect.height).fill()
        }
        drawNumber(line.oldLine, right: numberWidth - 8, y: rect.minY)
        drawNumber(line.newLine, right: numberWidth * 2 - 8, y: rect.minY)
        drawMarker(line.kind, x: numberWidth * 2 + 4, y: rect.minY)
        drawText(line, x: unifiedTextX, y: rect.minY, width: wrap ? bounds.width - unifiedTextX - 12 : nil)
    }

    private func drawSplitRow(_ row: DiffRow, in rect: NSRect) {
        let half = sideWidth
        for side in [Side.left, Side.right] {
            let x0 = side == .left ? 0 : half
            let sideRect = NSRect(x: x0, y: rect.minY, width: half, height: rect.height)
            let line = side == .left ? row.left : row.right
            guard let line else {
                drawFiller(in: sideRect)
                continue
            }
            let selected = selection.contains(line.id) && line.isChange
            if line.kind != .context, let color = background(for: line.kind) {
                color.setFill()
                sideRect.fill()
            }
            (selected ? DiffPalette.selection : DiffPalette.gutter).setFill()
            NSRect(x: x0, y: rect.minY, width: numberWidth, height: rect.height).fill(using: .sourceOver)
            if selected {
                NSColor.forestLeaf.setFill()
                NSRect(x: x0, y: rect.minY, width: 3, height: rect.height).fill()
            }
            drawNumber(side == .left ? line.oldLine : line.newLine, right: x0 + numberWidth - 8, y: rect.minY)
            drawMarker(line.kind, x: x0 + numberWidth + 4, y: rect.minY)
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: x0, y: rect.minY, width: half - 1, height: rect.height).clip()
            drawText(line, x: x0 + sideTextX, y: rect.minY, width: wrap ? half - sideTextX - 12 : nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawFiller(in rect: NSRect) {
        // Diagonal hatching marks "nothing on this side", like a sheet of tracing paper.
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        DiffPalette.filler.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let spacing: CGFloat = 7
        var x = rect.minX - rect.height - (rect.minY.truncatingRemainder(dividingBy: spacing))
        while x < rect.maxX {
            path.move(to: NSPoint(x: x, y: rect.maxY))
            path.line(to: NSPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func background(for kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .addition: DiffPalette.addedBackground
        case .deletion: DiffPalette.removedBackground
        default: nil
        }
    }

    private func drawNumber(_ number: Int?, right: CGFloat, y: CGFloat) {
        guard let number else { return }
        let string = String(number) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: DiffPalette.gutterText]
        let size = string.size(withAttributes: attributes)
        string.draw(at: NSPoint(x: right - size.width, y: y + (lineHeight - size.height) / 2), withAttributes: attributes)
    }

    private func drawMarker(_ kind: DiffLine.Kind, x: CGFloat, y: CGFloat) {
        let (text, color): (String, NSColor) = switch kind {
        case .addition: ("+", DiffPalette.addedText)
        case .deletion: ("−", DiffPalette.removedText)
        default: ("", .clear)
        }
        guard !text.isEmpty else { return }
        (text as NSString).draw(at: NSPoint(x: x, y: y + 1.5), withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawText(_ line: DiffLine, x: CGFloat, y: CGFloat, width: CGFloat?) {
        let text = attributedText(for: line)
        if let width {
            text.draw(with: NSRect(x: x, y: y, width: width, height: 100_000), options: [.usesLineFragmentOrigin])
        } else {
            // Skip glyphs left of the visible area on long, horizontally scrolled lines.
            text.draw(with: NSRect(x: x, y: y, width: 1_000_000, height: lineHeight), options: [.usesLineFragmentOrigin])
        }
    }

    private lazy var paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byCharWrapping
        return style
    }()

    private func attributedText(for line: DiffLine) -> NSAttributedString {
        if let cached = cache[line.id] { return cached }
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        var display = DiffLayout.displayText(line.text)
        let limit = wrap ? maxDrawnColumns * 5 : maxDrawnColumns
        if display.utf16.count > limit { display = String(display.utf16.prefix(limit)).map { $0 + "…" } ?? display }
        let baseline = (lineHeight - (font.ascender - font.descender)) / 2 - 1
        let text = NSMutableAttributedString(string: display, attributes: [
            .font: font, .foregroundColor: line.kind == .noNewline ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            .paragraphStyle: paragraph, .baselineOffset: baseline,
        ])
        let length = text.length
        if line.kind != .noNewline, let highlighter {
            for (range, token) in highlighter.tokens(in: display) where range.upperBound <= length {
                text.addAttribute(.foregroundColor, value: SyntaxHighlighter.color(for: token), range: range)
            }
        }
        if let ranges = layoutData?.highlights[line.id] {
            let color = line.kind == .addition ? DiffPalette.addedHighlight : DiffPalette.removedHighlight
            for range in ranges where range.upperBound <= length {
                text.addAttribute(.backgroundColor, value: color, range: NSRange(location: range.lowerBound, length: range.count))
            }
        }
        cache[line.id] = text
        return text
    }

    // MARK: Hunk headers

    private struct HeaderButton {
        let rect: NSRect
        let title: String
        let action: HunkAction
        let prominent: Bool
    }

    private func buttons(forHeader index: Int) -> [HeaderButton] {
        guard actions != .none else { return [] }
        let row = rows[index]
        let selectedInHunk = selectedChangeLines(inHunk: row.hunk)
        let scope = selectedInHunk > 0 ? "Lines" : "Hunk"
        let specs: [(String, HunkAction, Bool)] = actions == .unstaged
            ? [("Discard \(scope)", .discard, false), ("Stage \(scope)", .stage, true)]
            : [("Unstage \(scope)", .unstage, false)]
        var x = visibleRect.maxX - 12
        var result: [HeaderButton] = []
        for (title, action, prominent) in specs.reversed() {
            let width = (title as NSString).size(withAttributes: [.font: buttonFont]).width + 20
            x -= width
            result.insert(HeaderButton(rect: NSRect(x: x, y: offsets[index] + 5, width: width, height: 20), title: title,
                                       action: action, prominent: prominent), at: 0)
            x -= 6
        }
        return result
    }

    private func selectedChangeLines(inHunk hunk: Int) -> Int {
        guard !selection.isEmpty, let diffHunk = diff?.hunks.first(where: { $0.id == hunk }) else { return 0 }
        return diffHunk.lines.filter { $0.isChange && selection.contains($0.id) }.count
    }

    private func drawHeader(_ row: DiffRow, index: Int, in rect: NSRect) {
        DiffPalette.header.setFill()
        rect.fill()
        DiffPalette.separator.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        guard let hunk = diff?.hunks.first(where: { $0.id == row.hunk }) else { return }

        let x = visibleRect.minX + 12
        let range = "@@ −\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@" as NSString
        let rangeAttributes: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: DiffPalette.headerText]
        let rangeSize = range.size(withAttributes: rangeAttributes)
        range.draw(at: NSPoint(x: x, y: rect.minY + (headerHeight - rangeSize.height) / 2), withAttributes: rangeAttributes)
        let buttons = buttons(forHeader: index)
        if !hunk.context.isEmpty {
            let limit = (buttons.first?.rect.minX ?? visibleRect.maxX) - 16
            let contextRect = NSRect(x: x + rangeSize.width + 12, y: rect.minY + 7, width: max(0, limit - x - rangeSize.width - 12), height: 16)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            (hunk.context as NSString).draw(with: contextRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
                .font: headerFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
            ])
        }
        for button in buttons {
            let hovered = hoveredButton?.row == index && hoveredButton?.action == button.action
            let path = NSBezierPath(roundedRect: button.rect, xRadius: 6, yRadius: 6)
            if button.prominent {
                NSColor.forestLeaf.withAlphaComponent(hovered ? 1 : 0.9).setFill()
            } else if button.action == .discard {
                DiffPalette.removedText.withAlphaComponent(hovered ? 0.2 : 0.1).setFill()
            } else {
                NSColor.labelColor.withAlphaComponent(hovered ? 0.14 : 0.07).setFill()
            }
            path.fill()
            let color: NSColor = button.prominent ? .white : (button.action == .discard ? DiffPalette.removedText : .labelColor)
            let title = button.title as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: buttonFont, .foregroundColor: color]
            let size = title.size(withAttributes: attributes)
            title.draw(at: NSPoint(x: button.rect.midX - size.width / 2, y: button.rect.midY - size.height / 2), withAttributes: attributes)
        }
    }

    // MARK: Mouse & keyboard

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var hovered: (Int, HunkAction)?
        if let index = rowIndex(atY: point.y), rows[index].isHeader,
           let button = buttons(forHeader: index).first(where: { $0.rect.contains(point) }) {
            hovered = (index, button.action)
        }
        if hovered?.0 != hoveredButton?.row || hovered?.1 != hoveredButton?.action {
            if let old = hoveredButton?.row { setNeedsDisplay(NSRect(x: 0, y: offsets[old], width: bounds.width, height: headerHeight)) }
            hoveredButton = hovered.map { (row: $0.0, action: $0.1) }
            if let new = hovered?.0 { setNeedsDisplay(NSRect(x: 0, y: offsets[new], width: bounds.width, height: headerHeight)) }
            (hovered == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let old = hoveredButton?.row {
            hoveredButton = nil
            setNeedsDisplay(NSRect(x: 0, y: offsets[old], width: bounds.width, height: headerHeight))
        }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(atY: point.y), point.y < (offsets.last ?? 0) - 24 else {
            setSelection([])
            return
        }
        let row = rows[index]
        if row.isHeader {
            if let button = buttons(forHeader: index).first(where: { $0.rect.contains(point) }) {
                onHunkAction?(row.hunk, button.action)
            } else {
                // Clicking a header selects the whole hunk's changes.
                let ids = rows.filter { $0.hunk == row.hunk && !$0.isHeader }.flatMap(\.lines).filter(\.isChange).map(\.id)
                setSelection(event.modifierFlags.contains(.command) ? selection.symmetricDifference(ids) : Set(ids))
            }
            return
        }
        if event.clickCount == 2 {
            onOpenInEditor?(row.right?.newLine ?? row.left?.newLine ?? row.left?.oldLine)
            return
        }
        let side: Side = isSplit && point.x >= sideWidth ? .right : .left
        let ids = lineIDs(in: index...index, side: side)
        if event.modifierFlags.contains(.shift), let anchor = anchorRow {
            setSelection(selection.union(lineIDs(in: min(anchor, index)...max(anchor, index), side: anchorSide)))
        } else if event.modifierFlags.contains(.command) {
            setSelection(selection.symmetricDifference(ids))
            anchorRow = index
            anchorSide = side
        } else {
            setSelection(selection == Set(ids) ? [] : Set(ids))
            anchorRow = index
            anchorSide = side
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = anchorRow else { return }
        let point = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        guard let index = rowIndex(atY: point.y) else { return }
        setSelection(Set(lineIDs(in: min(anchor, index)...max(anchor, index), side: anchorSide)))
    }

    private func lineIDs(in range: ClosedRange<Int>, side: Side) -> [Int] {
        range.flatMap { index -> [Int] in
            guard index < rows.count, !rows[index].isHeader else { return [] }
            let row = rows[index]
            if isSplit {
                let line = side == .left ? row.left : row.right
                return line.map { [$0.id] } ?? []
            }
            return row.left.map { [$0.id] } ?? []
        }
    }

    private func setSelection(_ ids: Set<Int>) {
        guard ids != selection else { return }
        selection = ids
        needsDisplay = true
        onSelect?(ids)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: setSelection([])  // esc
        default: super.keyDown(with: event)
        }
    }

    override func selectAll(_ sender: Any?) {
        setSelection(Set(rows.flatMap(\.lines).map(\.id)))
    }

    @objc func copy(_ sender: Any?) {
        var seen = Set<Int>()
        var lines: [String] = []
        for row in rows where !row.isHeader {
            for line in row.lines where selection.contains(line.id) && seen.insert(line.id).inserted {
                lines.append(line.text)
            }
        }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selection.isEmpty }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let index = rowIndex(atY: point.y), !rows[index].isHeader, selection.isEmpty {
            let side: Side = isSplit && point.x >= sideWidth ? .right : .left
            setSelection(Set(lineIDs(in: index...index, side: side)))
        }
        let menu = NSMenu()
        let hunks = Set(rows.filter { !$0.isHeader && $0.lines.contains { selection.contains($0.id) && $0.isChange } }.map(\.hunk))
        if hunks.count == 1, let hunk = hunks.first {
            switch actions {
            case .unstaged:
                menu.addItem(ClosureMenuItem("Stage Selected Lines") { [weak self] in self?.onHunkAction?(hunk, .stage) })
                menu.addItem(ClosureMenuItem("Discard Selected Lines…") { [weak self] in self?.onHunkAction?(hunk, .discard) })
                menu.addItem(.separator())
            case .staged:
                menu.addItem(ClosureMenuItem("Unstage Selected Lines") { [weak self] in self?.onHunkAction?(hunk, .unstage) })
                menu.addItem(.separator())
            case .none:
                break
            }
        }
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        if let onOpenInEditor {
            let line = rowIndex(atY: point.y).flatMap { rows[$0].right?.newLine ?? rows[$0].left?.newLine }
            menu.addItem(ClosureMenuItem("Open in Editor") { onOpenInEditor(line) })
        }
        return menu
    }

    // MARK: Navigation

    func jumpToChange(forward: Bool) {
        guard let starts = layoutData?.changeStarts, !starts.isEmpty, let clip = enclosingScrollView?.contentView else { return }
        let top = clip.bounds.minY + 40
        let target: Int?
        if forward {
            target = starts.first { offsets[$0] > top + 1 }
        } else {
            target = starts.last { offsets[$0] < top - 1 }
        }
        guard let target else { NSSound.beep(); return }
        let y = max(0, offsets[target] - 40)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: min(y, max(0, bounds.height - clip.bounds.height))))
        }
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    func scrollTo(fraction: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let y = fraction * bounds.height - clip.bounds.height / 2
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: max(0, min(y, bounds.height - clip.bounds.height))))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// Coloured segments for the overview ruler, as fractions of the document height.
    func overviewMarks() -> [(ClosedRange<CGFloat>, NSColor)] {
        let total = max(bounds.height, offsets.last ?? 1, 1)
        var marks: [(ClosedRange<CGFloat>, NSColor)] = []
        var index = 0
        while index < rows.count {
            let row = rows[index]
            guard row.isChange else { index += 1; continue }
            let kind = changeKind(row)
            let start = index
            while index < rows.count, rows[index].isChange, changeKind(rows[index]) == kind { index += 1 }
            let color: NSColor = kind == 1 ? DiffPalette.addedText : kind == 2 ? DiffPalette.removedText : NSColor.systemOrange
            marks.append((offsets[start] / total...offsets[index] / total, color))
        }
        return marks
    }

    private func changeKind(_ row: DiffRow) -> Int {
        let added = row.lines.contains { $0.kind == .addition }
        let removed = row.lines.contains { $0.kind == .deletion }
        return added && removed ? 3 : added ? 1 : 2
    }
}

/// The thin strip beside the diff showing where changes are; click or drag to jump.
final class DiffOverviewRuler: NSView {
    weak var document: DiffDocumentView?
    private var marks: [(ClosedRange<CGFloat>, NSColor)] = []

    override var isFlipped: Bool { true }

    func rebuildMarks() {
        marks = document?.overviewMarks() ?? []
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        DiffPalette.gutter.setFill()
        bounds.fill()
        DiffPalette.separator.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        let height = bounds.height - 4
        for (range, color) in marks {
            color.withAlphaComponent(0.85).setFill()
            let y = 2 + range.lowerBound * height
            let h = max(2, (range.upperBound - range.lowerBound) * height)
            NSBezierPath(roundedRect: NSRect(x: 3, y: y, width: bounds.width - 5, height: h), xRadius: 1.5, yRadius: 1.5).fill()
        }
        if let document, let clip = document.enclosingScrollView?.contentView, document.bounds.height > clip.bounds.height {
            let total = document.bounds.height
            let rect = NSRect(x: 1, y: 2 + clip.bounds.minY / total * height, width: bounds.width - 2,
                              height: max(10, clip.bounds.height / total * height))
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }
    }

    override func mouseDown(with event: NSEvent) { jump(event) }
    override func mouseDragged(with event: NSEvent) { jump(event) }

    private func jump(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        document?.scrollTo(fraction: max(0, min(1, (point.y - 2) / max(1, bounds.height - 4))))
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
