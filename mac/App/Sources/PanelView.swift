import AppKit
import AppearsCore
import PDFKit
import QuickLookThumbnailing
import SwiftUI

/// The panel that hangs from the menu bar ring: a header, up to ten results in a bounded
/// scrolling list, and fixed keyboard hints. shadcn's command-list language (Theme.swift).
struct PanelView: View {
    @Bindable var model: AppModel
    let close: () -> Void
    var openSources: () -> Void = {}
    var openSearch: () -> Void = {}
    var resize: (CGSize) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            content
            if showsFooter { footer }
        }
        .frame(width: 400)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: resize)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(headline)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.foreground)
                .layoutPriority(1)
            if let shown = model.shown, let subtitle = Self.subtitle(shown) {
                HStack(spacing: 5) {
                    if shown.meeting == nil, let icon = Self.appIcon(shown.bundleID) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    } else if shown.meeting != nil {
                        Image(systemName: "calendar").font(.system(size: 11))
                    }
                    Text(subtitle).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedForeground)
                .help(shown.meeting == nil ? "\(shown.windowTitle) · \(shown.appName)" : subtitle)
            }
            Spacer(minLength: 4)
            if model.isPulling { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    /// The front app's icon, which says which app this is about without spelling it out.
    static func appIcon(_ bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var headline: String {
        if model.isPulling, model.shown?.suggestions.isEmpty ?? true { return "Looking through your files…" }
        if model.shown?.mode == .ambient { return "Found something related" }
        return "Related"
    }

    /// "Re: Kitchen": the window's title without the app's name tacked on the end (the app's
    /// icon sits before it), or the app's name when that's all there is. For a meeting, why
    /// now, time first so it survives truncation: "2:00 PM · Kitchen walkthrough".
    static func subtitle(_ shown: AppModel.Shown) -> String? {
        if let meeting = shown.meeting {
            return "\(meeting.start.formatted(date: .omitted, time: .shortened)) · \(meeting.title.trimmingCharacters(in: .whitespacesAndNewlines))"
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
        return shown.bundleID.isEmpty && !app.isEmpty ? "\(title) · \(app)" : title
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
        } else if model.modelDownload.phase != .ready {
            ModelDownloadView(status: model.modelDownload, retry: model.retryModelDownload).padding(14)
        } else if let reason = model.skippedReason, model.shown == nil {
            Message(title: "Not here", text: reason, action: nil)
        } else if let error = model.pullError {
            Message(title: "Couldn't look", text: error, action: nil)
        } else if let preview = model.sourcePreview {
            SourcePreviewView(suggestion: preview, back: { model.sourcePreview = nil }) {
                model.act(.opened, on: preview); close()
            }
        } else if model.status?.ready != true || model.status?.error != nil || model.engineStatusError != nil {
            ReadinessView(model: model, openSources: openSources).padding(16)
        } else if let shown = model.shown {
            if shown.suggestions.isEmpty, !model.isPulling {
                VStack(alignment: .leading, spacing: 10) {
                    Text(emptyText).font(.system(size: 13)).foregroundStyle(Theme.mutedForeground)
                    if let missing = model.missingSourceAccess {
                        Text(missing).font(.system(size: 12)).foregroundStyle(Theme.mutedForeground)
                    }
                    HStack {
                        Button("Search instead", action: openSearch).buttonStyle(OutlineButtonStyle())
                        Button("View sources", action: openSources).buttonStyle(OutlineButtonStyle())
                    }
                }
                .padding(16)
            } else if shown.suggestions.isEmpty {
                Color.clear.frame(height: 40)
            } else {
                RelatedResultsList(model: model, suggestions: shown.suggestions, close: close)
                    .id(shown.at)
            }
        }
    }

    private var emptyText: String {
        if let status = model.status, status.counts.indexedTotal == 0 {
            return "Still reading your files. Try again in a little while."
        }
        if let progress = model.status?.progress, progress.phase == .scanning || progress.phase == .indexing {
            return "No close matches yet. Still reading your files."
        }
        return "No close matches for this window."
    }

    // MARK: - Footer

    /// The footer carries indexing status or the keys for a list; with neither, it goes.
    private var showsFooter: Bool {
        if let progress = model.status?.progress,
           progress.phase == .indexing || progress.phase == .scanning || (progress.phase == .paused && progress.pausedReason != nil) { return true }
        return model.settings.isPaused || hasRows
    }

    private var hasRows: Bool {
        model.shown?.suggestions.isEmpty == false
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.sourcePreview != nil {
                hint("esc", "back")
                Spacer(minLength: 0)
                hint("↩", "open")
            } else if let status = model.status, status.progress.phase == .indexing || status.progress.phase == .scanning {
                Text(status.progress.phase == .scanning ? "Looking through your files…" : "Indexing \(status.progress.done.formatted()) of \(status.progress.total.formatted())…")
            } else if let status = model.status, status.progress.phase == .paused, let reason = status.progress.pausedReason {
                Text("Indexing paused: \(reason)")
            } else if model.settings.isPaused {
                Text("Paused")
            } else if hasRows {
                hint("↩", "open")
                if model.selected?.line != nil { hint("⌥⌘C", "copy") } else { hint("␣", "preview") }
                Spacer(minLength: 0)
                hint("⌫", "hide")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 11))
        .lineLimit(1)
        .foregroundStyle(Theme.mutedForeground)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Theme.muted.opacity(0.5))
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Kbd(key: key)
            Text(label)
        }
        .fixedSize()
    }
}

/// Eagerly lay out at most ten rows so short lists keep their natural height. Longer lists
/// show roughly five rows; keyboard movement scrolls just enough to reveal the selection.
private struct RelatedResultsList: View {
    @Bindable var model: AppModel
    let suggestions: [Suggestion]
    let close: () -> Void
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        ResultRow(suggestion: suggestion, selected: model.selectedIndex == index, model: model, close: close)
                            .id(suggestion.id)
                    }
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .scrollIndicators(.visible)
            .frame(height: min(contentHeight ?? CGFloat(suggestions.count) * 96 + 12, 480))
            .onAppear {
                if let selected = model.selected { proxy.scrollTo(selected.id) }
            }
            .onChange(of: model.selected?.id) { _, id in
                if let id { proxy.scrollTo(id) }
            }
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
    private let evidence: SuggestionEvidence
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    init(suggestion: Suggestion, selected: Bool, model: AppModel, close: @escaping () -> Void) {
        self.suggestion = suggestion
        self.selected = selected
        self.model = model
        self.close = close
        evidence = SuggestionEvidence(suggestion, terms: model.shown?.evidenceTerms ?? [])
        _thumbnail = State(initialValue: Thumbnails.cache[suggestion.item.id])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            preview
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(suggestion.item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    ConfidenceRing(confidence: suggestion.confidence)
                }
                if !evidence.segments.isEmpty {
                    evidenceText
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.foreground)
                        .lineSpacing(1.5)
                        .lineLimit(3)
                }
                if selected, let line = suggestion.line {
                    QuotedLine(line: line).padding(.top, 5)
                }
                HStack(spacing: 4) {
                    if !evidence.metadata.isEmpty {
                        Text(evidence.metadata)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.mutedForeground)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    trailing
                }
                .frame(height: 22)
            }
            .frame(minHeight: 36, alignment: .center)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
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
            if let url = suggestion.item.fileURL, let provider = NSItemProvider(contentsOf: url) {
                return provider
            }
            return NSItemProvider(object: suggestion.snippet as NSString)
        }
        .help(suggestion.item.fileURL.map { "\($0.path)\nDrag it into anything." } ?? (suggestion.item.source == .messages ? "Messages" : "Apple Notes"))
        .task(id: suggestion.id) { thumbnail = await Thumbnails.image(for: suggestion) }
    }

    /// Quote the retrieved source, with matching terms emphasized. A specific name match
    /// remains useful when there is no clean passage; visual-only matches use the thumbnail.
    private var evidenceText: Text {
        var content = AttributedString(evidence.isQuotation ? "“" : "")
        for segment in evidence.segments {
            var run = AttributedString(segment.text)
            run.font = .system(size: 12, weight: segment.emphasized ? .semibold : .regular)
            content += run
        }
        if evidence.isQuotation { content += AttributedString("”") }
        return Text(content)
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
                    if suggestion.item.fileURL == nil {
                        Button("Preview passage") {
                            model.selectedIndex = model.visibleSuggestions.firstIndex { $0.id == suggestion.id } ?? model.selectedIndex
                            model.sourcePreview = suggestion
                            model.act(.previewed, on: suggestion)
                        }
                    }
                    if let line = suggestion.line {
                        Button("Copy Line") {
                            line.copyToPasteboard()
                            model.act(.copiedLine, on: suggestion)
                        }
                    }
                    if let url = suggestion.item.fileURL {
                        Button("Show in Finder") { model.act(.revealed, on: suggestion); close() }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.path, forType: .string)
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
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.muted)
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36, alignment: suggestion.item.kind == .pdf ? .top : .center)
            } else {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.mutedForeground)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var icon: String {
        switch suggestion.item.kind {
        case .note: "note.text"
        case .message: "bubble.left.and.bubble.right"
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
        guard let url = suggestion.item.fileURL, !suggestion.item.metadataOnly else { return nil }
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
