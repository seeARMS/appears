import AppKit
import AppearsContext
import AppearsCore
import KeyboardShortcuts
import SwiftUI

/// Settings: native toolbar tabs, each a grouped form of the same size.
@MainActor
final class SettingsTabsController: NSTabViewController {
    /// The content area below the toolbar. Every pane fills it and scrolls within it.
    static let size = NSSize(width: 560, height: 580)
    private let model: AppModel
    private let tabs: [SettingsTab] = [.general, .suggestions, .sources, .privacy, .activity]

    /// The Settings window. The tab controller sizes the window from the selected pane's
    /// `preferredContentSize` and titles it from the pane's `title`, so both are set here.
    static func makeWindow(model: AppModel) -> NSWindow {
        let window = NSWindow(contentViewController: SettingsTabsController(model: model))
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.center()
        return window
    }

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = []
        for tab in tabs {
            let host = NSHostingController(rootView: pane(tab))
            host.sizingOptions = []
            host.preferredContentSize = Self.size
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            addTabViewItem(item)
        }
    }

    required init?(coder: NSCoder) { nil }

    func select(_ tab: SettingsTab) {
        selectedTabViewItemIndex = tabs.firstIndex(of: tab) ?? 0
    }

    private func pane(_ tab: SettingsTab) -> AnyView {
        switch tab {
        case .general: AnyView(GeneralPane(model: model))
        case .suggestions: AnyView(SuggestionsPane(model: model))
        case .sources: AnyView(SourcesPane(model: model))
        case .privacy: AnyView(PrivacyPane(model: model))
        case .activity: AnyView(ActivityPane(model: model))
        }
    }
}

extension SettingsTab {
    var title: String {
        switch self {
        case .general: "General"
        case .suggestions: "Suggestions"
        case .sources: "Sources"
        case .privacy: "Privacy"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .suggestions: "circle.dotted"
        case .sources: "folder"
        case .privacy: "hand.raised"
        case .activity: "chart.bar"
        }
    }
}

/// A row's secondary line, under its label.
private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A label with a caption beneath it, for toggles and pickers that need a sentence of explanation.
private struct Titled: View {
    let title: String
    let caption: String?
    init(_ title: String, caption: String? = nil) {
        self.title = title
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let caption { Caption(caption) }
        }
    }
}

/// A row that asks for a macOS permission: a short reason and one button.
private struct PermissionRow: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack {
            Label(text, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(button, action: action).controlSize(.small)
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.loginItem.enabled }, set: { model.loginItem.setEnabled($0) })) {
                    Titled("Open at login", caption: "Starts quietly in the menu bar.")
                }
                .disabled(model.loginItem.updating)
                if model.loginItem.status == .requiresApproval {
                    PermissionRow(text: "Allow Appears in Login Items to finish.", button: "Open Login Items…") { model.loginItem.openSettings() }
                }
                if let error = model.loginItem.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Keyboard shortcuts") {
                LabeledContent {
                    KeyboardShortcuts.Recorder(for: .pull)
                } label: {
                    Titled("Show related", caption: "What do you already have about this window?")
                }
                LabeledContent {
                    KeyboardShortcuts.Recorder(for: .search)
                } label: {
                    Titled("Search", caption: "Find anything by describing it.")
                }
            }
            UpdatesSection(updater: model.updater)
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.loginItem.refresh()
        }
    }
}

// MARK: - Suggestions

struct SuggestionsPane: View {
    @Bindable var model: AppModel
    @State private var calendarAccess = CalendarWatcher.access

    private var suggesting: Bool { model.settings.ambientMode != .off }

    var body: some View {
        Form {
            Section {
                #if DEBUG
                Picker(selection: Binding(get: { model.settings.ambientMode }, set: { model.setAmbientMode($0) })) {
                    Text("On").tag(AmbientMode.on)
                    Text("Log only").tag(AmbientMode.shadow)
                    Text("Off").tag(AmbientMode.off)
                } label: {
                    Titled("Suggest on its own", caption: "“Log only” records what it would have shown, for Activity, without alerting you.")
                }
                #else
                Toggle(isOn: Binding(get: { model.settings.ambientMode == .on }, set: { model.setAmbientMode($0 ? .on : .off) })) {
                    Titled("Suggest on its own", caption: "Alerts you when something you have is a confident match for what you’re working on. Always silent.")
                }
                #endif
                Group {
                    Picker(selection: $model.settings.matchAlertStyle) {
                        ForEach(MatchAlertStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    } label: {
                        Titled("Alert style", caption: model.settings.matchAlertStyle.caption)
                    }
                    Picker(selection: $model.settings.dwell) {
                        Text("1 second (default)").tag(1.0)
                        Text("5 seconds").tag(5.0)
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                    } label: {
                        Titled("Wait before suggesting", caption: "After you switch to a window, document or conversation, Appears waits this long before checking for matches. While typing, it checks after a one-second pause.")
                    }
                    LabeledContent("Suggest") {
                        HStack(spacing: 8) {
                            Text("Fewer").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $model.settings.sensitivity, in: 0...1).frame(width: 180)
                            Text("More").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $model.settings.ambientInSafari) {
                        Titled("Include Safari", caption: "Safari doesn’t say which windows are private, so Appears reads it only when you ask unless this is on.")
                    }
                }
                .disabled(!suggesting)
            }
            Section {
                Picker(selection: Binding(
                    get: { model.settings.calendarContext ? model.settings.calendarLead : 0 },
                    set: { lead in
                        if lead > 0 { model.setCalendarLead(lead) }
                        model.setCalendarContext(lead > 0)
                    }
                )) {
                    Text("Off").tag(0.0)
                    Text("5 minutes before").tag(300.0)
                    Text("10 minutes before").tag(600.0)
                    Text("15 minutes before").tag(900.0)
                    Text("30 minutes before").tag(1_800.0)
                } label: {
                    Titled("Before meetings", caption: "Looks for what you have about a meeting with other people. Events are never stored.")
                }
                .disabled(!suggesting)
                if suggesting, model.settings.calendarContext, calendarAccess != .granted {
                    PermissionRow(text: "Needs access to your calendar.", button: calendarAccess == .notAsked ? "Allow…" : "Open Settings…") {
                        Task {
                            await CalendarWatcher.requestAccess()
                            calendarAccess = CalendarWatcher.access
                            model.startCalendar()
                        }
                    }
                }
            }
            Section {
                LabeledContent {
                    if model.settings.isPaused {
                        Button("Resume") { model.pause(for: nil) }
                    } else {
                        Menu("Pause") {
                            Button("For an hour") { model.pause(for: 3_600) }
                            Button("Until tomorrow") { model.pauseUntilTomorrow() }
                        }
                        .fixedSize()
                    }
                } label: {
                    if let until = model.settings.pausedUntil, model.settings.isPaused {
                        Titled("Paused", caption: "Until \(until.formatted(date: until.timeIntervalSinceNow > 43_200 ? .abbreviated : .omitted, time: .shortened))")
                    } else {
                        Titled("Pause suggestions", caption: "Asking and searching keep working.")
                    }
                }
                .disabled(!suggesting && !model.settings.isPaused)
            }
            Section {
                Toggle(isOn: $model.settings.ocrOnPull) {
                    Titled("Read text in images", caption: "When you ask about a window with no readable text, Appears recognizes the text on screen, on this Mac.")
                }
                if model.settings.ocrOnPull, !ScreenText.isAllowed {
                    PermissionRow(text: "Needs Screen Recording.", button: "Allow…") { FullDiskAccessGuide.openScreenRecording() }
                }
            } header: {
                Text("When you ask")
            }
            Section {
                Toggle(isOn: $model.settings.answerModel) {
                    Titled("Use the answer model", caption: "A model on this Mac reads what you’re asking or working on together with each match, and decides which one answers. Without it, Appears lists matches but never suggests on its own.")
                }
                if model.settings.answerModel, let download = model.modelDownload.answerModel, download.phase != .ready {
                    if download.phase == .failed {
                        PermissionRow(text: download.error ?? "Couldn’t download the answer model.", button: "Retry") { model.retryModelDownload() }
                    } else {
                        LabeledContent("Downloading (\(ByteCountFormatter.string(fromByteCount: download.total, countStyle: .file)))") {
                            ProgressView(value: download.fraction).frame(width: 120)
                        }
                    }
                }
            } header: {
                Text("Answers")
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.settings.answerModel) { model.answerModelChanged() }
        .onChange(of: model.settings.sensitivity) { model.ambientSettingsChanged() }
        .onChange(of: model.settings.dwell) { model.ambientSettingsChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            calendarAccess = CalendarWatcher.access
        }
    }
}

// MARK: - Sources

struct SourcesPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                ReadinessView(model: model, details: true)
                if let status = model.status, status.ready, !status.protectedFoldersReadable {
                    PermissionRow(text: "Documents needs access. Allow it when macOS asks.", button: "Open Settings…") { FullDiskAccessGuide.open() }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { model.settings.sources.notes }, set: { model.settings.sources.notes = $0; model.sourcesChanged() })) {
                    Label("Apple Notes", systemImage: "note.text")
                }
                if model.settings.sources.notes, model.status?.notesReadable == false {
                    PermissionRow(text: "Needs Full Disk Access.", button: "Open Settings…") { FullDiskAccessGuide.open() }
                }
                Toggle(isOn: Binding(get: { model.settings.sources.messages }, set: { model.settings.sources.messages = $0; model.sourcesChanged() })) {
                    Label("Messages and photos", systemImage: "message")
                }
                if model.settings.sources.messages {
                    if model.status?.messagesReadable == false {
                        PermissionRow(text: "Needs Full Disk Access.", button: "Open Settings…") { FullDiskAccessGuide.open() }
                    }
                    contactsRow
                }
            } header: {
                Text("Apps")
            } footer: {
                Caption("Turning a source off removes it from the index.")
            }
            Section {
                ForEach(ItemKind.allCases.filter { $0 != .note && $0 != .message }, id: \.self) { kind in
                    Toggle(kind == .pdf ? "PDFs" : "\(kind.label)s", isOn: Binding(
                        get: { !model.settings.sources.excludedKinds.contains(kind) },
                        set: { include in
                            if include { model.settings.sources.excludedKinds.remove(kind) } else { model.settings.sources.excludedKinds.insert(kind) }
                            model.sourcesChanged()
                        }
                    ))
                }
            } header: {
                Text("Files in your home folder")
            } footer: {
                Caption("Appears skips app data, code checkouts, build output, caches and very large files. iCloud files that aren’t downloaded are found by name.")
            }
            Section("Also include") {
                FolderList(folders: $model.settings.sources.includes, empty: "Add folders outside your home folder, or a code checkout.", watched: model.status?.watchedFolders, unreadable: model.status?.unreadableFolders ?? []) { model.sourcesChanged() }
            }
            Section("Never include") {
                FolderList(folders: $model.settings.sources.excludes, empty: "Add folders Appears should leave alone.") { model.sourcesChanged() }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var contactsRow: some View {
        let contacts = model.contacts
        LabeledContent {
            if contacts.access != .granted {
                Button(contacts.access == .notAsked ? "Allow…" : "Open Settings…") { Task { await contacts.allow() } }
                    .controlSize(.small)
            } else if contacts.loadFailed {
                Button("Retry") { Task { await contacts.refresh(force: true) } }.controlSize(.small)
            }
        } label: {
            Titled("Contact names and photos", caption: contacts.access != .granted
                   ? "Show names instead of phone numbers."
                   : contacts.loadFailed ? "Couldn’t load your contacts." : "On")
        }
        .padding(.leading, 24)
    }
}

private struct FolderList: View {
    @Binding var folders: [String]
    let empty: String
    var watched: [String]? = nil
    var unreadable: [String] = []
    let changed: () -> Void

    var body: some View {
        ForEach(folders, id: \.self) { folder in
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: folder)).resizable().frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    if unreadable.contains(folder) {
                        Caption("Unavailable. Check that it’s connected and readable.")
                    } else if let watched, !watched.contains(folder) {
                        Caption("Waiting for live updates")
                    }
                }
                Spacer()
                Button {
                    folders.removeAll { $0 == folder }
                    changed()
                } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .help("Remove")
            }
        }
        HStack {
            if folders.isEmpty { Caption(empty) }
            Spacer()
            Button("Add Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true
                guard panel.runModal() == .OK else { return }
                for url in panel.urls where !folders.contains(url.path) { folders.append(url.path) }
                changed()
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Privacy

struct PrivacyPane: View {
    @Bindable var model: AppModel
    @State private var confirmIndex = false
    @State private var confirmJournal = false

    var body: some View {
        Form {
            Section {
                ForEach(model.settings.excludedApps, id: \.self) { bundle in
                    HStack {
                        appIcon(bundle)
                        Text(appName(bundle))
                        Spacer()
                        Button { model.settings.excludedApps.removeAll { $0 == bundle } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
                HStack {
                    if model.settings.excludedApps.isEmpty { Caption("Add apps Appears should never read.") }
                    Spacer()
                    Menu("Add App") {
                        ForEach(NSWorkspace.shared.runningApplications.filter {
                            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                                && !model.settings.excludedApps.contains($0.bundleIdentifier!)
                        }, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier!) { model.settings.excludedApps.append(app.bundleIdentifier!) }
                        }
                    }
                    .fixedSize()
                    .controlSize(.small)
                }
            } header: {
                Text("Never read")
            } footer: {
                Caption("Appears also always skips password managers, Keychain Access, System Settings, password fields and private browser windows.")
            }
            Section {
                promise("What’s on your screen is never stored.", "eye.slash")
                promise("Your index and history stay on this Mac, out of backups.", "lock.laptopcomputer")
                promise("No analytics or tracking.", "hand.raised")
            } header: {
                Text("Your data")
            }
            Section {
                LabeledContent {
                    Button("Clear…") { confirmJournal = true }
                        .confirmationDialog("Clear the history of suggestions and what you did with them?", isPresented: $confirmJournal) {
                            Button("Clear History", role: .destructive) { Task { await model.engine.send(.deleteJournal) } }
                        }
                } label: {
                    Titled("Suggestion history", caption: "Which suggestions you opened or dismissed, so Appears can learn. Used for Activity.")
                }
                LabeledContent {
                    Button("Delete…") { confirmIndex = true }
                        .confirmationDialog("Delete the index? Appears will read your files again from the start.", isPresented: $confirmIndex) {
                            Button("Delete Index", role: .destructive) { Task { await model.engine.send(.deleteIndex) } }
                        }
                } label: {
                    Titled("Index", caption: "What Appears has read from your sources. It’s rebuilt from scratch.")
                }
            }
            #if DEBUG
            Section("Development") {
                Toggle("Keep context snippets in the log for 14 days", isOn: $model.settings.keepDebugContext)
            }
            #endif
        }
        .formStyle(.grouped)
    }

    private func promise(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(text)
        }
    }

    private func appIcon(_ bundle: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        return Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(named: NSImage.applicationIconName)!)
            .resizable().frame(width: 18, height: 18)
    }

    private func appName(_ bundle: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return bundle }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Activity

struct ActivityPane: View {
    @Bindable var model: AppModel
    @State private var stats: JournalStats?
    @State private var days = 7

    var body: some View {
        Form {
            Section {
                Picker("Period", selection: $days) {
                    Text("Today").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity)
            }
            if let stats, stats.pulls + stats.ambient + stats.shadow + stats.calendar > 0 {
                Section("Shown") {
                    row("When you asked", stats.pulls)
                    row("On its own", stats.ambient)
                    row("Before meetings", stats.calendar)
                    #if DEBUG
                    row("Logged only", stats.shadow)
                    #endif
                }
                Section {
                    row("Opened or previewed", stats.useful)
                    row("Dismissed", stats.dismissed)
                    row("Ignored", stats.ignored)
                    LabeledContent("Useful a day") { Text(stats.usefulPerDay, format: .number.precision(.fractionLength(1))).monospacedDigit() }
                } header: {
                    Text("What you did")
                }
                Section {
                    percentRow("Top result used, when you asked", stats.pullPrecisionAt1)
                    percentRow("Any result used, when you asked", stats.pullPrecisionAt3)
                    percentRow("Used, when suggested", stats.ambientPrecision)
                    percentRow("Used, before meetings", stats.calendarPrecision)
                    #if DEBUG
                    percentRow("Log-only pick matched a later ask", stats.shadowPrecision)
                    #endif
                } header: {
                    Text("How often it helped")
                }
            } else {
                Section {
                    ContentUnavailableView("Nothing yet", systemImage: "chart.bar", description: Text("Ask Appears about a window, and what it showed you appears here."))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: days) { stats = await model.engine.stats(days: days) }
    }

    private func row(_ label: String, _ value: Int) -> some View {
        LabeledContent(label) { Text(value.formatted()).monospacedDigit() }
    }

    private func percentRow(_ label: String, _ value: Double?) -> some View {
        LabeledContent(label) { Text(value.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–").monospacedDigit() }
    }
}
