import AppKit
import AppearsCore
import ApplicationServices

/// What the reader saw, plus what the app needs to decide whether to use it.
public struct CapturedContext: Sendable {
    public var snapshot: ContextSnapshot
    /// A private or incognito browser window.
    public var isPrivate: Bool
    /// A browser that can't say whether its window is private (Safari).
    public var privacyUnknown: Bool
    /// The focused field is a password field.
    public var isSecure: Bool
}

/// Reads the frontmost window through the Accessibility API: its title, the document it
/// shows, the field you're typing in, the selection, and its visible text, within a time and
/// size budget. Watches for changes with an `AXObserver` on the frontmost app.
///
/// Nothing it reads is stored. It's handed to the engine in memory and dropped.
@MainActor
public final class ContextReader {
    public enum Change { case context, textEdited, navigation }
    /// Called on the main thread whenever the frontmost app, window, focus, title, text or
    /// selection changes. Callers debounce.
    public var onChange: ((Change) -> Void)?

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var observedField: AXUIElement?
    private var activationToken: NSObjectProtocol?
    private var enabledManualAccessibility: Set<pid_t> = []

    public init() {}

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    @discardableResult
    public static func requestTrust() -> Bool {
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public func start() {
        guard activationToken == nil else { observeFrontmost(); return }
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.observeFrontmost()
                self?.onChange?(.navigation)
            }
        }
        observeFrontmost()
    }

    public func stop() {
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        detach()
    }

    // MARK: - Observing

    private static let notifications = [
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXFocusedUIElementChangedNotification,
        kAXTitleChangedNotification, kAXValueChangedNotification, kAXSelectedTextChangedNotification,
    ]

    private func observeFrontmost() {
        guard Self.isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        guard pid != observedPID, pid != getpid() else { return }
        detach()
        observedPID = pid
        let element = AXUIElementCreateApplication(pid)
        enableManualAccessibility(element, pid: pid)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let reader = Unmanaged<ContextReader>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated {
                let edited = notification as String == kAXValueChangedNotification &&
                    reader.observedField.map { CFEqual(element, $0) } == true
                let navigation = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                                  kAXFocusedUIElementChangedNotification].contains(notification as String)
                reader.observeFocusedField()
                reader.onChange?(edited ? .textEdited : (navigation ? .navigation : .context))
            }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observeFocusedField()
    }

    /// Value and selection notifications belong to the editable element. Subscribing
    /// only to the app does not reliably report typing inside Messages or other apps.
    private func observeFocusedField() {
        guard let observer else { return }
        let app = AXUIElementCreateApplication(observedPID)
        let focused: AXUIElement? = attribute(app, kAXFocusedUIElementAttribute)
        if let focused, let observedField, CFEqual(focused, observedField) { return }
        let notifications = [kAXValueChangedNotification, kAXSelectedTextChangedNotification]
        if let observedField {
            for name in notifications { AXObserverRemoveNotification(observer, observedField, name as CFString) }
        }
        observedField = focused
        if let focused {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for name in notifications { AXObserverAddNotification(observer, focused, name as CFString, refcon) }
        }
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedField = nil
        observedPID = 0
    }

    /// Electron and Chromium apps build their accessibility tree only when asked.
    private func enableManualAccessibility(_ app: AXUIElement, pid: pid_t) {
        guard !enabledManualAccessibility.contains(pid) else { return }
        enabledManualAccessibility.insert(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: - Reading

    /// Reads the frontmost window now. Nil if nothing is readable (no permission, no window,
    /// or Appears itself is frontmost).
    public func capture(includeBrowserURL: Bool = true) -> CapturedContext? {
        guard Self.isTrusted, let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        enableManualAccessibility(element, pid: app.processIdentifier)
        let bundleID = app.bundleIdentifier ?? ""
        var snapshot = ContextSnapshot(appName: app.localizedName ?? bundleID, bundleID: bundleID)

        let window: AXUIElement? = attribute(element, kAXFocusedWindowAttribute) ?? attribute(element, kAXMainWindowAttribute)
        if let window {
            snapshot.windowTitle = attribute(window, kAXTitleAttribute) ?? ""
            if let document: String = attribute(window, kAXDocumentAttribute), let url = URL(string: document), url.isFileURL {
                snapshot.documentPath = url.path
            }
        }

        var isSecure = false
        if let focused: AXUIElement = attribute(element, kAXFocusedUIElementAttribute) {
            let role: String = attribute(focused, kAXRoleAttribute) ?? ""
            let subrole: String = attribute(focused, kAXSubroleAttribute) ?? ""
            isSecure = subrole == (kAXSecureTextFieldSubrole as String)
            if !isSecure {
                snapshot.selection = String((attribute(focused, kAXSelectedTextAttribute) ?? "").prefix(4_000))
                if [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXWebArea"].contains(role) || attribute(focused, "AXEditableAncestor") as AXUIElement? != nil {
                    let value: String = attribute(focused, kAXValueAttribute) ?? ""
                    snapshot.focusedText = String(value.prefix(8_000))
                }
            }
        }

        if let window, !isSecure {
            var walk = TreeWalk()
            walk.collect(window)
            snapshot.visibleText = walk.text
            snapshot.recipients = walk.recipients
            if let url = walk.url { snapshot.url = url }
        }

        var isPrivate = false
        var privacyUnknown = false
        if includeBrowserURL, let browser = Browsers.kind(bundleID) {
            let reading = Browsers.read(browser, bundleID: bundleID)
            if let url = reading.url { snapshot.url = url }
            isPrivate = reading.isPrivate
            privacyUnknown = reading.privacyUnknown
            if browser == .firefox, snapshot.windowTitle.contains("Private Browsing") { isPrivate = true }
        }
        if isSecure {
            snapshot.selection = ""
            snapshot.focusedText = ""
        }
        snapshot.capturedAt = Date()
        return CapturedContext(snapshot: snapshot, isPrivate: isPrivate, privacyUnknown: privacyUnknown, isSecure: isSecure)
    }

    /// The frontmost window's document, cheaply: for marking files you have open as recently used.
    public func frontmostDocumentPath() -> String? {
        guard Self.isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard let window: AXUIElement = attribute(element, kAXFocusedWindowAttribute),
              let document: String = attribute(window, kAXDocumentAttribute),
              let url = URL(string: document), url.isFileURL else { return nil }
        return url.path
    }
}

/// Collects a window's text breadth-first, within a node, time and character budget,
/// skipping menus and toolbars.
struct TreeWalk {
    static let characterBudget = 8_000
    static let nodeBudget = 4_000
    static let timeBudget: TimeInterval = 0.06

    var pieces: [String] = []
    var characters = 0
    var recipients: [String] = []
    var url: String?

    var text: String { pieces.joined(separator: "\n") }

    static let skippedRoles: Set<String> = ["AXMenuBar", "AXMenu", "AXToolbar", "AXScrollBar", "AXImage", "AXSecureTextField"]

    mutating func collect(_ root: AXUIElement) {
        let started = Date()
        var queue: [AXUIElement] = [root]
        var visited = 0
        var seen: Set<String> = []
        while !queue.isEmpty, visited < Self.nodeBudget, characters < Self.characterBudget {
            if visited % 64 == 0, Date().timeIntervalSince(started) > Self.timeBudget { break }
            let element = queue.removeFirst()
            visited += 1
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            if Self.skippedRoles.contains(role) { continue }
            if role == "AXWebArea", url == nil, let link: URL = attribute(element, kAXURLAttribute) {
                url = link.absoluteString
            }
            if role == kAXStaticTextRole as String || role == kAXTextAreaRole as String || role == "AXHeading" {
                if let value: String = attribute(element, kAXValueAttribute) ?? attribute(element, kAXTitleAttribute) {
                    add(value, seen: &seen)
                }
            }
            if role == kAXTextFieldRole as String || role == "AXTokenField" {
                let label: String = (attribute(element, kAXDescriptionAttribute) ?? attribute(element, kAXTitleAttribute) ?? "").lowercased()
                if ["to:", "to", "cc:", "cc"].contains(label) {
                    let value: String = attribute(element, kAXValueAttribute) ?? ""
                    recipients += value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            }
            let children: [AXUIElement] = attribute(element, kAXVisibleChildrenAttribute) ?? attribute(element, kAXChildrenAttribute) ?? []
            queue.append(contentsOf: children.prefix(200))
        }
    }

    private mutating func add(_ value: String, seen: inout Set<String>) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !seen.contains(trimmed) else { return }
        seen.insert(trimmed)
        let room = Self.characterBudget - characters
        let piece = String(trimmed.prefix(room))
        pieces.append(piece)
        characters += piece.count + 1
    }
}

/// Reads an accessibility attribute as a Swift type.
func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
    if T.self == AXUIElement.self, CFGetTypeID(value) == AXUIElementGetTypeID() { return (value as! T) }
    if T.self == [AXUIElement].self { return value as? [AXUIElement] as? T }
    if T.self == URL.self { return (value as? URL) as? T ?? (value as? String).flatMap(URL.init(string:)) as? T }
    return value as? T
}
