import CryptoKit
import Foundation

/// What's on screen right now, read by the app and sent to the engine. It lives in memory
/// only: neither process stores it. The journal keeps a salted fingerprint, never the text.
public struct ContextSnapshot: Sendable, Codable, Equatable {
    public enum Origin: String, Sendable, Codable {
        /// `calendar`: an upcoming event (`CalendarEvent`), not a window.
        case accessibility, ocr, text, calendar
    }

    public var appName: String
    public var bundleID: String
    public var windowTitle: String
    /// The file the window shows (`AXDocument`), if it says.
    public var documentPath: String?
    public var url: String?
    /// Selected text, which says most clearly what you care about.
    public var selection: String
    /// The text field you're typing in: the reply you're writing.
    public var focusedText: String
    /// The rest of the window's text, up to a budget.
    public var visibleText: String
    /// People the window is addressed to (a mail compose window's To and Cc).
    public var recipients: [String]
    public var origin: Origin
    public var capturedAt: Date

    public init(
        appName: String = "", bundleID: String = "", windowTitle: String = "", documentPath: String? = nil,
        url: String? = nil, selection: String = "", focusedText: String = "", visibleText: String = "",
        recipients: [String] = [], origin: Origin = .accessibility, capturedAt: Date = Date()
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.documentPath = documentPath
        self.url = url
        self.selection = selection
        self.focusedText = focusedText
        self.visibleText = visibleText
        self.recipients = recipients
        self.origin = origin
        self.capturedAt = capturedAt
    }

    /// A context made from plain text, for the CLI and the eval.
    public static func text(_ text: String, title: String = "", app: String = "Text") -> ContextSnapshot {
        ContextSnapshot(appName: app, windowTitle: title, visibleText: text, origin: .text)
    }

    /// All the words, for deciding whether there's enough to go on.
    public var characterCount: Int {
        selection.count + focusedText.count + visibleText.count + windowTitle.count
    }

    /// Identifies the current draft and selection, plus the start of the window's text.
    /// Hashed with a per-install salt so it can't be reversed into words. Changes at the
    /// end of a long draft count too; whitespace alone doesn't.
    public func fingerprint(salt: String) -> String {
        let normalized = [bundleID, windowTitle, documentPath ?? "", url ?? "",
                          QueryBuilder.clean(focusedText),
                          QueryBuilder.clean(selection), String(visibleText.prefix(400))]
            .joined(separator: "\u{1F}")
            .lowercased()
            .filter { !$0.isWhitespace }
        let digest = SHA256.hash(data: Data((salt + normalized).utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The "topic" of the context: changes when you switch documents or threads, not on every
    /// keystroke. Dwell time counts from the last topic change.
    public var topic: String {
        [bundleID, windowTitle, documentPath ?? "", url ?? ""].joined(separator: "|")
    }
}
