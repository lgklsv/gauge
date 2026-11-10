import AppKit

extension Provider {
    var color: NSColor {
        switch self {
        case .codex: return .systemBlue
        case .claude: return NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
        }
    }
    @MainActor var markImage: NSImage? {
        Bundle.main.url(forResource: mark, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
}

struct StatusRing {
    var provider: Provider
    var percent: Double?
    var stale: Bool
}

@MainActor
func statusImage(rings: [StatusRing]) -> NSImage {
    // Wide enough to read as separate menu bar items that share one menu.
    let spacing: CGFloat = 12
    let width = CGFloat(max(rings.count, 1)) * (22 + spacing) - spacing
    let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
        if rings.isEmpty {
            let circle = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 18, height: 18))
            circle.lineWidth = 2
            NSColor.labelColor.withAlphaComponent(0.22).setStroke()
            circle.stroke()
        }
        for (index, ring) in rings.enumerated() {
            let rect = NSRect(x: CGFloat(index) * (22 + spacing), y: 0, width: 22, height: 22)
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            circle.lineWidth = 2
            NSColor.labelColor.withAlphaComponent(0.22).setStroke()
            circle.stroke()
            if let percent = ring.percent, percent > 0 {
                let arc = NSBezierPath()
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                arc.appendArc(
                    withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: 9,
                    startAngle: 90, endAngle: 90 - 360 * percent / 100, clockwise: true)
                NSColor.labelColor.setStroke()
                arc.stroke()
            }
            if let mark = ring.provider.markImage {
                mark.draw(in: NSRect(x: rect.minX + 5.5, y: 5.5, width: 11, height: 11))
            } else {
                let dot = NSBezierPath(ovalIn: NSRect(x: rect.minX + 8, y: 8, width: 6, height: 6))
                NSColor.labelColor.setFill()
                dot.fill()
            }
            if ring.stale {
                NSColor.labelColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.minX + 17, y: 1, width: 4, height: 4)).fill()
            }
        }
        return true
    }
    image.isTemplate = true
    return image
}

@MainActor
final class HeaderView: NSView {
    init(title: String, provider: Provider, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        let icon = NSImageView()
        icon.image = provider.markImage
        icon.image?.isTemplate = true
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
    private let color: NSColor
    private let heading = NSTextField(labelWithString: "")
    init(window: UsageWindow, color: NSColor, width: CGFloat) {
        self.usage = window
        self.color = color
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
        color.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        if usage.percent > 0 {
            color.setFill()
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
    private let series: [(values: [Double], color: NSColor)]
    init(estimate: Estimate, providers: [Provider], width: CGFloat) {
        series = providers.compactMap { provider in
            estimate.dailyCosts[provider.rawValue].map { ($0, provider.color) }
        }
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 142))
        let title = NSTextField(labelWithString: "Estimated API cost")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.frame = NSRect(x: 14, y: 118, width: width - 28, height: 20)
        title.toolTip =
            "Estimated API equivalent of local sessions, not your subscription bill."
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
        // One shared scale keeps the providers' lines comparable.
        guard let maxValue = series.flatMap(\.values).max() else { return }
        // Include the 0.75 pt half-stroke in the shared 16 pt inset.
        let area = NSRect(x: 16.75, y: 84, width: bounds.width - 33.5, height: 22)
        for (values, color) in series where values.count > 1 {
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
            color.setStroke()
            path.stroke()
        }
    }
}
