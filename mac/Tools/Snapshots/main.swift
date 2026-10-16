import AppKit
import AppearsCore
import SwiftUI

// appears-snapshots: renders the panel (pull, ambient and before a meeting), its empty and setup
// states, onboarding and Settings' General pane, in light and dark, to PNGs in mac/build/snapshots. Uses demo/files for the
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

/// A result whose selected row quotes the line that answers: the demo's cabin card (as Vision
/// reads it) and the garage invoice (as PDFKit does), run through the real line picker.
func answering(_ asked: String, _ id: Int64, _ path: String, _ kind: ItemKind, days: Double, text: String, reason: String) -> Suggestion {
    let line = Question(ContextSnapshot(focusedText: asked)).flatMap { MatchedLine.find(in: text, for: $0) }
    return Suggestion(item: item(id, path, kind, days: days), unit: Unit(kind: kind == .image ? .image : .text, locator: kind == .pdf ? .page(1) : .whole, text: text),
                      reason: reason, snippet: String(text.prefix(160)), score: 1, confidence: 0.97, features: features, line: line)
}
let cabin = answering(
    "Thanks Joan! What was the wifi password again?", 4, "Desktop/IMG_2031.jpg", .image, days: 470,
    text: "Welcome to Pine Hollow Cabin!\nWiFi: PineHollow-Guest\nPassword: trout-meadow-88\nHot tub: cover back on please\nTrash pickup Tuesday a.m.\nEmergency: Joan (530) 555-0177",
    reason: "Mentions Joan · from July 2025"
)
let invoice = answering(
    "CR-V brakes grinding when stopping. When were the brakes last looked at? Call Eastshore Honda.", 5,
    "Documents/Car/Honda service invoice 2023-08.pdf", .pdf, days: 430,
    text: "EASTSHORE HONDA — SERVICE INVOICE RO# 418820\nService date: Aug 14, 2023\nVehicle: 2019 Honda CR-V EX Mileage in: 42,118\nServices performed:\nMaintenance B1: oil and filter, tire rotation $189.95\nReplace cabin air filter $64.00\nBrake fluid replacement $139.00\nRecommended at next visit: rear brake pads (3mm remaining)\nTotal: $392.95 Paid by card ending 5521",
    reason: "Mentions Eastshore Honda · from August 2025 · page 1"
)
let weaker = [
    Suggestion(item: item(6, "Documents/Travel/Lisbon 2023/itinerary.md", .document, days: 520), unit: Unit(kind: .text, locator: .chunk(0), text: ""),
               reason: "Related · from May 2024", snippet: "", score: 0.1, confidence: 0.02, features: features),
    Suggestion(item: item(7, "Downloads/receipt-117.pdf", .pdf, days: 330), unit: Unit(kind: .text, locator: .page(1), text: ""),
               reason: "Looks related · from November 2025 · page 1", snippet: "", score: 0.1, confidence: 0.01, features: features),
]

@MainActor func thumbnails() async {
    for s in suggestions + [cabin, invoice] + weaker {
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
    let glyphs: [(AppModel.Glyph, String)] = [
        (.idle, "Idle"), (.working, "Indexing"), (.found, "Found"),
        (.paused, "Paused"), (.needsSetup, "Needs setup"),
    ]
    render(VStack(spacing: 24) {
        Mark(size: 88)
        HStack(spacing: 24) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, entry in
                VStack(spacing: 12) {
                    Image(nsImage: GlyphImage.image(for: entry.0))
                        .renderingMode(.template)
                        .foregroundStyle(Theme.foreground)
                        .frame(width: 18, height: 18)
                    Text(entry.1).font(.system(size: 11)).foregroundStyle(Theme.foreground)
                        .frame(height: 28)
                }
                .frame(width: 64)
            }
        }
        MenuGlyph(found: 1, size: 48)
    }, "orbit", width: 440)
    let model = AppModel()
    var status = EngineStatus()
    status.ready = true
    status.counts.indexed = [.image: 2_413, .pdf: 611, .document: 3_982, .note: 214]

    model.showForSnapshot(.init(mode: .pull, bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Re: Kitchen — can you start on the 14th?", fingerprint: "x",
                                suggestions: suggestions, weaker: []), status: status)
    render(PanelView(model: model, close: {}), "panel-pull", width: 400)

    model.showForSnapshot(.init(mode: .ambient, bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Re: Kitchen — can you start on the 14th?", fingerprint: "x",
                                suggestions: Array(suggestions.prefix(2)), weaker: []), status: status)
    render(PanelView(model: model, close: {}), "panel-ambient", width: 400)

    model.showForSnapshot(.init(mode: .pull, bundleID: "com.apple.MobileSMS", appName: "Messages", windowTitle: "Joan (Pine Hollow)", fingerprint: "x",
                                suggestions: [cabin], weaker: weaker), status: status)
    render(PanelView(model: model, close: {}), "panel-line-wifi", width: 400)

    model.showForSnapshot(.init(mode: .pull, bundleID: "com.apple.Notes", appName: "Notes", windowTitle: "Car", fingerprint: "x",
                                suggestions: [invoice], weaker: weaker), status: status)
    render(PanelView(model: model, close: {}), "panel-line-invoice", width: 400)

    // Shortly before a made-up meeting at 2:00 PM today.
    let start = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
    let meeting = CalendarEvent(id: "demo", title: "Kitchen walkthrough with Dana Ruiz", start: start, end: start.addingTimeInterval(1_800),
                                attendees: [.init(name: "Dana Ruiz", email: "dana@ruizdaughters.example")])
    model.showForSnapshot(.init(mode: .ambient, bundleID: CalendarEvent.bundleID, appName: CalendarEvent.appName, windowTitle: meeting.title,
                                fingerprint: "x", suggestions: Array(suggestions.prefix(2)), weaker: [], meeting: meeting), status: status)
    render(PanelView(model: model, close: {}), "panel-meeting", width: 400)

    model.showForSnapshot(.init(mode: .pull, bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "NASA rover finds evidence of ancient lakebeds", fingerprint: "x",
                                suggestions: [], weaker: [suggestions[2]]), status: status)
    render(PanelView(model: model, close: {}), "panel-empty", width: 400)

    model.showForSnapshot(nil, status: status, trusted: false)
    render(PanelView(model: model, close: {}), "panel-setup", width: 400)

    for step in 0..<4 {
        UserDefaults.standard.set(step, forKey: "onboardingStep")
        render(OnboardingView(model: model, done: {}), "onboarding-\(step)", width: 560)
    }
    model.showDownloadForSnapshot(.init(phase: .downloading, received: 310_000_000, total: 914_469_773))
    for step in 0..<4 {
        UserDefaults.standard.set(step, forKey: "onboardingStep")
        render(OnboardingView(model: model, done: {}), "onboarding-download-\(step)", width: 560)
    }
    model.showForSnapshot(nil, status: nil)
    model.showDownloadForSnapshot(.init(phase: .failed, error: "Check your internet connection, then retry. Setup is saved."))
    render(PanelView(model: model, close: {}), "panel-download-retry", width: 400)
    model.showDownloadForSnapshot(.init(phase: .ready))
    UserDefaults.standard.removeObject(forKey: "onboardingStep")
    // The General pane alone: a TabView doesn't draw its tab bar offscreen.
    render(GeneralPane(model: model).frame(width: 560, height: 600), "settings-general", width: 560)
    let scenes: [(Illustration.Scene, String, [Double])] = [
        (.moment, "moment", [1.5, 3.4, 5.5]), (.notice, "notice", [1.5, 4.0]),
        (.gather, "gather", [1.0, 2.2, 4.5]), (.ready, "ready", [0.5, 4.0]),
    ]
    for (scene, name, times) in scenes {
        for time in times {
            render(Illustration(scene: scene, time: time).frame(width: 496), "illustration-\(name)-\(time)", width: 496)
        }
    }
    render(FullDiskAccessCard(close: {}), "full-disk-access-card", width: 300)
    print("Wrote snapshots to \(out.path)")
}

MainActor.assumeIsolated {
    Task { await run(); exit(0) }
}
RunLoop.main.run()
