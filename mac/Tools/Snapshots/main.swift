import AppKit
import AppearsCore
import SwiftUI

// appears-snapshots: renders the panel (pull and ambient), its empty and setup states, and
// onboarding, in light and dark, to PNGs in mac/build/snapshots. Uses demo/files for the
// thumbnails. No permissions needed. Run from the repository root.

let root = URL(filePath: FileManager.default.currentDirectoryPath)
let demo = root.appending(path: "demo/files")
let out = root.appending(path: "mac/build/snapshots")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func item(_ id: Int64, _ path: String, _ kind: ItemKind, days: Double) -> Item {
    let date = Date().addingTimeInterval(-days * 86_400)
    return Item(id: id, source: .file, path: demo.appending(path: path).path, kind: kind,
                title: (path as NSString).lastPathComponent, size: 1, created: date, modified: date, lastUsed: nil)
}

let features = Features(cosine: 0.8, zScore: 5, agreement: true, entityHit: true, daysSinceTouched: 500, fused: 0.05, forgotten: 1, novelty: 1)
let suggestions = [
    Suggestion(item: item(1, "Documents/House/Kitchen/IMG_4471.jpg", .image, days: 520), unit: Unit(kind: .image, locator: .whole, text: ""),
               reason: "Mentions Dana Ruiz · from May 2025", snippet: "Ruiz & Daughters Builders — Quote Q-2291 — Kitchen remodel. Cabinets (shaker, white oak) $9,800…",
               score: 1, confidence: 0.98, features: features),
    Suggestion(item: item(2, "Documents/House/Kitchen/permit-BLD-2024-0457.pdf", .pdf, days: 505), unit: Unit(kind: .text, locator: .page(3), text: ""),
               reason: "Page 3: scope of work · from May 2025 · page 3", snippet: "Interior kitchen remodel. Replace cabinets and countertops, relocate sink 3 feet, add six (6) 20-amp GFCI outlets…",
               score: 0.7, confidence: 0.75, features: features),
    Suggestion(item: item(3, "Documents/House/Kitchen measurements.md", .document, days: 530), unit: Unit(kind: .text, locator: .chunk(0), text: ""),
               reason: "Related · from April 2025", snippet: "Back wall: 11' 4\" (sink wall). Window: 36\" wide, sill at 42\". Dana said the outlet by the window has to move for code",
               score: 0.4, confidence: 0.24, features: features),
]

@MainActor func thumbnails() async {
    for s in suggestions {
        if let image = await Thumbnails.image(for: s) { Thumbnails.cache[s.item.id] = image }
        else if s.item.kind == .image, let cg = Extractor.loadImage(URL(filePath: s.item.path), maxPixels: 160) {
            Thumbnails.cache[s.item.id] = NSImage(cgImage: cg, size: NSSize(width: 52, height: 52))
        }
    }
}

@MainActor func render<V: View>(_ view: V, _ name: String, width: CGFloat) {
    for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).padding(24).background(scheme == .dark ? Color(white: 0.04) : Color(white: 0.96)))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: max(size.width, width + 48), height: size.height))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        rep.size = host.bounds.size
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "\(name)-\(suffix).png"))
    }
}

@MainActor func run() async {
    await thumbnails()
    let model = AppModel()
    var status = EngineStatus()
    status.ready = true
    status.counts.indexed = [.image: 2_413, .pdf: 611, .document: 3_982, .note: 214]

    model.showForSnapshot(.init(mode: .pull, appName: "Mail", windowTitle: "Re: Kitchen — can you start on the 14th?", fingerprint: "x",
                                suggestions: suggestions, weaker: []), status: status)
    render(PanelView(model: model, close: {}), "panel-pull", width: 400)

    model.showForSnapshot(.init(mode: .ambient, appName: "Mail", windowTitle: "Re: Kitchen — can you start on the 14th?", fingerprint: "x",
                                suggestions: Array(suggestions.prefix(2)), weaker: []), status: status)
    render(PanelView(model: model, close: {}), "panel-ambient", width: 400)

    model.showForSnapshot(.init(mode: .pull, appName: "Safari", windowTitle: "NASA rover finds evidence of ancient lakebeds", fingerprint: "x",
                                suggestions: [], weaker: [suggestions[2]]), status: status)
    render(PanelView(model: model, close: {}), "panel-empty", width: 400)

    model.showForSnapshot(nil, status: status, trusted: false)
    render(PanelView(model: model, close: {}), "panel-setup", width: 400)

    render(OnboardingView(model: model, done: {}), "onboarding", width: 520)
    print("Wrote snapshots to \(out.path)")
}

MainActor.assumeIsolated {
    Task { await run(); exit(0) }
}
RunLoop.main.run()
