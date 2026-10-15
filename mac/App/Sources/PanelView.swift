import AppKit
import AppearsCore
import PDFKit
import QuickLookThumbnailing
import SwiftUI

/// Appears' palette (brand/README.md): warm paper, ink, one vermilion signal.
enum Theme {
    static let paper = Color(light: 0xF7F4EE, dark: 0x1B1A18)
    static let card = Color(light: 0xFFFDF9, dark: 0x24221F)
    static let ink = Color(light: 0x17150F, dark: 0xEDE8DE)
    static let muted = Color(light: 0x6B655A, dark: 0x9A9387)
    static let rule = Color(light: 0xDCD6CA, dark: 0x34302B)
    static let signal = Color(light: 0xE0531F, dark: 0xFF6A33)
    static let serif = Font.system(size: 15, weight: .regular, design: .serif)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        })
    }
}

struct PanelView: View {
    @Bindable var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.rule).frame(height: 1)
            content
            footer
        }
        .frame(width: 400)
        .background(Theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.shown?.mode == .ambient ? "You might want these" : "You already have")
                    .font(Theme.serif)
                    .foregroundStyle(Theme.ink)
                if let shown = model.shown, !shown.windowTitle.isEmpty || !shown.appName.isEmpty {
                    Text("For \(shown.windowTitle.isEmpty ? shown.appName : shown.windowTitle)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer()
            if model.isPulling {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if !model.accessibilityTrusted {
            Message(
                title: "Appears needs Accessibility",
                text: "It reads the window you're in, in memory, to know what's related. Nothing is stored or sent anywhere.",
                action: ("Open Settings", { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) })
            )
        } else if let reason = model.skippedReason, model.shown == nil {
            Message(title: "Not here", text: reason, action: nil)
        } else if let error = model.pullError {
            Message(title: "Couldn't look", text: error, action: nil)
        } else if let shown = model.shown {
            if shown.suggestions.isEmpty, !model.isPulling {
                VStack(alignment: .leading, spacing: 10) {
                    Text(emptyText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                    if !shown.weaker.isEmpty { weaker(shown) }
                }
                .padding(16)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(shown.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        ResultCard(suggestion: suggestion, selected: model.selectedIndex == index, model: model, close: close)
                    }
                    if !shown.weaker.isEmpty { weaker(shown) }
                }
                .padding(10)
            }
        }
    }

    private var emptyText: String {
        if let status = model.status, status.counts.indexedTotal == 0 {
            return "Appears is still reading your files. Try again in a little while."
        }
        return "Nothing you've forgotten about this."
    }

    @ViewBuilder
    private func weaker(_ shown: AppModel.Shown) -> some View {
        DisclosureGroup(isExpanded: $model.showWeaker) {
            VStack(spacing: 6) {
                ForEach(Array(shown.weaker.enumerated()), id: \.element.id) { index, suggestion in
                    ResultCard(suggestion: suggestion, selected: model.selectedIndex == shown.suggestions.count + index, model: model, close: close)
                        .opacity(0.8)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Less likely (\(shown.weaker.count))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 6)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let status = model.status, status.progress.phase == .indexing || status.progress.phase == .scanning {
                Text(status.progress.phase == .scanning ? "Looking through your files…" : "Reading \(status.progress.done.formatted()) of \(status.progress.total.formatted())…")
            } else if let status = model.status, status.progress.phase == .paused, let reason = status.progress.pausedReason {
                Text("Indexing paused: \(reason)")
            } else if model.settings.isPaused {
                Text("Paused")
            } else {
                Text("↩ open · space preview · ⌫ not useful · drag into anything")
            }
            Spacer()
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.card.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }
}

private struct Message: View {
    let title: String
    let text: String
    let action: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.0, action: action.1).padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One suggestion: a preview, its name, why it's here, and what you can do with it.
struct ResultCard: View {
    let suggestion: Suggestion
    let selected: Bool
    let model: AppModel
    let close: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    init(suggestion: Suggestion, selected: Bool, model: AppModel, close: @escaping () -> Void) {
        self.suggestion = suggestion
        self.selected = selected
        self.model = model
        self.close = close
        _thumbnail = State(initialValue: Thumbnails.cache[suggestion.item.id])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            preview
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                reasonText
                    .font(.system(size: 11))
                    .lineLimit(1)
                if !suggestion.snippet.isEmpty {
                    Text(suggestion.snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if hovering || selected {
                VStack(spacing: 4) {
                    iconButton("xmark", help: "Not useful") { model.act(.dismissed, on: suggestion) }
                    Menu {
                        Button("Not useful") { model.act(.dismissed, on: suggestion) }
                        Button("Never show this") { model.act(.blocked, on: suggestion) }
                        Button("Not in this app") { model.act(.muted, on: suggestion) }
                        Divider()
                        if suggestion.item.source == .file {
                            Button("Show in Finder") { model.act(.revealed, on: suggestion); close() }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(suggestion.item.path, forType: .string)
                                model.act(.copied, on: suggestion)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 10, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 18)
                    .foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 1).fill(Theme.signal).frame(width: 2).padding(.vertical, 10)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.rule.opacity(selected ? 1 : 0.6), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            model.act(.opened, on: suggestion)
            close()
        }
        .onDrag {
            model.act(.dragged, on: suggestion)
            if suggestion.item.source == .file, let provider = NSItemProvider(contentsOf: URL(filePath: suggestion.item.path)) {
                return provider
            }
            return NSItemProvider(object: suggestion.snippet as NSString)
        }
        .help(suggestion.item.source == .file ? suggestion.item.path : "Apple Notes")
        .task(id: suggestion.id) { thumbnail = await Thumbnails.image(for: suggestion) }
    }

    /// The why ("Mentions Dana Ruiz") in the signal colour; when and where in grey.
    private var reasonText: Text {
        let parts = suggestion.reason.components(separatedBy: " · ")
        let first = parts.first ?? ""
        let generic = first == "Related" || first == "Looks related"
        let why = Text(first).foregroundStyle(generic ? Theme.muted : Theme.signal)
        guard parts.count > 1 else { return why }
        return Text("\(why)\(Text(" · " + parts.dropFirst().joined(separator: " · ")).foregroundStyle(Theme.muted))")
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.paper)
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.muted)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
    }

    private var icon: String {
        switch suggestion.item.kind {
        case .note: "note.text"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .document: "doc.text"
        }
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 10, weight: .semibold)) }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .frame(width: 18, height: 18)
            .help(help)
    }
}

/// Thumbnails: the matching PDF page, else Quick Look's thumbnail. Notes get an icon.
enum Thumbnails {
    /// Pre-rendered thumbnails (the snapshot tool fills it, since ImageRenderer can't wait).
    nonisolated(unsafe) static var cache: [Int64: NSImage] = [:]

    static func image(for suggestion: Suggestion) async -> NSImage? {
        if let cached = cache[suggestion.item.id] { return cached }
        guard suggestion.item.source == .file, !suggestion.item.metadataOnly else { return nil }
        let url = URL(filePath: suggestion.item.path)
        if suggestion.item.kind == .pdf, let page = suggestion.unit.locator.page,
           let document = PDFDocument(url: url), let pdfPage = document.page(at: page - 1) {
            return pdfPage.thumbnail(of: NSSize(width: 104, height: 104), for: .mediaBox)
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 52, height: 52), scale: 2, representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
