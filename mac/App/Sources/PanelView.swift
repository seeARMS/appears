import AppKit
import AppearsCore
import PDFKit
import QuickLookThumbnailing
import SwiftUI

/// The panel that hangs from the menu bar ring: a header, up to three results as a ⌘K-style
/// list, and keyboard hints. shadcn's popover and command-list language (Theme.swift).
struct PanelView: View {
    @Bindable var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            content
            footer
        }
        .frame(width: 400)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.foreground)
                if let shown = model.shown, let subtitle = Self.subtitle(shown) {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if model.isPulling {
                ProgressView().controlSize(.small)
            } else if let count = model.shown?.suggestions.count, count > 0 {
                Badge(text: "\(count) found")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var headline: String {
        if model.isPulling, model.shown?.suggestions.isEmpty ?? true { return "Looking through your files…" }
        if model.shown?.mode == .ambient { return "Found something related" }
        return "Related"
    }

    /// "Re: Kitchen · Mail": the window's title without the app's name or a browser profile
    /// tacked on the end, then the app. For a meeting, why now: "For Kitchen walkthrough at 2:00 PM".
    static func subtitle(_ shown: AppModel.Shown) -> String? {
        if let meeting = shown.meeting {
            return "For \(meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)) at \(meeting.start.formatted(date: .omitted, time: .shortened))"
        }
        var title = shown.windowTitle
        let app = shown.appName
        if !app.isEmpty {
            for separator in [" - ", " — ", " – "] {
                if let range = title.range(of: separator + app) { title = String(title[..<range.lowerBound]) }
            }
        }
        title = title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty || title == app { return app.isEmpty ? nil : app }
        return app.isEmpty ? title : "\(title) · \(app)"
    }

    // MARK: - Content

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
                VStack(alignment: .leading, spacing: 6) {
                    Text(emptyText)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.mutedForeground)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 14)
                    if !shown.weaker.isEmpty { weaker(shown) }
                }
                .padding(4)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        ResultRow(suggestion: suggestion, selected: model.selectedIndex == index, model: model, close: close)
                    }
                    if !shown.weaker.isEmpty {
                        Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4).padding(.horizontal, -4)
                        weaker(shown)
                    }
                }
                .padding(4)
            }
        }
    }

    private var emptyText: String {
        if let status = model.status, status.counts.indexedTotal == 0 {
            return "Still reading your files. Try again in a little while."
        }
        return "Nothing you've forgotten about this."
    }

    @ViewBuilder
    private func weaker(_ shown: AppModel.Shown) -> some View {
        Button {
            model.showWeaker.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.showWeaker ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                Text("Less likely (\(shown.weaker.count))")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.mutedForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if model.showWeaker {
            ForEach(Array(shown.weaker.enumerated()), id: \.element.id) { index, suggestion in
                ResultRow(suggestion: suggestion, selected: model.selectedIndex == shown.suggestions.count + index, model: model, close: close)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let status = model.status, status.progress.phase == .indexing || status.progress.phase == .scanning {
                Text(status.progress.phase == .scanning ? "Looking through your files…" : "Indexing \(status.progress.done.formatted()) of \(status.progress.total.formatted())…")
            } else if let status = model.status, status.progress.phase == .paused, let reason = status.progress.pausedReason {
                Text("Indexing paused: \(reason)")
            } else if model.settings.isPaused {
                Text("Paused")
            } else if model.selected?.line != nil {
                hint("↩", "open")
                hint("⌥⌘C", "copy line")
                hint("␣", "preview")
                hint("⌫", "not useful")
            } else {
                hint("↩", "open")
                hint("␣", "preview")
                hint("⌫", "not useful")
                Spacer(minLength: 0)
                Text("or drag into anything")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.mutedForeground)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Kbd(key: key)
            Text(label)
        }
    }
}

private struct Message: View {
    let title: String
    let text: String
    let action: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.foreground)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.mutedForeground).fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.0, action: action.1).buttonStyle(PrimaryButtonStyle()).padding(.top, 6)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One result, as a row in a command list: a thumbnail, the name, why it's here, and (when
/// selected) the matching text.
struct ResultRow: View {
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
        HStack(alignment: .top, spacing: 10) {
            preview
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.item.source == .notes ? suggestion.item.title : suggestion.item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                reasonText
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                if selected, let line = suggestion.line {
                    QuotedLine(line: line).padding(.top, 4)
                } else if selected, !suggestion.snippet.isEmpty {
                    Text(suggestion.snippet)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            .frame(minHeight: 40, alignment: .center)
            Spacer(minLength: 0)
            trailing
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(selected || hovering ? Theme.muted : Color.clear)
        )
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

    /// The why ("Mentions Dana Ruiz") in the foreground colour; when and where muted.
    private var reasonText: Text {
        var parts = suggestion.reason.components(separatedBy: " · ")
        if suggestion.item.source == .notes { parts.insert("Notes", at: min(1, parts.count)) }
        let first = parts.first ?? ""
        let generic = first == "Related" || first == "Looks related"
        let why = Text(first).foregroundStyle(generic ? Theme.mutedForeground : Theme.foreground)
        guard parts.count > 1 else { return why }
        return Text("\(why)\(Text(" · " + parts.dropFirst().joined(separator: " · ")).foregroundStyle(Theme.mutedForeground))")
    }

    @ViewBuilder
    private var trailing: some View {
        if hovering {
            HStack(spacing: 2) {
                Button { model.act(.dismissed, on: suggestion) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mutedForeground)
                .help("Not useful")
                Menu {
                    Button("Not useful") { model.act(.dismissed, on: suggestion) }
                    Button("Never show this") { model.act(.blocked, on: suggestion) }
                    Button(model.shown?.meeting == nil ? "Not in this app" : "Not before meetings") { model.act(.muted, on: suggestion) }
                    Divider()
                    if let line = suggestion.line {
                        Button("Copy Line") {
                            line.copyToPasteboard()
                            model.act(.copiedLine, on: suggestion)
                        }
                    }
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
                .frame(width: 22, height: 22)
                .foregroundStyle(Theme.mutedForeground)
            }
            .frame(minHeight: 40)
        } else if selected {
            Kbd(key: "↩").frame(minHeight: 40)
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.muted)
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.mutedForeground)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var icon: String {
        switch suggestion.item.kind {
        case .note: "note.text"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .document: "doc.text"
        }
    }
}

/// The line that answers, quoted from the file on a card inset into the selected row: the
/// label muted, the answer in the foreground.
struct QuotedLine: View {
    let line: MatchedLine

    var body: some View {
        Text(attributed)
            .lineSpacing(2)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.kbdBorder, lineWidth: 1))
            .accessibilityLabel(line.text)
    }

    private var attributed: AttributedString {
        line.segments.reduce(into: AttributedString()) { string, segment in
            var run = AttributedString(segment.text)
            run.font = .system(size: 12, weight: segment.emphasized ? .semibold : .regular)
            run.foregroundColor = segment.emphasized ? Theme.foreground : Theme.mutedForeground
            string += run
        }
    }
}

extension MatchedLine {
    /// Puts the line on the clipboard. A password or a code goes with the concealed type
    /// (nspasteboard.org), so clipboard managers leave it out of their history.
    func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if concealed { pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
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
            return pdfPage.thumbnail(of: NSSize(width: 80, height: 80), for: .mediaBox)
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 40, height: 40), scale: 2, representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
