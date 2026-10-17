import AppKit
import AppearsContext
import AppearsCore
import Contacts
import SwiftUI

/// One in-memory directory shared by ambient results and typed search. Never prompts
/// from a result row, and discards cached contacts when access is revoked or Messages is off.
@MainActor @Observable
final class ContactDirectory {
    private(set) var snapshot = MessageContacts()
    private(set) var access = MessageContacts.access
    private(set) var loadFailed = false
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var lastLoaded = Date.distantPast
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loading: Task<MessageContacts?, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let store = CNContactStore()
    @ObservationIgnored private var reloadRequested = false

    init(snapshot: MessageContacts = MessageContacts()) {
        self.snapshot = snapshot
    }

    func start(enabled: Bool) {
        self.enabled = enabled
        if !enabled { clear() }
        if observers.isEmpty {
            observers = [Notification.Name.CNContactStoreDidChange, NSApplication.didBecomeActiveNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in await self?.refresh(force: true) }
                }
            }
        }
        Task { await refresh(force: true) }
    }

    func refresh(force: Bool = false) async {
        guard enabled else { return }
        let currentAccess = MessageContacts.access
        let changed = currentAccess != access
        access = currentAccess
        if changed {
            clear()
        }
        if loading != nil {
            reloadRequested = reloadRequested || force
            return
        }
        guard force || changed || Date().timeIntervalSince(lastLoaded) > 60 else { return }
        let expected = generation
        let task = Task.detached(priority: .utility) { try? MessageContacts.load() }
        loading = task
        let loaded = await task.value
        guard generation == expected else { return }
        loading = nil
        // A permission change during the fetch must not restore private cached data.
        guard MessageContacts.access == access else { await refresh(force: true); return }
        snapshot = loaded ?? MessageContacts()
        loadFailed = loaded == nil
        lastLoaded = Date()
        if reloadRequested {
            reloadRequested = false
            await refresh(force: true)
        }
    }

    private func clear() {
        generation += 1
        loading?.cancel()
        loading = nil
        snapshot = MessageContacts()
        lastLoaded = .distantPast
        loadFailed = false
        reloadRequested = false
    }

    func checkAuthorization() {
        let currentAccess = MessageContacts.access
        guard currentAccess != access else { return }
        if enabled {
            Task { await refresh(force: true) }
        } else {
            access = currentAccess
        }
    }

    func allow() async {
        let currentAccess = MessageContacts.access
        if currentAccess == .notAsked {
            await MessageContacts.requestAccess()
        } else if currentAccess == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
        }
        if !enabled { access = MessageContacts.access }
        await refresh(force: true)
    }

    func presentation(for item: Item) -> MessageContacts.Presentation? { snapshot.presentation(for: item) }
    func displayText(_ text: String, for item: Item) -> String { snapshot.displayText(text, for: item) }
    func displaySnippet(for suggestion: Suggestion) -> String { snapshot.displaySnippet(for: suggestion) }
    func displayLine(_ line: MatchedLine, for item: Item) -> MatchedLine { snapshot.displayLine(line, for: item) }
}

/// A message's contact photo, or initials when the contact has no photo. Attached photos
/// keep their own preview and never use a person's avatar in place of the actual image.
struct ContactAvatar: View {
    let presentation: MessageContacts.Presentation?
    var body: some View {
        if let data = presentation?.photo, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else if let initials = presentation?.initials {
            Text(initials).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.mutedForeground)
        } else {
            Image(systemName: presentation?.isGroup == true ? "person.2" : "person.crop.circle")
                .font(.system(size: 18)).foregroundStyle(Theme.mutedForeground)
        }
    }
}
