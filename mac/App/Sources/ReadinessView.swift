import AppearsCore
import SwiftUI

enum SettingsTab: Hashable { case general, updates, sources, privacy, stats }

@MainActor
extension AppModel {
    var readinessTitle: String {
        guard modelDownload.phase == .ready else { return "Preparing Appears" }
        if engineStatusError != nil || status?.error != nil { return "Index needs attention" }
        guard let status, status.ready else { return "Starting the search engine…" }
        switch status.progress.phase {
        case .scanning: return "Looking for new items…"
        case .indexing: return "Reading your files…"
        case .paused: return "Indexing paused"
        case .idle:
            if status.counts.waiting > 0 { return "Items queued for indexing" }
            if status.sources.first(where: { $0.source == .file })?.lastChecked == nil, status.counts.indexedTotal == 0 { return "Getting your index started…" }
            return status.counts.indexedTotal > 0 ? "Ready to search" : "No items indexed yet"
        }
    }

    var readinessDetail: String {
        if let engineStatusError { return engineStatusError }
        if let error = status?.error { return error }
        guard let status else { return "Your files will be searchable as soon as the engine is ready." }
        if !status.ready { return "Loading the on-device model. This can take a moment on the first launch." }
        if status.progress.phase == .scanning { return "\(status.progress.scanned.formatted()) items found so far. Already indexed items remain searchable." }
        if status.progress.phase == .paused { return status.progress.pausedReason ?? "Indexing will resume automatically." }
        let indexed = status.counts.indexedTotal.formatted()
        let waiting = status.counts.waiting
        if waiting > 0 {
            if status.progress.phase == .indexing {
                return "\(indexed) searchable · \(waiting.formatted()) left to index. You can search while indexing continues."
            }
            return "\(indexed) searchable · \(waiting.formatted()) queued to index. Appears retries the queue automatically every minute."
        }
        if status.counts.indexedTotal == 0 {
            return status.sources.first(where: { $0.source == .file })?.lastChecked == nil
                ? "You can keep working while Appears checks your sources."
                : "Check your sources and permissions, or add a folder."
        }
        return "\(indexed) items searchable on this Mac."
    }

    var missingSourceAccess: String? {
        guard let status, status.ready else { return nil }
        var missing: [String] = []
        if settings.sources.notes && !status.notesReadable { missing.append("Notes") }
        if settings.sources.messages && !status.messagesReadable { missing.append("Messages") }
        guard !missing.isEmpty else { return nil }
        return "\(missing.joined(separator: " and ")) \(missing.count > 1 ? "need" : "needs") Full Disk Access."
    }
}

/// Shared by Sources and the empty states, using the same state as the menu bar.
struct ReadinessView: View {
    @Bindable var model: AppModel
    var details = false
    var openSources: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.modelDownload.phase != .ready {
                ModelDownloadView(status: model.modelDownload, retry: model.retryModelDownload)
            } else {
                HStack(alignment: .top) {
                    Text(model.readinessTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.foreground)
                    Spacer(minLength: 8)
                    if details {
                        Button(model.isRequestingScan ? "Requesting scan…" : model.status?.progress.phase == .scanning ? "Scanning…" : "Scan now") {
                            Task { await model.scanNow() }
                        }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(model.isRequestingScan || model.status?.ready == false || model.status?.progress.phase == .scanning)
                        .help("Check all enabled sources for new and changed items, then index them.")
                    }
                }
                Text(model.readinessDetail).font(.system(size: 12)).foregroundStyle(Theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                if details {
                    Text("Files update as they change. Messages are checked every minute; Notes every 10 minutes.")
                        .font(.system(size: 11)).foregroundStyle(Theme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.scanRequestError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                } else if let message = model.scanRequestMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(Theme.mutedForeground)
                }
                if let missing = model.missingSourceAccess {
                    Text(missing).font(.system(size: 12)).foregroundStyle(Theme.mutedForeground)
                }
                if details, let status = model.status, status.ready {
                    ForEach(status.sources) { source in sourceRow(source, status: status) }
                    if status.counts.unreadable > 0 {
                        Text("\(status.counts.unreadable.formatted()) items couldn’t be read. Other results are still available; unreadable items are retried when they change.")
                            .font(.system(size: 11)).foregroundStyle(Theme.mutedForeground)
                    }
                    if status.watchedFolders.isEmpty {
                        Text("Live folder updates aren’t running. Reopen Appears; periodic scans still check for changes.")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
                }
                if !details, model.engineStatusError != nil || model.status?.error != nil || model.scanRequestError != nil {
                    Button("Try again") { Task { await model.scanNow() } }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(model.isRequestingScan)
                }
            }
            if let openSources { Button("View sources", action: openSources).buttonStyle(OutlineButtonStyle()) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceRow(_ source: SourceStatus, status: EngineStatus) -> some View {
        let enabled = source.source == .file || (source.source == .notes ? model.settings.sources.notes : model.settings.sources.messages)
        let readable = source.source == .file || (source.source == .notes ? status.notesReadable : status.messagesReadable)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: source.source == .file ? "folder" : source.source == .notes ? "note.text" : "message")
                .frame(width: 16).foregroundStyle(Theme.mutedForeground)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.source == .file ? "Files" : source.source == .notes ? "Apple Notes" : "Messages and photos")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.foreground)
                if !enabled { Text("Off") }
                else if !readable { Text("Needs Full Disk Access") }
                else {
                    Text("\(source.indexed.formatted()) searchable\(source.waiting > 0 ? " · \(source.waiting.formatted()) queued to index" : "")")
                    if let date = source.lastChecked {
                        Text("\(source.source == .file ? "Last scan" : "Last checked") \(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                            .help(date.formatted(date: .abbreviated, time: .shortened))
                    } else { Text("Updates checked automatically") }
                }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.mutedForeground)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }
}
