import AppKit

/// The menu bar glyph, drawn in code as template images so it reads in light, dark and
/// tinted menu bars. A ring is what you're looking at; a dot at its top edge is something
/// you already had, surfacing.
enum GlyphImage {
    static func image(for glyph: AppModel.Glyph) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let ring = NSRect(x: 3, y: 1.5, width: 12, height: 12)
            switch glyph {
            case .idle:
                let path = NSBezierPath(ovalIn: ring)
                path.lineWidth = 1.6
                path.stroke()
            case .working:
                // An open ring: the index is still filling.
                let path = NSBezierPath()
                path.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: 6, startAngle: 120, endAngle: 60, clockwise: false)
                path.lineWidth = 1.6
                path.stroke()
            case .found:
                let path = NSBezierPath(ovalIn: ring)
                path.lineWidth = 1.6
                path.stroke()
                NSBezierPath(ovalIn: NSRect(x: 6, y: 9.5, width: 6, height: 6)).fill()
            case .paused:
                let path = NSBezierPath(ovalIn: ring)
                path.lineWidth = 1.6
                path.setLineDash([2, 2.2], count: 2, phase: 0)
                path.stroke()
            case .needsSetup:
                let path = NSBezierPath(ovalIn: ring)
                path.lineWidth = 1.6
                path.stroke()
                let bang = NSBezierPath()
                bang.move(to: NSPoint(x: 9, y: 10))
                bang.line(to: NSPoint(x: 9, y: 6.5))
                bang.lineWidth = 1.6
                bang.lineCapStyle = .round
                bang.stroke()
                NSBezierPath(ovalIn: NSRect(x: 8.2, y: 3.6, width: 1.6, height: 1.6)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = switch glyph {
        case .idle: "Appears"
        case .working: "Appears is indexing"
        case .found: "Appears has something"
        case .paused: "Appears is paused"
        case .needsSetup: "Appears needs setup"
        }
        return image
    }
}
