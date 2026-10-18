import AppKit
import AppearsCore
import SwiftUI

/// An in-memory banner: it never enters Notification Center or stores source/context text.
@MainActor
final class MatchToastController: NSObject {
    private let panel = MatchToastPanel()
    private var expiry: Task<Void, Never>?
    private let duration: Duration
    private var displayAsleep = false
    private var sessionActive = true
    var isVisible: Bool { panel.isVisible }

    init(duration: Duration = .seconds(8)) {
        self.duration = duration
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(displaySlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(displayWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionBecameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    deinit {
        expiry?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func show(_ entry: AppModel.Shown, contacts: ContactDirectory, screen: NSScreen?, open: @escaping () -> Void) {
        dismiss()
        guard !displayAsleep, sessionActive, let suggestion = entry.suggestions.first else { return }
        let view = MatchToastView(suggestion: suggestion, terms: entry.evidenceTerms, contacts: contacts,
                                 meeting: entry.meeting, open: open, dismiss: { [weak self] in self?.dismiss() })
            .onHover { [weak self] hovering in
                if hovering { self?.expiry?.cancel() } else { self?.scheduleExpiry() }
            }
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        let frame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - 12))
        panel.orderFrontRegardless()
        scheduleExpiry()
    }

    @objc func dismiss() {
        expiry?.cancel()
        expiry = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }

    @objc private func displaySlept() { displayAsleep = true; dismiss() }
    @objc private func displayWoke() { displayAsleep = false }
    @objc private func sessionResigned() { sessionActive = false; dismiss() }
    @objc private func sessionBecameActive() { sessionActive = true }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard panel.isVisible else { return }
        let duration = duration
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.dismiss()
        }
    }
}

private final class MatchToastPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct MatchToastView: View {
    let suggestion: Suggestion
    let terms: [String]
    let contacts: ContactDirectory
    var meeting: CalendarEvent?
    let open: () -> Void
    let dismiss: () -> Void
    @State private var thumbnail: NSImage?

    private var evidence: SuggestionEvidence {
        let source = suggestion.unit.text.isEmpty ? suggestion.snippet : suggestion.unit.text
        return SuggestionEvidence(suggestion, terms: terms, style: .search,
                                  sourceText: contacts.displayText(source, for: suggestion.item))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Mark(size: 15)
                Text("Appears").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mutedForeground)
                .accessibilityLabel("Dismiss match alert")
                .help("Dismiss alert")
            }
            Button(action: open) {
                VStack(alignment: .leading, spacing: 9) {
                    if let meeting {
                        Label("\(meeting.start.formatted(date: .omitted, time: .shortened)) · \(meeting.title)", systemImage: "calendar")
                            .font(.system(size: 11)).foregroundStyle(Theme.mutedForeground).lineLimit(1)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        preview
                        VStack(alignment: .leading, spacing: 5) {
                            Text(contacts.presentation(for: suggestion.item)?.title ?? suggestion.item.title)
                                .font(.system(size: 13, weight: .medium)).lineLimit(2)
                            if !evidence.segments.isEmpty {
                                evidenceText.font(.system(size: 12)).lineSpacing(1.5).lineLimit(3)
                            }
                            if !evidence.metadata.isEmpty {
                                Text(evidence.metadata).font(.system(size: 11))
                                    .foregroundStyle(Theme.mutedForeground).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("View related results").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.mutedForeground)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Theme.foreground)
        .padding(14)
        .frame(width: 360)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
        .task(id: suggestion.id) {
            if suggestion.item.source == .messages { await contacts.refresh() }
            thumbnail = await Thumbnails.image(for: suggestion)
        }
    }

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

    private var preview: some View {
        ZStack {
            Theme.muted
            if suggestion.item.kind == .message {
                ContactAvatar(presentation: contacts.presentation(for: suggestion.item))
            } else if let image = thumbnail ?? Thumbnails.cache[suggestion.item.id] {
                Image(nsImage: image).resizable()
                    .aspectRatio(contentMode: suggestion.item.kind == .pdf ? .fit : .fill)
                    .frame(width: 40, height: 40)
            } else {
                Image(systemName: suggestion.item.kind == .image ? "photo" : "doc.text")
                    .foregroundStyle(Theme.mutedForeground)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
    }
}
