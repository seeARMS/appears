import CoreServices
import Foundation

/// What to index. By default: everything sensible in your home folder, plus Apple Notes.
/// `includes` and `excludes` are for people who want control.
public struct SourceSettings: Sendable, Codable, Equatable {
    /// Extra folders, outside home or inside something the default rules skip (a git repo).
    public var includes: [String]
    /// Folders never indexed. Excluding one removes what's already indexed under it.
    public var excludes: [String]
    public var excludedKinds: Set<ItemKind>
    public var notes: Bool
    /// Demo mode: index this folder as if it were the home folder (the app's `-demo` argument).
    public var homeOverride: String?

    public init(includes: [String] = [], excludes: [String] = [], excludedKinds: Set<ItemKind> = [], notes: Bool = true, homeOverride: String? = nil) {
        self.includes = includes
        self.excludes = excludes
        self.excludedKinds = excludedKinds
        self.notes = notes
        self.homeOverride = homeOverride
    }
}

/// Finds the files worth indexing under the home folder and the included folders.
public struct FileScanner: Sendable {
    public let settings: SourceSettings
    public let home: String

    public init(settings: SourceSettings, home: String? = nil) {
        self.settings = settings
        self.home = home ?? settings.homeOverride ?? FileScanner.realHome
    }

    /// The user's real home folder. In the sandboxed engine `NSHomeDirectory()` is the
    /// container, so ask the password database instead.
    public static var realHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    public var roots: [String] {
        var roots = [home]
        for include in settings.includes where !roots.contains(include) { roots.append(include) }
        return roots
    }

    /// Folder names skipped anywhere: system and app data, code and build output, caches.
    static let skippedNames: Set<String> = [
        "Library", "Applications", "Music", "Movies", "node_modules", "bower_components", "DerivedData",
        "build", "Build", "dist", "target", "out", "venv", "env", "__pycache__", "site-packages", "Pods",
        "Carthage", "vendor", "go", "Caches", "cache", "tmp", "temp", "Logs", "logs",
    ]

    /// Folders directly under home that hold app data rather than your files.
    static let skippedHomeChildren: Set<String> = ["Library", "Applications", "Public", "Music", "Movies"]

    public static let documentExtensions: Set<String> = ["txt", "md", "markdown", "rtf", "html", "htm", "docx", "doc", "odt"]
    public static let pdfExtensions: Set<String> = ["pdf"]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "webp"]

    public static func kind(forExtension ext: String) -> ItemKind? {
        let ext = ext.lowercased()
        if documentExtensions.contains(ext) { return .document }
        if pdfExtensions.contains(ext) { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        return nil
    }

    static func maxSize(_ kind: ItemKind) -> Int64 {
        switch kind {
        case .document: 10 << 20
        case .pdf: 200 << 20
        case .image: 40 << 20
        case .note: .max
        }
    }

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isPackageKey,
    ]

    /// Whether a path is inside an excluded folder.
    public func isExcluded(_ path: String) -> Bool {
        settings.excludes.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    private func isUnderInclude(_ path: String) -> Bool {
        settings.includes.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Whether to descend into a folder.
    func shouldEnter(_ url: URL, isRoot: Bool) -> Bool {
        let path = url.path
        if isExcluded(path) { return false }
        if isRoot { return true }
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return false }
        if url.deletingLastPathComponent().path == home, Self.skippedHomeChildren.contains(name) {
            return isUnderInclude(path)
        }
        if Self.skippedNames.contains(name), !isUnderInclude(path) { return false }
        // Code checkouts are full of READMEs and docs that aren't "things you have";
        // include a repo explicitly to index it.
        if FileManager.default.fileExists(atPath: url.appending(path: ".git").path), !isUnderInclude(path) {
            return false
        }
        return true
    }

    /// Walks every root and calls `found` for each indexable file.
    public func scan(_ found: (Item) throws -> Void) rethrows {
        for root in roots {
            let rootURL = URL(filePath: root)
            guard shouldEnter(rootURL, isRoot: true) else { continue }
            try walk(rootURL, found)
        }
    }

    private func walk(_ folder: URL, _ found: (Item) throws -> Void) rethrows {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Self.keys, options: [.skipsHiddenFiles]
        ) else { return }
        for child in children {
            guard let values = try? child.resourceValues(forKeys: Set(Self.keys)) else { continue }
            if values.isDirectory == true {
                // Bundles (apps, Photos libraries, .rtfd, Pages documents) are skipped whole.
                if values.isPackage == true { continue }
                if shouldEnter(child, isRoot: false) { try walk(child, found) }
            } else if values.isRegularFile == true, let item = item(child, values) {
                try found(item)
            }
        }
    }

    /// The item for one file, or nil if it isn't indexable.
    public func item(at url: URL) -> Item? {
        guard let values = try? url.resourceValues(forKeys: Set(Self.keys)), values.isRegularFile == true else { return nil }
        var folder = url.deletingLastPathComponent()
        while folder.path.count > 1 {
            if roots.contains(folder.path) { return item(url, values) }
            if !shouldEnter(folder, isRoot: false) { return nil }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    private func item(_ url: URL, _ values: URLResourceValues) -> Item? {
        guard let kind = Self.kind(forExtension: url.pathExtension), !settings.excludedKinds.contains(kind) else { return nil }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0, size <= Self.maxSize(kind) else { return nil }
        if isExcluded(url.path) { return nil }
        // An iCloud file that isn't on this Mac: reading it would download it.
        let notDownloaded = values.isUbiquitousItem == true
            && values.ubiquitousItemDownloadingStatus != nil
            && values.ubiquitousItemDownloadingStatus != .current
        return Item(
            source: .file, path: url.path, kind: kind, title: url.lastPathComponent, size: size,
            created: values.creationDate ?? .distantPast, modified: values.contentModificationDate ?? .distantPast,
            lastUsed: nil, metadataOnly: notDownloaded
        )
    }

    /// Size and modification date, so a changed file is re-indexed.
    public static func signature(_ item: Item) -> String {
        "\(item.size)-\(Int(item.modified.timeIntervalSince1970))-\(item.metadataOnly ? 1 : 0)"
    }
}

/// Spotlight's record of when you last opened a file.
public enum LastUsed {
    public static func date(path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString),
              let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return value as? Date
    }
}
