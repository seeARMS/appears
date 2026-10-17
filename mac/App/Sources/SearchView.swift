import AppKit
import AppearsCore
import SwiftUI

/// A typed search, distinct from the ambient panel: the query stays focused while arrows
/// select results. Space is always a space; preview uses Command-Y.
struct SearchView: View {
    @Bindable var model: SearchModel
    let close: () -> Void
    let finish: () -> Void
    let openSettings: () -> Void
    let resize: (CGSize) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.mutedForeground)
                SearchField(text: $model.query, command: command)
                    .frame(height: 34)
                if model.isSearching { ProgressView().controlSize(.small).accessibilityLabel("Updating results") }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.mutedForeground)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 68)
            Rectangle().fill(Theme.border).frame(height: 1)
            content.frame(height: model.hasQuery ? 350 : 190)
            footer
        }
        .frame(width: 640)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: resize)
        .onChange(of: model.app.modelDownload.phase) { model.refresh() }
        .onChange(of: model.app.status?.ready) { model.refresh() }
        .onChange(of: model.app.status?.counts.indexedTotal) {
            if model.results.isEmpty && !model.isSearching { model.refresh() }
        }
        .onChange(of: model.app.settings.sources) { model.refresh(clearResults: true) }
    }

    @ViewBuilder private var content: some View {
        if model.app.modelDownload.phase != .ready {
            ModelDownloadView(status: model.app.modelDownload, retry: model.app.retryModelDownload)
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if let error = model.error {
            message("Search unavailable", text: error) {
                Button("Try again") { model.refresh() }.buttonStyle(OutlineButtonStyle())
            }
        } else if model.app.engineStatusError != nil || (model.app.status?.ready != true && model.results.isEmpty) {
            ReadinessView(model: model.app, openSources: openSettings).padding(24)
        } else if let preview = model.sourcePreview {
            SourcePreviewView(suggestion: preview, title: model.app.contacts.presentation(for: preview.item)?.title,
                              contacts: model.app.contacts,
                              back: { model.sourcePreview = nil }) {
                open(preview)
            }
        } else if !model.hasQuery {
            message("Find it by meaning", text: "Search your files, photos, notes and messages. Describe what you remember.") {
                Text("Try “the quote for the kitchen” or “our trip to Lisbon”.")
                    .font(.system(size: 12)).foregroundStyle(Theme.mutedForeground)
            }
        } else if !model.results.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, suggestion in
                            SearchResultRow(suggestion: suggestion, query: model.query, contacts: model.app.contacts, selected: model.selectedIndex == index) {
                                open(suggestion)
                            } reveal: {
                                open(suggestion, reveal: true)
                            } preview: {
                                model.selectedIndex = model.results.firstIndex { $0.id == suggestion.id } ?? model.selectedIndex
                                model.sourcePreview = suggestion
                            }
                            .allowsHitTesting(!model.isSearching)
                            .accessibilityHidden(model.isSearching)
                            .id(suggestion.id)
                        }
                    }
                    .padding(6)
                }
                .opacity(model.isSearching ? 0.75 : 1)
                .onChange(of: model.selectedIndex) {
                    if let selected = model.selected { proxy.scrollTo(selected.id) }
                }
            }
        } else if model.isSearching {
            message("Searching your index…", text: "Matching what you mean, across text and images.") { EmptyView() }
        } else if model.app.status?.error != nil {
            ReadinessView(model: model.app, openSources: openSettings).padding(24)
        } else if model.app.status?.counts.indexedTotal == 0 {
            message("Your index is still getting started", text: "Results appear as Appears reads your enabled sources.") {
                Button("Open Settings", action: openSettings).buttonStyle(OutlineButtonStyle())
            }
        } else {
            message("No results", text: model.app.status?.counts.waiting ?? 0 > 0
                    ? "No matches yet. More items are still being indexed; try again shortly."
                    : "Try another description, a name, or a few more details.") {
                if let missing = model.app.missingSourceAccess {
                    Text(missing).font(.system(size: 12)).foregroundStyle(Theme.mutedForeground)
                }
                Button("View sources", action: openSettings).buttonStyle(OutlineButtonStyle())
            }
        }
    }

    private func message<Actions: View>(_ title: String, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.foreground)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            actions().padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(nsImage: GlyphImage.image(for: .idle)).renderingMode(.template).frame(width: 14, height: 14)
                Button("Sources", action: openSettings).buttonStyle(.plain)
                    .help(model.app.readinessDetail)
            }
            Spacer()
            if model.isSearching {
                Text(model.results.isEmpty ? "Searching…" : "Updating results…")
            } else if model.sourcePreview != nil {
                hint("esc", "back")
                hint("↩", "open")
            } else if !model.results.isEmpty {
                hint("↑↓", "select")
                hint("↩", "open")
                hint("⌘Y", "preview")
            } else {
                Text("Only on this Mac")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.mutedForeground)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Theme.muted.opacity(0.5))
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) { Kbd(key: key); Text(text) }
    }

    private func open(_ suggestion: Suggestion, reveal: Bool = false) {
        Task {
            if await model.open(suggestion, reveal: reveal) { finish() }
        }
    }

    /// Called by the native field editor, so navigation never moves the insertion point
    /// out of the query, and normal text editing (including spaces and Delete) stays native.
    private func command(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): model.moveSelection(1)
        case #selector(NSResponder.moveUp(_:)): model.moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            if let selected = model.selected { open(selected, reveal: NSApp.currentEvent?.modifierFlags.contains(.command) == true) }
        case #selector(NSResponder.cancelOperation(_:)):
            if model.sourcePreview != nil { model.sourcePreview = nil } else { close() }
        default: return false
        }
        return true
    }
}

private struct SearchResultRow: View {
    let suggestion: Suggestion
    let contacts: ContactDirectory
    let selected: Bool
    let open: () -> Void
    let reveal: () -> Void
    let preview: () -> Void
    private let queryTerms: [String]
    @State private var thumbnail: NSImage?

    init(suggestion: Suggestion, query: String, contacts: ContactDirectory, selected: Bool, open: @escaping () -> Void, reveal: @escaping () -> Void, preview: @escaping () -> Void) {
        self.suggestion = suggestion
        self.contacts = contacts
        self.selected = selected
        self.open = open
        self.reveal = reveal
        self.preview = preview
        let words = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        queryTerms = [query] + words
        _thumbnail = State(initialValue: Thumbnails.cache[suggestion.item.id])
    }

    var body: some View {
        let source = suggestion.unit.text.isEmpty ? suggestion.snippet : suggestion.unit.text
        let evidence = SuggestionEvidence(suggestion, terms: queryTerms, style: .search,
                                          sourceText: contacts.displayText(source, for: suggestion.item))
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.muted)
                    if suggestion.item.kind == .message {
                        ContactAvatar(presentation: contacts.presentation(for: suggestion.item))
                    } else if let thumbnail {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.mutedForeground)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
                .overlay(alignment: .bottomTrailing) {
                    ResultSourceIcon(item: suggestion.item).offset(x: 6, y: 6)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(contacts.presentation(for: suggestion.item)?.title ?? suggestion.item.title).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.foreground).lineLimit(1).truncationMode(.middle)
                    if !evidence.segments.isEmpty {
                        Text(excerpt(evidence)).font(.system(size: 12)).foregroundStyle(Theme.mutedForeground)
                            .lineSpacing(2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    if let location {
                        Text(location).font(.system(size: 11)).foregroundStyle(Theme.mutedForeground)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                Image(systemName: "return").font(.system(size: 12)).foregroundStyle(Theme.mutedForeground)
                    .frame(width: 16, height: 40).opacity(selected ? 1 : 0).accessibilityHidden(true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(selected ? Theme.muted : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu {
            Button("Open", action: open)
            if suggestion.item.fileURL != nil { Button("Show in Finder", action: reveal) }
            else { Button("Preview passage", action: preview) }
            if let line = suggestion.line { Button("Copy Line") { contacts.displayLine(line, for: suggestion.item).copyToPasteboard() } }
        }
        .task(id: suggestion.id) {
            if suggestion.item.source == .messages { await contacts.refresh() }
            thumbnail = await Thumbnails.image(for: suggestion)
        }
    }

    private func excerpt(_ evidence: SuggestionEvidence) -> AttributedString {
        let segments = suggestion.line.map { contacts.displayLine($0, for: suggestion.item).segments } ?? evidence.segments
        return segments.reduce(into: AttributedString()) { text, segment in
            var run = AttributedString(segment.text)
            if segment.emphasized {
                run.font = .system(size: 12, weight: .semibold)
                run.foregroundColor = Theme.foreground
            }
            text += run
        }
    }

    private var location: String? {
        guard suggestion.item.source == .file else { return nil }
        var location = (suggestion.item.folder as NSString).abbreviatingWithTildeInPath
        if let page = suggestion.unit.locator.page { location += " · page \(page)" }
        return location
    }

    private var icon: String {
        switch suggestion.item.kind {
        case .document: "doc.text"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .note: "note.text"
        case .message: "bubble.left.and.bubble.right"
        }
    }
}

/// AppKit's field editor gives us dependable focus, IME support,
/// and selection keys without treating a typed space as Quick Look.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let command: (Selector) -> Bool

    func makeNSView(context: Context) -> QueryField {
        let field = QueryField()
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 23)
        field.placeholderString = "Search anything you remember…"
        field.setAccessibilityLabel("Search Appears")
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: QueryField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // Don't search intermediate marked text while composing with an input method.
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            return parent.command(selector)
        }
    }
}

private final class QueryField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Also focused explicitly by the controller each time this reusable panel opens.
        if let window { window.makeFirstResponder(self) }
    }
}
