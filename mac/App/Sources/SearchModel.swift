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
    var sourcePreview: Suggestion?
    @ObservationIgnored private let search: (SearchRequest) async throws -> RecallResponse
    @ObservationIgnored private let openItem: (Item) async -> Bool
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private let session = UUID()
    @ObservationIgnored private var isOpen = false

    init(app: AppModel, search: ((SearchRequest) async throws -> RecallResponse)? = nil,
         openItem: ((Item) async -> Bool)? = nil) {
        self.app = app
        self.search = search ?? {
            await app.sourcesUpdate?.value
            try Task.checkCancellation()
            return try await app.engine.search($0)
        }
        self.openItem = openItem ?? { item in
            guard await ResultOpener.open(item) else { return false }
            Task { await app.engine.send(.touch, item.path) }
            return true
        }
    }

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
        sourcePreview = nil
    }

    func refresh(clearResults: Bool = false) {
        revision += 1
        worker?.cancel()
        worker = nil
        error = nil
        sourcePreview = nil
        isSearching = isOpen && hasQuery && app.modelDownload.phase == .ready
        if clearResults || !isSearching { results = []; selectedIndex = 0 }
        guard isSearching else { return }
        let version = revision
        let draft = SearchRequest(text: query, token: SearchToken(session: session, revision: version))
        // Debounce the latest draft independently of a superseded XPC reply. The engine
        // cancels obsolete work too, so replacing the task doesn't build a model queue.
        worker = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer { if version == self.revision { self.worker = nil } }
            do {
                try await Task.sleep(for: .milliseconds(180))
                try Task.checkCancellation()
                await self.app.contacts.refresh()
                try Task.checkCancellation()
                var request = draft
                request.contacts = self.app.contacts.snapshot.searchContacts(in: draft.text)
                let response = try await self.search(request)
                guard !Task.isCancelled, self.isOpen, version == self.revision else { return }
                let selectedID = self.selected?.id
                self.results = response.suggestions.filter { self.app.mayShow($0.item) }
                self.selectedIndex = selectedID.flatMap { id in self.results.firstIndex { $0.id == id } } ?? 0
                self.isSearching = false
            } catch {
                guard !Task.isCancelled, self.isOpen, version == self.revision else { return }
                if error is CancellationError { self.isSearching = false; return }
                self.results = []
                self.selectedIndex = 0
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
        }
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
        if sourcePreview != nil { sourcePreview = selected?.item.fileURL == nil ? selected : nil }
    }

    @discardableResult
    func open(_ suggestion: Suggestion, reveal: Bool = false) async -> Bool {
        guard isOpen, !isSearching else { return false }
        let version = revision
        if reveal {
            guard let url = suggestion.item.fileURL else { return false }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            guard await openItem(suggestion.item) else { return false }
        }
        return isOpen && version == revision
    }

    func toggleSourcePreview() {
        guard !isSearching, let selected, selected.item.fileURL == nil else { return }
        sourcePreview = sourcePreview == nil ? selected : nil
    }

    /// Demo-only rendering, without searching or touching the user's index.
    func showForSnapshot(query: String, results: [Suggestion], searching: Bool = false, error: String? = nil) {
        self.query = query
        self.results = results
        self.isSearching = searching
        self.error = error
    }
}
