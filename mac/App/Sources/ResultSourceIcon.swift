import AppKit
import AppearsCore
import SwiftUI

/// Local app icons identify a result's source without taking the excerpt's line.
struct ResultSourceIcon: View {
    private let icon: NSImage?
    private let name: String

    init(item: Item) {
        let workspace = NSWorkspace.shared
        let application: URL?
        switch item.source {
        case .messages: application = workspace.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS")
        case .notes: application = workspace.urlForApplication(withBundleIdentifier: "com.apple.Notes")
        case .file: application = item.fileURL.flatMap { workspace.urlForApplication(toOpen: $0) }
        }
        let url = application ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.finder")
        icon = url.map { Self.image(for: $0) }
        switch item.source {
        case .messages: name = "Messages"
        case .notes: name = "Notes"
        case .file: name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? "Finder"
        }
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app").resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 18, height: 18)
        .padding(2)
        .help(name)
        .accessibilityLabel(name)
    }

    private static var cache: [URL: NSImage] = [:]

    private static func image(for application: URL) -> NSImage {
        if let icon = cache[application] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: application.path)
        cache[application] = icon
        return icon
    }
}
