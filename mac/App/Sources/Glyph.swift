import AppKit

/// The menu bar glyph, drawn in code as template images so it reads in light, dark and
/// tinted menu bars. Orbit leaves a gap at the upper right for a discovery.
enum GlyphImage {
    static func image(for glyph: AppModel.Glyph) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.scaleBy(x: size.width / 24, y: size.height / 24)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(OrbitGeometry.lineWidth)
            context.setLineCap(.round)
            context.addPath(OrbitGeometry.ring(indexing: glyph == .working))
            context.strokePath()
            switch glyph {
            case .idle, .working:
                break
            case .found:
                context.fillEllipse(in: OrbitGeometry.dot())
            case .paused:
                context.setLineWidth(1.8)
                for x in [9.5, 13.5] {
                    context.move(to: CGPoint(x: x, y: 10.3))
                    context.addLine(to: CGPoint(x: x, y: 15.3))
                }
                context.strokePath()
            case .needsSetup:
                context.setLineWidth(1.9)
                context.move(to: CGPoint(x: 11.5, y: 9.1))
                context.addLine(to: CGPoint(x: 11.5, y: 12.3))
                context.strokePath()
                context.fillEllipse(in: CGRect(x: 10.5, y: 14.5, width: 2, height: 2))
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
