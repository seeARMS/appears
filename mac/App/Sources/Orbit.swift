import CoreGraphics
import SwiftUI

/// Orbit's approved 24-point drawing. Coordinates run down from the top left,
/// matching the site and brand assets (web/src/lib/orbit.ts).
enum OrbitGeometry {
    static let center = CGPoint(x: 11.5, y: 12.8)
    static let radius: CGFloat = 7.5
    static let lineWidth: CGFloat = 2.1
    static let dotCenter = CGPoint(x: 17.5, y: 6.4)
    static let dotRadius: CGFloat = 2.65

    static func ring(indexing: Bool = false) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: .pi / 18,
                    endAngle: indexing ? 4.06 : .pi * 1.5, clockwise: false)
        return path
    }

    static func dot(progress: CGFloat = 1) -> CGRect {
        let r = dotRadius * (0.4 + 0.6 * progress)
        return CGRect(x: dotCenter.x - r, y: dotCenter.y - r, width: r * 2, height: r * 2)
    }
}

/// The same Orbit drawing in the brand mark and onboarding illustrations.
/// Only illustrations animate the dot; the real menu bar stays still.
struct OrbitSymbol: View {
    var size: CGFloat = 24
    var found: Double = 1
    var ink: Color = Theme.foreground
    var accent: Color = Theme.accent

    var body: some View {
        let transform = CGAffineTransform(scaleX: size / 24, y: size / 24)
        ZStack {
            Path(OrbitGeometry.ring()).applying(transform)
                .stroke(ink, style: StrokeStyle(lineWidth: OrbitGeometry.lineWidth * size / 24, lineCap: .round))
            Path(ellipseIn: OrbitGeometry.dot(progress: CGFloat(found))).applying(transform)
                .fill(accent)
                .opacity(found)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
