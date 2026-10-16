import AppKit
import AppearsCore
import Observation

/// The search window has its own transient state. It never captures the screen or logs a
/// pull, and closing it drops the query and results, including any request still in flight.
@MainActor @Observable
final class SearchModel {
    let app: AppModel
    var query = "" { didSet { if query != oldValue { refresh() } } }
    private(set) var results: [Suggestion] = []
    private(set) var isSearching = false
    private(set) var error: String?
    var selectedIndex = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var deadline = Date.distantPast
    @ObservationIgnored private var isOpen = false

    init(app: AppModel) { self.app = app }

    var selected: Suggestion? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func begin() { isOpen = true; refresh() }

    func clear() {
        isOpen = false
        query = ""
        revision += 1
        results = []
        error = nil
        isSearching = false
        selectedIndex = 0
    }

    func refresh() {
        revision += 1
        results = []
        error = nil
        selectedIndex = 0
        isSearching = isOpen && hasQuery && app.modelDownload.phase == .ready
        deadline = Date().addingTimeInterval(0.18)
        guard isSearching, worker == nil else { return }
        // One request at a time: typing while the model is busy replaces the pending query
        // instead of queuing embeddings for every keystroke. Only the latest reply can show.
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil }
            while self.isOpen && self.hasQuery && self.app.modelDownload.phase == .ready {
                let version = self.revision
                let wait = self.deadline.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard self.isOpen else { return }
                if version != self.revision { continue }
                let text = self.query
                do {
                    let response = try await self.app.engine.search(text)
                    guard self.isOpen else { return }
                    if version != self.revision { continue }
                    self.results = response.suggestions
                    self.isSearching = false
                } catch {
                    guard self.isOpen else { return }
                    if version != self.revision { continue }
                    // Keep the engine's actionable failure in memory only, just like the
                    // query. Neither is written to logs or the suggestion journal.
                    if self.app.modelDownload.phase == .ready,
                       error.localizedDescription == ModelAssetError.missing.localizedDescription {
                        self.error = "The model is downloaded, but the search engine can't read it. Reopen Appears and try again."
                    } else {
                        self.error = error.localizedDescription
                    }
                    self.isSearching = false
                }
                return
            }
        }
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    @discardableResult
    func open(_ suggestion: Suggestion, reveal: Bool = false) -> Bool {
        if reveal {
            guard let url = suggestion.item.fileURL else { return false }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            guard let url = suggestion.item.openURL, NSWorkspace.shared.open(url) else { return false }
            Task { await app.engine.send(.touch, suggestion.item.path) }
        }
        return true
    }

    /// Demo-only rendering, without searching or touching the user's index.
    func showForSnapshot(query: String, results: [Suggestion], searching: Bool = false, error: String? = nil) {
        self.query = query
        self.results = results
        self.isSearching = searching
        self.error = error
    }
}
