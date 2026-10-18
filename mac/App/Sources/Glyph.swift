import AppKit

/// The menu bar glyph, drawn in code as template images so it reads in light, dark and
/// tinted menu bars. Orbit leaves a gap at the upper right for a discovery.
enum GlyphImage {
    static let rotationDuration: TimeInterval = 4
    static let framesPerSecond = 30
    static let frameCount = Int(rotationDuration) * framesPerSecond

    static func rotation(at elapsed: TimeInterval) -> CGFloat {
        let frame = Int(max(0, elapsed) * Double(framesPerSecond)) % frameCount
        return CGFloat(frame) / CGFloat(frameCount) * 2 * .pi
    }

    static func image(for glyph: AppModel.Glyph, rotation: CGFloat = 0) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.scaleBy(x: size.width / 24, y: size.height / 24)
            if glyph == .found {
                // Rotate the whole mark inside its existing image bounds. All angles fit,
                // including the detached dot; the status item's hit target stays still.
                context.translateBy(x: 12, y: 12)
                context.rotate(by: rotation)
                context.translateBy(x: -12, y: -12)
            }
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

/// Animates only a discovery that's still waiting. Template images retain the system's
/// menu bar tint and highlighted appearance, without rotating the button or its hit target.
@MainActor
final class StatusGlyphAnimator: NSObject {
    private weak var button: NSStatusBarButton?
    private var glyph: AppModel.Glyph?
    private var alertStyle: MatchAlertStyle = .motion
    private var animation: Task<Void, Never>?
    private var displayAsleep = false
    private lazy var frames = (0..<GlyphImage.frameCount).map {
        GlyphImage.image(for: .found, rotation: CGFloat($0) / CGFloat(GlyphImage.frameCount) * 2 * .pi)
    }

    init(button: NSStatusBarButton) {
        self.button = button
        super.init()
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.addObserver(self, selector: #selector(refresh), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        notifications.addObserver(self, selector: #selector(displaySlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        notifications.addObserver(self, selector: #selector(displayWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    deinit {
        animation?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func update(_ glyph: AppModel.Glyph, style: MatchAlertStyle = .motion) {
        guard self.glyph != glyph || alertStyle != style else { return }
        self.glyph = glyph
        alertStyle = style
        refresh()
    }

    @objc private func displaySlept() { displayAsleep = true; refresh() }
    @objc private func displayWoke() { displayAsleep = false; refresh() }

    @objc private func refresh() {
        animation?.cancel()
        animation = nil
        guard let glyph else { return }
        button?.image = GlyphImage.image(for: glyph)
        guard glyph == .found, alertStyle == .motion, !displayAsleep,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let started = ProcessInfo.processInfo.systemUptime
        animation = Task { [weak self] in
            while !Task.isCancelled {
                self?.drawFrame(elapsed: ProcessInfo.processInfo.systemUptime - started)
                do { try await Task.sleep(for: .seconds(1.0 / Double(GlyphImage.framesPerSecond))) }
                catch { return }
            }
        }
    }

    private func drawFrame(elapsed: TimeInterval) {
        let frame = Int(elapsed * Double(GlyphImage.framesPerSecond)) % GlyphImage.frameCount
        button?.image = frames[frame]
    }
}
