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
            arc.appendArc(
                withCenter: NSPoint(x: 11, y: 11), radius: 9,
                startAngle: 90, endAngle: 90 - 360 * percent / 100, clockwise: true)
            NSColor.labelColor.setStroke()
            arc.stroke()
        }
        if let mark = NSImage(
            contentsOf: Bundle.main.url(forResource: "CodexMark", withExtension: "png")
                ?? URL(fileURLWithPath: "/nonexistent"))
        {
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
final class HeaderView: NSView {
    init(title: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        let icon = NSImageView()
        if let url = Bundle.main.url(forResource: "CodexMark", withExtension: "png") {
            icon.image = NSImage(contentsOf: url)
            icon.image?.isTemplate = true
        }
        icon.contentTintColor = .labelColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 1
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class LimitView: NSView {
    private let usage: UsageWindow
    private let heading = NSTextField(labelWithString: "")
    init(window: UsageWindow, width: CGFloat) {
        self.usage = window
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 50))
        heading.maximumNumberOfLines = 1
        heading.lineBreakMode = .byTruncatingTail
        heading.frame = NSRect(x: 14, y: 26, width: width - 92, height: 20)
        addSubview(heading)
        let percent = NSTextField(labelWithString: String(format: "%.0f%%", window.percent))
        percent.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        percent.alignment = .right
        percent.frame = NSRect(x: width - 70, y: 26, width: 56, height: 20)
        addSubview(percent)
        updateCountdown()
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(window.label), \(Int(window.percent)) percent used")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateCountdown() {
        // One text run keeps the label and smaller countdown on the same baseline,
        // without a separate, tightly sized field clipping the label's last glyph.
        let text = NSMutableAttributedString(
            string: usage.label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
        let countdown = usage.countdown()
        if !countdown.isEmpty {
            text.append(
                NSAttributedString(
                    string: "  " + countdown,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
        }
        heading.attributedStringValue = text
    }
    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: 16, y: 10, width: bounds.width - 32, height: 4)
        NSColor.systemBlue.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        if usage.percent > 0 {
            NSColor.systemBlue.setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: bar.minX, y: bar.minY,
                    width: bar.width * usage.percent / 100, height: 4),
                xRadius: 2, yRadius: 2
            ).fill()
        }
    }
}

@MainActor
final class EstimateView: NSView {
    private let values: [Double]
    init(estimate: Estimate, width: CGFloat) {
        values = estimate.dailyCosts
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 142))
        let title = NSTextField(labelWithString: "Estimated API cost")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.frame = NSRect(x: 14, y: 118, width: width - 28, height: 20)
        title.toolTip =
            "Estimated API equivalent of local Codex sessions, not your subscription bill."
        addSubview(title)
        for (index, row) in [
            ("Today", estimate.today), ("7 days", estimate.week), ("30 days", estimate.month),
        ].enumerated() {
            let y = CGFloat(52 - index * 24)
            let name = NSTextField(labelWithString: row.0)
            name.font = .menuFont(ofSize: 0)
            name.frame = NSRect(x: 14, y: y, width: 75, height: 20)
            addSubview(name)
            let cost = NSTextField(labelWithString: row.1.costText)
            cost.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            cost.alignment = .right
            cost.frame = NSRect(x: 94, y: y, width: 90, height: 20)
            cost.toolTip =
                row.1.unpriced > 0
                ? "Some tokens have no known API price; the estimate is incomplete." : title.toolTip
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
        // Include the 0.75 pt half-stroke in the shared 16 pt inset.
        let area = NSRect(x: 16.75, y: 84, width: bounds.width - 33.5, height: 22)
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for (index, value) in values.enumerated() {
            let point = NSPoint(
                x: area.minX + area.width * CGFloat(index) / CGFloat(values.count - 1),
                y: area.minY + (maxValue > 0 ? area.height * value / maxValue : 0))
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        NSColor.systemBlue.setStroke()
        path.stroke()
    }
}
