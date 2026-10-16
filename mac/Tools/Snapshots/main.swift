import AppKit
import AppearsContext
import AppearsCore
import AppearsMessages
import PDFKit
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
               reason: "Related · from May 2025 · page 3", snippet: "Interior kitchen remodel. Replace cabinets and countertops, relocate sink 3 feet, add six (6) 20-amp GFCI outlets…",
               score: 0.7, confidence: 0.75, features: features),
    Suggestion(item: item(3, "Documents/House/Kitchen measurements.md", .document, days: 530), unit: Unit(kind: .text, locator: .chunk(0), text: ""),
               reason: "Related · from April 2025", snippet: "Back wall: 11' 4\" (sink wall). Window: 36\" wide, sill at 42\". Dana said the outlet by the window has to move for code",
               score: 0.4, confidence: 0.02, features: features),
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

/// Exercise the actual native scroll view in an offscreen fixture window. No user files,
/// permissions, or desktop windows are involved.
@MainActor func verifyScrolling(_ model: AppModel, status: EngineStatus) async {
    let paths = ["Downloads/Fernway order FW-88310.pdf", "Downloads/EOB-Delta-Dental-2025-03.pdf",
                 "Documents/Taxes/2024/1099-INT-Harbor-Credit-Union.pdf"]
    let extra = paths.enumerated().map { index, path in
        let text = PDFDocument(url: demo.appending(path: path))?.string ?? ""
        return Suggestion(item: item(Int64(20 + index), path, .pdf, days: 400),
                          unit: Unit(kind: .text, locator: .page(1), text: text),
                          reason: "Related · from May 2025 · page 1", snippet: String(text.prefix(160)),
                          score: 0.01, confidence: 0.01, features: features)
    }
    let ten = suggestions + [invoice, cabin] + weaker + extra
    precondition(ten.count == AppModel.contextResultLimit)
    let policy = SurfacePolicy()
    let ambient = AppModel.ambientPanelSuggestions(ten, isConfident: policy.isConfident)
    precondition(ambient.count == 10 && ambient.prefix(2).map(\.id) == [suggestions[0].id, suggestions[1].id])
    precondition(AppModel.ambientPanelSuggestions(weaker + extra + suggestions, isConfident: policy.isConfident).isEmpty,
                 "A strong result outside the first three must not trigger the ambient dot")
    var deduplication = SurfacePolicy()
    deduplication.didSurface(itemIDs: [suggestions[0].item.id], topic: "fixture")
    let novel = AppModel.ambientPanelSuggestions(ten, isConfident: policy.isConfident) {
        deduplication.maySuggest(itemID: $0.item.id, topic: "fixture")
    }
    precondition(!novel.isEmpty && !novel.contains { $0.item.id == suggestions[0].item.id },
                 "A different confident item can signal in the same conversation without repeating the first")
    deduplication.didSurface(itemIDs: suggestions.map { $0.item.id }, topic: "fixture")
    precondition(AppModel.ambientPanelSuggestions(ten, isConfident: policy.isConfident) {
        deduplication.maySuggest(itemID: $0.item.id, topic: "fixture")
    }.isEmpty, "Previously shown leading candidates cannot be replaced by a confident tail result to bypass the gate")
    model.showForSnapshot(.init(mode: .pull, appName: "Mail", windowTitle: "Related files", fingerprint: "scroll",
                                suggestions: ten, evidenceTerms: ["Dana", "Ruiz", "outlet", "cabinets"]), status: status)
    let host = NSHostingView(rootView: PanelView(model: model, close: {}).environment(\.colorScheme, .light))
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    func settle() async {
        for _ in 0..<4 {
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let scroll = scrollView(in: child) { return scroll } }
        return nil
    }
    await settle()
    guard let scroll = scrollView(in: host), let document = scroll.documentView else {
        preconditionFailure("The results must use a native scrolling list")
    }
    precondition(document.frame.height > scroll.contentView.bounds.height)
    precondition(host.fittingSize.height <= 560, "The list must keep the panel compact")
    let top = scroll.contentView.bounds.origin.y
    render(PanelView(model: model, close: {}), "panel-ten-results", width: 400)
    model.moveSelection(9)
    await settle()
    precondition(model.selected?.id == ten.last?.id)
    precondition(scroll.contentView.bounds.origin.y > top + 1, "Arrow navigation must reveal the tenth result")
    model.moveSelection(1)
    await settle()
    precondition(model.selected?.id == ten.first?.id)
    // scrollTo uses the row's edge, inside the list's six-point content padding.
    precondition(scroll.contentView.bounds.origin.y <= top + 12, "Wrapping must reveal the first result")
    model.moveSelection(-1)
    await settle()
    precondition(model.selected?.id == ten.last?.id)
    model.act(.dismissed, on: ten.last!)
    await settle()
    precondition(model.selectedIndex == 8 && model.visibleSuggestions.count == 9)
    window.close()
    print("Verified ten results, original ambient gate, bounded height, scrolling to selection, wraparound and dismissal")
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
    render(HStack(spacing: 30) {
        ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { confidence in
            VStack(spacing: 10) {
                ConfidenceRing(confidence: confidence, size: 28)
                Text(confidence, format: .number.precision(.fractionLength(2)))
                    .font(.system(size: 11)).foregroundStyle(Theme.mutedForeground)
            }
        }
    }, "confidence-ring", width: 400)
    let model = AppModel()
    // Made-up contact results exercise both lists, including a photo, initials and
    // an unknown address. Never open the user's Contacts or chat.db.
    let avatar = NSImage(size: NSSize(width: 80, height: 80), flipped: false) { rect in
        NSColor(calibratedRed: 0.3, green: 0.5, blue: 0.7, alpha: 1).setFill()
        rect.fill()
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: 27, y: 39, width: 26, height: 26)).fill()
        NSBezierPath(ovalIn: NSRect(x: 13, y: -17, width: 54, height: 54)).fill()
        return true
    }
    let contactFixture = MessageContacts(people: [
        .init(id: "dana", name: "Dana Ruiz", addresses: ["+14155550142"], photo: avatar.tiffRepresentation),
        .init(id: "joan", name: "Joan Lee", addresses: ["joan@example.test"]),
    ])
    let contactModel = AppModel(contacts: ContactDirectory(snapshot: contactFixture))
    let contactResults = ["+14155550142", "joan@example.test", "+14155550149"].enumerated().map { index, address in
        let item = Item(id: Int64(101 + index), source: .messages, path: "messages:\(index)", kind: .message,
                        title: address, size: 30, created: Date(), modified: Date(), lastUsed: nil,
                        message: .init(rowID: Int64(index), guid: "fixture-\(index)", chatID: Int64(index), conversationURL: nil))
        return Suggestion(item: item, unit: Unit(kind: .text, locator: .whole, text: "Me: The kitchen quote includes moving the outlet."),
                          reason: "Related · from October 2026", snippet: "Me: The kitchen quote includes moving the outlet.",
                          score: 1, confidence: 0.8, features: features)
    }
    var contactStatus = EngineStatus()
    contactStatus.ready = true
    contactModel.showForSnapshot(.init(mode: .pull, appName: "Messages", windowTitle: "Kitchen", fingerprint: "fixture",
                                       suggestions: contactResults, evidenceTerms: ["quote"]), status: contactStatus)
    render(PanelView(model: contactModel, close: {}), "panel-contacts", width: 400)
    contactModel.sourcePreview = contactResults[0]
    render(PanelView(model: contactModel, close: {}), "panel-contact-preview", width: 400)
    contactModel.sourcePreview = nil
    let contactSearch = SearchModel(app: contactModel)
    contactSearch.showForSnapshot(query: "kitchen quote", results: contactResults)
    render(SearchView(model: contactSearch, close: {}, finish: {}, openSettings: {}, resize: { _ in }), "search-contacts", width: 640)
    contactSearch.sourcePreview = contactResults[0]
    render(SearchView(model: contactSearch, close: {}, finish: {}, openSettings: {}, resize: { _ in }), "search-contact-preview", width: 640)
    var status = EngineStatus()
    status.ready = true
    status.protectedFoldersReadable = true
    status.notesReadable = true
    status.messagesReadable = true
    status.watchedFolders = [demo.path]
    status.sources = [
        SourceStatus(source: .file, indexed: 7_006, lastChecked: Date().addingTimeInterval(-180)),
        SourceStatus(source: .notes, indexed: 214, lastChecked: Date().addingTimeInterval(-120)),
        SourceStatus(source: .messages, indexed: 2_100, lastChecked: Date().addingTimeInterval(-30)),
    ]
    status.counts.indexed = [.image: 2_413, .pdf: 611, .document: 3_982, .note: 214, .message: 2_100]

    model.showForSnapshot(.init(mode: .pull, bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Re: Kitchen — can you start on the 14th?", fingerprint: "x",
                                suggestions: suggestions, evidenceTerms: ["Dana", "Ruiz", "kitchen", "outlet", "cabinets", "countertops"]), status: status)
    render(PanelView(model: model, close: {}), "panel-pull", width: 400)
    // The lowest-confidence candidate is visible and reachable without a disclosure.
    precondition(model.visibleSuggestions.count == 3)
    model.moveSelection(2)
    precondition(model.selected?.id == suggestions[2].id)
    render(PanelView(model: model, close: {}), "panel-evidence", width: 400)
    model.act(.dismissed, on: suggestions[2])
    precondition(model.selectedIndex == 1 && model.selected?.id == suggestions[1].id)

    model.showForSnapshot(.init(mode: .pull, bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Re: Kitchen — can you start on the 14th?", fingerprint: "x",
                                suggestions: [suggestions[2]], evidenceTerms: ["Dana", "outlet"]), status: status)
    precondition(model.selected?.id == suggestions[2].id)
    render(PanelView(model: model, close: {}), "panel-low-confidence", width: 400)

    await verifyScrolling(model, status: status)

    model.showForSnapshot(.init(mode: .ambient, bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Re: Kitchen — can you start on the 14th?", fingerprint: "x",
                                suggestions: Array(suggestions.prefix(2)), evidenceTerms: ["Ruiz", "kitchen", "outlets"]), status: status)
    render(PanelView(model: model, close: {}), "panel-ambient", width: 400)

    model.showForSnapshot(.init(mode: .pull, bundleID: "com.apple.MobileSMS", appName: "Messages", windowTitle: "Joan (Pine Hollow)", fingerprint: "x",
                                suggestions: [cabin] + weaker), status: status)
    render(PanelView(model: model, close: {}), "panel-line-wifi", width: 400)

    model.showForSnapshot(.init(mode: .pull, bundleID: "com.apple.Notes", appName: "Notes", windowTitle: "Car", fingerprint: "x",
                                suggestions: [invoice] + weaker), status: status)
    render(PanelView(model: model, close: {}), "panel-line-invoice", width: 400)

    // Shortly before a made-up meeting at 2:00 PM today.
    let start = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
    let meeting = CalendarEvent(id: "demo", title: "Kitchen walkthrough with Dana Ruiz", start: start, end: start.addingTimeInterval(1_800),
                                attendees: [.init(name: "Dana Ruiz", email: "dana@ruizdaughters.example")])
    model.showForSnapshot(.init(mode: .ambient, bundleID: CalendarEvent.bundleID, appName: CalendarEvent.appName, windowTitle: meeting.title,
                                fingerprint: "x", suggestions: Array(suggestions.prefix(2)), evidenceTerms: ["Ruiz", "kitchen", "outlets"], meeting: meeting), status: status)
    render(PanelView(model: model, close: {}), "panel-meeting", width: 400)

    model.showForSnapshot(.init(mode: .pull, bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "NASA rover finds evidence of ancient lakebeds", fingerprint: "x",
                                suggestions: []), status: status)
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
    model.showForSnapshot(nil, status: status)
    render(SourcesPane(model: model).frame(width: 560, height: 600), "settings-sources", width: 560)
    render(UpdatesPane(updater: model.updater).frame(width: 560, height: 600), "settings-updates", width: 560)
    verifyLaunchBehavior()
    await verifySearchUpdates(model, suggestions: suggestions)
    let search = SearchModel(app: model)
    func searchSnapshot(_ name: String) {
        render(SearchView(model: search, close: {}, finish: {}, openSettings: {}, resize: { _ in }), name, width: 640)
    }
    searchSnapshot("search-empty")
    search.showForSnapshot(query: "the quote for the kitchen", results: suggestions)
    searchSnapshot("search-results")
    search.showForSnapshot(query: "the kitchen permit", results: suggestions, searching: true)
    searchSnapshot("search-updating")
    let noteItem = Item(id: 101, source: .notes, path: "notes:demo-kitchen", kind: .note, title: "Kitchen measurements",
                        size: 120, created: Date().addingTimeInterval(-520 * 86_400), modified: Date(), lastUsed: nil)
    let note = Suggestion(item: noteItem, unit: Unit(kind: .text, locator: .chunk(0), text: "Back wall: 11′ 4″ (sink wall).\nWindow: 36″ wide, sill at 42″.\n\nDana said the outlet by the window has to move for code. Ask whether that work is included in the quote."),
                          reason: "Mentions Dana", snippet: "Dana said the outlet by the window has to move for code.", score: 1, confidence: 0.9, features: features)
    let messageItem = Item(id: 102, source: .messages, path: "messages:demo", kind: .message, title: "Dana Ruiz",
                           size: 100, created: Date().addingTimeInterval(-500 * 86_400), modified: Date(), lastUsed: nil)
    let message = Suggestion(item: messageItem, unit: Unit(kind: .text, locator: .whole, text: "Me: Does the kitchen quote include moving the outlet?\nDana: Yes, moving the outlet by the window is included. The permit covers that work too.\nMe: Great, thank you. I’ll keep the quote with the permit."),
                             reason: "Mentions outlet", snippet: "Moving the outlet is included.", score: 1, confidence: 0.9, features: features)
    for (suggestion, name) in [(note, "note"), (message, "message")] {
        search.showForSnapshot(query: "does the quote include the outlet", results: [suggestion])
        search.toggleSourcePreview()
        precondition(search.sourcePreview?.id == suggestion.id)
        searchSnapshot("search-preview-\(name)")
        render(SourcePreviewView(suggestion: suggestion, back: {}, open: {}).frame(width: 400), "preview-\(name)", width: 400)
        search.clear()
        precondition(search.sourcePreview == nil)
    }
    search.showForSnapshot(query: "does the kitchen quote include the outlet", results: [note, message], searching: true)
    searchSnapshot("search-updating")
    var partial = status
    partial.progress.phase = .indexing
    partial.counts.waiting = 3_200
    partial.sources[0].waiting = 3_200
    partial.notesReadable = false
    partial.messagesReadable = false
    model.showForSnapshot(nil, status: partial)
    precondition(model.readinessDetail.contains("left to index"))
    render(SourcesPane(model: model).frame(width: 560, height: 600), "settings-sources-indexing", width: 560)
    search.showForSnapshot(query: "our trip", results: [])
    searchSnapshot("search-partial-index")
    // An existing index can predate scan-date metadata. A missing date must not
    // claim that these searchable items are waiting for their first scan.
    var queued = status
    queued.sources[2].lastChecked = nil
    queued.sources[2].waiting = 42
    queued.counts.waiting = 42
    model.showForSnapshot(nil, status: queued)
    precondition(model.readinessTitle == "Items queued for indexing")
    precondition(model.readinessDetail.contains("queued to index") && model.readinessDetail.contains("every minute"))
    render(SourcesPane(model: model).frame(width: 560, height: 600), "settings-sources-queued", width: 560)
    var paused = status
    paused.progress.phase = .paused
    paused.progress.pausedReason = "Low Power Mode"
    model.showForSnapshot(nil, status: paused)
    precondition(model.readinessTitle == "Indexing paused" && model.readinessDetail == "Low Power Mode")
    render(ReadinessView(model: model, details: true).padding(16).frame(width: 400), "source-health-paused", width: 400)
    var failed = status
    failed.error = "Couldn’t check changed files. Use Scan now in Sources to retry."
    model.showForSnapshot(nil, status: failed)
    precondition(model.readinessTitle == "Index needs attention")
    render(ReadinessView(model: model, details: true).padding(16).frame(width: 400), "source-health-error", width: 400)
    var empty = status
    empty.counts = IndexCounts()
    empty.sources = [SourceStatus(source: .file, lastChecked: Date())]
    model.showForSnapshot(nil, status: empty)
    precondition(model.readinessTitle == "No items indexed yet")
    render(ReadinessView(model: model, details: true).padding(16).frame(width: 400), "source-health-empty", width: 400)
    model.showForSnapshot(nil, status: status)
    search.showForSnapshot(query: "the wifi password at the cabin", results: [cabin])
    searchSnapshot("search-answer")
    search.showForSnapshot(query: "our trip to Lisbon", results: [], searching: true)
    searchSnapshot("search-loading")
    search.showForSnapshot(query: "our trip to Lisbon", results: [])
    searchSnapshot("search-no-results")
    search.showForSnapshot(query: "our trip to Lisbon", results: [], error: "Couldn't search your index. Try again, or check Sources in Settings.")
    searchSnapshot("search-error")
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
