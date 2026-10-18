import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A reproducible GIF of the production glyph and timing, using a made-up menu bar.
/// No desktop capture, user files, engine, or permission prompts.
@MainActor
func renderGlyphPreview(to directory: URL) throws {
    let width = 720, height = 440
    let fps = GlyphImage.framesPerSecond
    let duration = 8
    let url = directory.appending(path: "menu-bar-rotation.gif")
    guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                   duration * fps, nil) else { fatalError("Cannot create GIF") }
    CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

    for frame in 0..<(duration * fps) {
        let time = Double(frame) / Double(fps)
        let image = GlyphImage.image(for: .found, rotation: GlyphImage.rotation(at: time))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSColor(white: 0.96, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
            let line = NSAttributedString(string: value, attributes: attributes)
            // Text uses AppKit's normal (upwards) coordinates inside the flipped canvas.
            context.saveGState()
            context.translateBy(x: x, y: y + line.size().height)
            context.scaleBy(x: 1, y: -1)
            line.draw(at: .zero)
            context.restoreGState()
        }
        text("Appears · discovery motion", x: 28, y: 23, size: 23, color: .black, weight: .semibold)
        text("Match waiting · continuous rotation", x: 28, y: 58, size: 14, color: .darkGray)

        for (row, dark) in [false, true].enumerated() {
            let top = CGFloat(99 + row * 145)
            let ink = NSColor(white: dark ? 0.98 : 0.06, alpha: 1)
            let muted = NSColor(white: dark ? 0.65 : 0.44, alpha: 1)
            NSColor(white: dark ? 0.095 : 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 24, y: top, width: 672, height: 132), xRadius: 8, yRadius: 8).fill()
            text(dark ? "DARK MENU BAR" : "LIGHT MENU BAR", x: 42, y: top + 16, size: 10, color: muted, weight: .medium)
            NSColor(white: dark ? 0.16 : 0.94, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 42, y: top + 44, width: 440, height: 32), xRadius: 6, yRadius: 6).fill()
            text("Finder    File    Edit    View", x: 55, y: top + 52, size: 12, color: ink)
            text("Sat 10:24", x: 412, y: top + 52, size: 12, color: ink)

            // Tint the exact native template image the same way the status button does.
            let tinted = NSImage(size: image.size, flipped: true) { rect in
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                ink.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            func drawGlyph(_ rect: NSRect) {
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                tinted.draw(in: NSRect(origin: .zero, size: rect.size))
                context.restoreGState()
            }
            drawGlyph(NSRect(x: 370, y: top + 51, width: 18, height: 18))
            drawGlyph(NSRect(x: 557, y: top + 23, width: 72, height: 72))
            text("18 pt · menu bar size", x: 42, y: top + 94, size: 11, color: muted)
            text("4× detail", x: 569, y: top + 102, size: 11, color: muted)
        }
        text("Keeps rotating while a match waits · Reduce Motion keeps it still", x: 28, y: 406, size: 12, color: .darkGray)
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = bitmap.cgImage else { fatalError("Cannot render glyph") }
        // GIF stores hundredths of a second: distribute 30/40 ms frames so the
        // preview's full turn still takes exactly four seconds at 30 fps.
        let delay = Double((frame + 1) * 100 / fps - frame * 100 / fps) / 100
        CGImageDestinationAddImage(gif, cgImage, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        if frame == 2 * fps {
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "menu-bar-rotation.png"))
        }
    }
    precondition(CGImageDestinationFinalize(gif), "GIF encoding failed")
    print("Wrote \(url.path)")
}

/// Exercise the actual NSStatusBarButton and production animation task, then remove it.
@MainActor
func verifyGlyphAnimation() async {
    _ = NSApplication.shared
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    defer { NSStatusBar.system.removeStatusItem(item) }
    let button = item.button!
    var animator: StatusGlyphAnimator? = StatusGlyphAnimator(button: button)
    animator?.update(.found)
    try? await Task.sleep(for: .milliseconds(150))
    let first = button.image
    animator?.update(.found) // Polling the same state must not reset the animation.
    precondition(button.image === first)
    func waitForImageChange(from image: NSImage?) async -> Bool {
        for _ in 0..<50 {
            if button.image !== image { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return button.image !== image
    }
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        try? await Task.sleep(for: .milliseconds(150))
        precondition(button.image === first, "Reduce Motion keeps discoveries still")
    } else {
        let rotated = await waitForImageChange(from: first)
        precondition(rotated, "A waiting discovery must rotate")
        try? await Task.sleep(for: .seconds(GlyphImage.rotationDuration))
        let afterFullTurn = button.image
        let continued = await waitForImageChange(from: afterFullTurn)
        precondition(continued, "Rotation must continue after the first full turn")
    }
    for state in [AppModel.Glyph.idle, .working, .paused, .needsSetup] {
        animator?.update(state)
        let still = button.image
        try? await Task.sleep(for: .milliseconds(100))
        precondition(button.image === still, "Leaving found must stop the animation")
        precondition(still?.isTemplate == true)
    }
    animator?.update(.found)
    try? await Task.sleep(for: .milliseconds(100))
    weak var released = animator
    animator = nil
    precondition(released == nil, "The animation must not retain its owner")
    let last = button.image
    try? await Task.sleep(for: .milliseconds(100))
    precondition(button.image === last, "Releasing the owner must stop the animation")
    print("Verified native discovery animation, repeated state updates, still states, template tint, and cleanup")
}
