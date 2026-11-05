import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        let background = NSBezierPath(roundedRect: NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88), xRadius: p * 0.20, yRadius: p * 0.20)
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.35, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.14, alpha: 1))!.draw(in: background, angle: -90)
        let track = NSBezierPath(ovalIn: NSRect(x: p * 0.24, y: p * 0.24, width: p * 0.52, height: p * 0.52))
        track.lineWidth = p * 0.065
        NSColor.white.withAlphaComponent(0.14).setStroke()
        track.stroke()
        let arc = NSBezierPath()
        arc.lineWidth = p * 0.065
        arc.lineCapStyle = .round
        arc.appendArc(withCenter: NSPoint(x: p / 2, y: p / 2), radius: p * 0.26, startAngle: 90, endAngle: -155, clockwise: true)
        NSColor(calibratedRed: 0.12, green: 0.62, blue: 1, alpha: 1).setStroke()
        arc.stroke()
        let needle = NSBezierPath()
        needle.lineWidth = p * 0.04
        needle.lineCapStyle = .round
        needle.move(to: NSPoint(x: p * 0.5, y: p * 0.5))
        needle.line(to: NSPoint(x: p * 0.62, y: p * 0.62))
        NSColor.white.setStroke()
        needle.stroke()
        image.unlockFocus()
        let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try representation.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
