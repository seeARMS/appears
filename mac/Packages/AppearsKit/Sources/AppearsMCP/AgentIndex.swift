import AppearsCore
import CoreGraphics
import Foundation

/// What `appears mcp` searches: an Appears index opened read-only, normally the engine's own
/// while the app keeps it up to date, and the model, loaded on the first call and kept for
/// the life of the process.
///
/// An agent asking is not an ambient suggestion, so ranking keeps relevance, entity matches
/// and variety but drops the "forgotten" weighting unless asked (`preferForgotten`). Nothing
/// is journaled: agent questions mustn't count toward the pull, shadow or ambient numbers, and
/// the query text is never stored or logged.
public actor AgentIndex {
    /// The folder holding `index.sqlite`.
    public let folder: URL
    /// The app's Include and Exclude settings. The engine already removed what they exclude;
    /// applying them again covers changes it hasn't caught up with.
    public let sources: SourceSettings
    private let loadEmbedder: @Sendable () async throws -> any Embedder
    private var embedderTask: Task<any Embedder, Error>?
    private var store: IndexStore?
    private var vectors: VectorIndex?
    private var stamp: String?

    public init(folder: URL, sources: SourceSettings = SourceSettings(), loadEmbedder: @escaping @Sendable () async throws -> any Embedder) {
        self.folder = folder
        self.sources = sources
        self.loadEmbedder = loadEmbedder
    }

    public enum Failure: Error, CustomStringConvertible {
        case notPermitted(String)
        case noIndex(String)
        case wrongModel(index: String, loaded: String)
        case notIndexed(String)
        case model(String)

        public var description: String {
            switch self {
            case .notPermitted(let folder):
                "macOS didn't let this process read Appears' index at \(folder). The app keeps its index in the engine's sandbox container, which macOS protects from other apps. Give Full Disk Access to the app that runs this agent (System Settings → Privacy & Security → Full Disk Access) and restart it, or point `appears mcp --data` at an index of your own."
            case .noIndex(let folder):
                "There's no Appears index at \(folder). Open Appears and let it index, or point `appears mcp --data` at an index made with `appears index`."
            case .wrongModel(let index, let loaded):
                "This index was built with \(index), but appears loaded \(loaded). Pass the model the index was made with (`appears mcp --model`), such as the one inside Appears.app."
            case .notIndexed(let path):
                "Appears hasn't indexed \(path). It indexes documents, PDFs, images and screenshots in the home folder and Include folders, and skips code checkouts, ~/Library and excluded folders."
            case .model(let reason):
                "Appears couldn't load its model: \(reason)"
            }
        }
    }

    // MARK: - Searching

    /// What the user already has about `text`: a question, a topic, names, or a passage.
    public func related(text: String, limit: Int, preferForgotten: Bool) async throws -> [Suggestion] {
        let (store, vectors, embedder) = try await ready()
        var recall = Recall(store: store, vectors: vectors, embedder: embedder)
        recall.settings = Self.ranking(preferForgotten: preferForgotten)
        let request = RecallRequest(context: Self.context(text), trigger: .pull, limit: limit, exclude: try excluded(store))
        return try await recall.run(request).suggestions
    }

    /// What relates to a file Appears has indexed, searched with the file's own stored vectors,
    /// so it needs no model call.
    public func related(toFile path: String, limit: Int, preferForgotten: Bool) async throws -> (item: Item, suggestions: [Suggestion]) {
        let (store, vectors, embedder) = try await ready()
        let excluded = try excluded(store)
        // The index has paths as the scanner found them; an agent may come by way of a symlink
        // (/tmp for /private/tmp). Foundation's symlink resolving drops /private, so ask realpath.
        var found = try store.item(path: path)
        if found == nil, let resolved = realpath(path, nil) {
            defer { free(resolved) }
            found = try store.item(path: String(cString: resolved))
        }
        guard let item = found, !excluded.contains(item.id) else { throw Failure.notIndexed(path) }
        let units = try store.units(itemID: item.id).filter { $0.vector.count == embedder.dimension }
        guard !units.isEmpty else { throw Failure.notIndexed(path) }
        var mean = [Float](repeating: 0, count: embedder.dimension)
        for (_, vector) in units { for index in mean.indices { mean[index] += vector[index] } }
        let norm = mean.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { mean = mean.map { $0 / norm } }

        // The file's text still drives the full-text side (names, numbers, rare words). A file
        // with almost no text (a photo) gets its folder's name, so Recall has enough to go on.
        var text = ([item.title] + units.map(\.unit.text)).joined(separator: "\n")
        if QueryBuilder.clean(text).count < 12 { text += "\n" + (item.folder as NSString).lastPathComponent }
        var recall = Recall(store: store, vectors: vectors, embedder: FileQueryEmbedder(base: embedder, vector: mean))
        recall.settings = Self.ranking(preferForgotten: preferForgotten)
        let request = RecallRequest(
            context: .text(String(text.prefix(4_000))), trigger: .pull, limit: limit,
            exclude: excluded + [item.id]
        )
        return (item, try await recall.run(request).suggestions)
    }

    /// Explicit text keeps even a one-word query verbatim. No synthetic asking words,
    /// window title or open document enter its embedding.
    static func context(_ text: String) -> ContextSnapshot {
        return ContextSnapshot(selection: text, origin: .text)
    }

    /// The app's ranking, without the "forgotten" weighting unless asked: when an agent asks
    /// outright, yesterday's file is as good an answer as last year's.
    static func ranking(preferForgotten: Bool) -> RankingSettings {
        var settings = RankingSettings()
        settings.preferForgottenForActiveText = preferForgotten
        if !preferForgotten {
            settings.recentWeight = 1
            settings.recentMessageWeight = 1
            settings.olderWeight = 1
        }
        return settings
    }

    /// Items the app's settings exclude (folders, kinds, Notes) that may still be in the index.
    /// "Never show this" is applied by Recall itself.
    private func excluded(_ store: IndexStore) throws -> [Int64] {
        var ids = try store.itemIDs(under: sources.excludes)
        if !sources.notes { ids += try store.itemIDs(source: .notes) }
        ids += try store.itemIDs(kinds: sources.excludedKinds)
        return ids
    }

    // MARK: - Loading

    /// The model, the index and its vectors, reloading the vectors when the index has changed.
    private func ready() async throws -> (IndexStore, VectorIndex, any Embedder) {
        let embedder = try await embedderLoaded()
        let store = try opened()
        if let model = try store.meta("model_id"), model != embedder.modelID {
            throw Failure.wrongModel(index: model, loaded: embedder.modelID)
        }
        // The engine keeps indexing while this process lives: reload when the index changed.
        // A fresh VectorIndex leaves any search still running on the old one undisturbed.
        let current = try store.contentStamp()
        if let vectors, current == stamp { return (store, vectors, embedder) }
        let fresh = VectorIndex(dimension: embedder.dimension)
        try store.loadVectors(into: fresh)
        vectors = fresh
        stamp = current
        return (store, fresh, embedder)
    }

    private func embedderLoaded() async throws -> any Embedder {
        if embedderTask == nil { embedderTask = Task { try await loadEmbedder() } }
        do {
            return try await embedderTask!.value
        } catch {
            // Let a later call try again (a model folder that appears after a fix).
            embedderTask = nil
            throw Failure.model(String(describing: error))
        }
    }

    private func opened() throws -> IndexStore {
        if let store { return store }
        let url = folder.appending(path: "index.sqlite")
        // macOS answers "not permitted" for another app's container, and "no such file" for a
        // folder that has no index yet. Tell them apart before SQLite blurs both into one error.
        let descriptor = open(url.path, O_RDONLY)
        if descriptor < 0 {
            throw errno == ENOENT || errno == ENOTDIR ? Failure.noIndex(folder.path) : Failure.notPermitted(folder.path)
        }
        close(descriptor)
        do {
            let store = try IndexStore(url: url, readOnly: true)
            _ = try store.meta("model_id")
            self.store = store
            return store
        } catch {
            throw Failure.noIndex(folder.path)
        }
    }
}

/// Recall embeds its query through an embedder. For "related to this file" the file's own
/// vector is the query, so this hands it back instead of running the model.
struct FileQueryEmbedder: Embedder {
    var supportsPassageRefinement: Bool { false }
    let base: any Embedder
    let vector: [Float]

    var modelID: String { base.modelID }
    var dimension: Int { base.dimension }
    var supportsImages: Bool { base.supportsImages }

    func embed(queries: [String]) async throws -> [[Float]] { queries.map { _ in vector } }
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] { try await base.embed(documents: documents) }
    func embed(images: [CGImage]) async throws -> [[Float]] { try await base.embed(images: images) }
}
