import AppKit

@MainActor
func statusImage(percent: Double?, stale: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
        circle.lineWidth = 2
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        circle.stroke()
        if let percent, percent > 0 {
            let arc = NSBezierPath()
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            arc.appendArc(withCenter: NSPoint(x: 11, y: 11), radius: 9,
                          startAngle: 90, endAngle: 90 - 360 * percent / 100, clockwise: true)
            NSColor.labelColor.setStroke()
            arc.stroke()
        }
        if let mark = NSImage(contentsOf: Bundle.main.url(forResource: "CodexMark", withExtension: "png") ?? URL(fileURLWithPath: "/nonexistent")) {
            mark.draw(in: NSRect(x: 5.5, y: 5.5, width: 11, height: 11))
        } else {
            let dot = NSBezierPath(ovalIn: NSRect(x: 8, y: 8, width: 6, height: 6))
            NSColor.labelColor.setFill()
            dot.fill()
        }
        if stale {
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 17, y: 1, width: 4, height: 4)).fill()
        }
        return true
    }
    image.isTemplate = true
    return image
}

@MainActor
final class LimitView: NSView {
    private let usage: UsageWindow
    private let countdown = NSTextField(labelWithString: "")
    init(window: UsageWindow, width: CGFloat) {
        self.usage = window
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 58))
        let title = NSTextField(labelWithString: window.label)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.frame = NSRect(x: 14, y: 30, width: title.intrinsicContentSize.width, height: 20)
        addSubview(title)
        countdown.font = .systemFont(ofSize: 11)
        countdown.textColor = .secondaryLabelColor
        countdown.frame = NSRect(x: title.frame.maxX + 6, y: 32, width: 118, height: 16)
        addSubview(countdown)
        let percent = NSTextField(labelWithString: String(format: "%.0f%%", window.percent))
        percent.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        percent.alignment = .right
        percent.frame = NSRect(x: width - 70, y: 30, width: 56, height: 20)
        addSubview(percent)
        updateCountdown()
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(window.label), \(Int(window.percent)) percent used")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateCountdown() { countdown.stringValue = usage.countdown() }
    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: 14, y: 14, width: bounds.width - 28, height: 4)
        NSColor.systemBlue.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        if usage.percent > 0 {
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY,
                                             width: bar.width * usage.percent / 100, height: 4),
                         xRadius: 2, yRadius: 2).fill()
        }
    }
}

@MainActor
final class EstimateView: NSView {
    private let values: [Double]
    init(estimate: Estimate, width: CGFloat) {
        values = estimate.dailyCosts
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 150))
        let title = NSTextField(labelWithString: "Estimated API cost")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.frame = NSRect(x: 14, y: 122, width: width - 28, height: 20)
        title.toolTip = "Estimated API equivalent of local Codex sessions, not your subscription bill."
        addSubview(title)
        for (index, row) in [("Today", estimate.today), ("7 days", estimate.week), ("30 days", estimate.month)].enumerated() {
            let y = CGFloat(56 - index * 24)
            let name = NSTextField(labelWithString: row.0)
            name.font = .systemFont(ofSize: 13)
            name.frame = NSRect(x: 14, y: y, width: 75, height: 20)
            addSubview(name)
            let cost = NSTextField(labelWithString: row.1.costText)
            cost.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            cost.alignment = .right
            cost.frame = NSRect(x: 94, y: y, width: 90, height: 20)
            cost.toolTip = row.1.unpriced > 0 ? "Some tokens have no known API price; the estimate is incomplete." : title.toolTip
            addSubview(cost)
            let tokens = NSTextField(labelWithString: row.1.tokenText)
            tokens.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            tokens.textColor = .secondaryLabelColor
            tokens.alignment = .right
            tokens.frame = NSRect(x: width - 101, y: y, width: 87, height: 20)
            addSubview(tokens)
        }
        toolTip = estimate.warning ?? title.toolTip
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        guard let maxValue = values.max(), values.count > 1 else { return }
        let area = NSRect(x: 15, y: 88, width: bounds.width - 30, height: 22)
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        for (index, value) in values.enumerated() {
            let point = NSPoint(x: area.minX + area.width * CGFloat(index) / CGFloat(values.count - 1),
                                y: area.minY + (maxValue > 0 ? area.height * value / maxValue : 0))
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        NSColor.systemBlue.setStroke()
        path.stroke()
    }
}
