import AppKit
import AppearsContext
import AppearsCore
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralPane(model: model).tabItem { Label("General", systemImage: "circle.dotted") }
            UpdatesPane(updater: model.updater).tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            SourcesPane(model: model).tabItem { Label("Sources", systemImage: "folder") }
            PrivacyPane(model: model).tabItem { Label("Privacy", systemImage: "lock") }
            StatsPane(model: model).tabItem { Label("Stats", systemImage: "chart.bar") }
        }
        .frame(width: 560, height: 620)
        .padding(.top, 8)
    }
}

struct GeneralPane: View {
    @Bindable var model: AppModel
    @State private var calendarAccess = CalendarWatcher.access

    var body: some View {
        Form {
            Section {
                LabeledContent("Ask Appears") { KeyboardShortcuts.Recorder(for: .pull) }
                LabeledContent("Search Appears") { KeyboardShortcuts.Recorder(for: .search) }
                Picker("Suggest on its own", selection: Binding(get: { model.settings.ambientMode }, set: { model.setAmbientMode($0) })) {
                    Text("On").tag(AmbientMode.on)
                    Text("Log only (shadow)").tag(AmbientMode.shadow)
                    Text("Off").tag(AmbientMode.off)
                }
                LabeledContent("Match selectivity") {
                    HStack {
                        Text("Stricter").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $model.settings.sensitivity, in: 0...1)
                        Text("Broader").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Wait while reading") {
                    Picker("", selection: $model.settings.dwell) {
                        Text("5 seconds").tag(5.0)
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            } footer: {
                Text("After typing, Appears looks after a two-second pause. New suggestions signal at least one minute apart. Ignoring or closing one doesn’t slow the next.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("“Log only” looks on its own and records what it would have shown, without changing the menu bar. Useful for checking whether it would be right before letting it interrupt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Read the window with OCR when it has no readable text (on ask only)", isOn: $model.settings.ocrOnPull)
                if !ScreenText.isAllowed {
                    Button("Allow Screen Recording…") { FullDiskAccessGuide.openScreenRecording() }
                }
                Toggle("Suggest on its own in Safari", isOn: $model.settings.ambientInSafari)
                Text("Safari can't say whether a window is private, so Appears only reads Safari when you ask, unless this is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Look ahead to meetings", selection: Binding(
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
                }
                if model.settings.calendarContext, calendarAccess != .granted {
                    HStack {
                        Text("Needs access to your calendar.").foregroundStyle(.secondary)
                        Spacer()
                        Button(calendarAccess == .notAsked ? "Allow…" : "Open Settings…") {
                            Task {
                                await CalendarWatcher.requestAccess()
                                calendarAccess = CalendarWatcher.access
                                model.startCalendar()
                            }
                        }
                    }
                }
            } footer: {
                Text("Before a meeting with other people, Appears looks for what you already have about it, by the same rules as everything else. Events are read in memory and never stored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    if model.settings.isPaused {
                        Text("Paused until \(model.settings.pausedUntil!.formatted(date: .omitted, time: .shortened))")
                        Spacer()
                        Button("Resume") { model.pause(for: nil) }
                    } else {
                        Text("Pause")
                        Spacer()
                        Button("For an hour") { model.pause(for: 3_600) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.settings.sensitivity) { model.ambientSettingsChanged() }
        .onChange(of: model.settings.dwell) { model.ambientSettingsChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            calendarAccess = CalendarWatcher.access
        }
    }
}

struct SourcesPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.modelDownload.phase != .ready {
                    ModelDownloadView(status: model.modelDownload, retry: model.retryModelDownload)
                }
                if let status = model.status {
                    LabeledContent("Indexed") {
                        Text(summary(status.counts))
                    }
                    if status.progress.phase != .idle {
                        LabeledContent("Now") { Text(progress(status.progress)) }
                    }
                    if !status.protectedFoldersReadable {
                        Text("Appears can't read Documents yet. Allow it when macOS asks, or give it Full Disk Access.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let error = status.error { Text(error).font(.caption).foregroundStyle(.red) }
                } else {
                    Text("Starting the engine…").foregroundStyle(.secondary)
                }
            } header: {
                Text("Everything sensible in your home folder, by default")
            } footer: {
                Text("Appears skips app data (~/Library), code checkouts, build output, caches and very large files. iCloud files that aren't on this Mac are indexed by name only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apple Notes") {
                Toggle("Include Apple Notes", isOn: Binding(get: { model.settings.sources.notes }, set: { model.settings.sources.notes = $0; model.sourcesChanged() }))
                if model.settings.sources.notes, model.status?.notesReadable == false {
                    HStack {
                        Text("Needs Full Disk Access.").font(.caption).foregroundStyle(.secondary)
                        Button("Open Settings") { FullDiskAccessGuide.open() }
                    }
                }
            }
            Section {
                Toggle("Include Messages and photos", isOn: Binding(
                    get: { model.settings.sources.messages },
                    set: { model.settings.sources.messages = $0; model.sourcesChanged() }
                ))
                if model.settings.sources.messages, model.status?.messagesReadable == false {
                    HStack {
                        Text("Needs Full Disk Access.").font(.caption).foregroundStyle(.secondary)
                        Button("Open Settings") { FullDiskAccessGuide.open() }
                    }
                }
            } header: {
                Text("Messages")
            } footer: {
                Text("Indexes conversations and photos already on this Mac. Everything stays on your Mac. Turning this off removes Messages and their photos from the index.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Also include") {
                FolderList(folders: $model.settings.sources.includes, empty: "Folders outside your home folder, or a code checkout you want indexed.") { model.sourcesChanged() }
            }
            Section("Never include") {
                FolderList(folders: $model.settings.sources.excludes, empty: "Nothing excluded.") { model.sourcesChanged() }
                ForEach(ItemKind.allCases.filter { $0 != .note && $0 != .message }, id: \.self) { kind in
                    Toggle("Skip \(kind.label.lowercased())s", isOn: Binding(
                        get: { model.settings.sources.excludedKinds.contains(kind) },
                        set: { skip in
                            if skip { model.settings.sources.excludedKinds.insert(kind) } else { model.settings.sources.excludedKinds.remove(kind) }
                            model.sourcesChanged()
                        }
                    ))
                }
            }
            Section {
                Button("Look for new items now") { Task { await model.engine.send(.rescan) } }
            }
        }
        .formStyle(.grouped)
    }

    private func summary(_ counts: IndexCounts) -> String {
        let parts = ItemKind.allCases.compactMap { kind -> String? in
            guard let n = counts.indexed[kind], n > 0 else { return nil }
            return "\(n.formatted()) \(kind.label.lowercased())s"
        }
        return parts.isEmpty ? "Nothing yet" : parts.joined(separator: ", ")
    }

    private func progress(_ progress: IndexProgress) -> String {
        switch progress.phase {
        case .scanning: "Looking through folders (\(progress.scanned.formatted()) found)"
        case .indexing: "Reading \(progress.done.formatted()) of \(progress.total.formatted())"
        case .paused: "Paused: \(progress.pausedReason ?? "")"
        case .idle: "Up to date"
        }
    }
}

private struct FolderList: View {
    @Binding var folders: [String]
    let empty: String
    let changed: () -> Void

    var body: some View {
        if folders.isEmpty {
            Text(empty).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(folders, id: \.self) { folder in
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    folders.removeAll { $0 == folder }
                    changed()
                } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
        }
        Button("Add Folder…") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            guard panel.runModal() == .OK else { return }
            for url in panel.urls where !folders.contains(url.path) { folders.append(url.path) }
            changed()
        }
    }
}

private struct PrivacyPane: View {
    @Bindable var model: AppModel
    @State private var confirmIndex = false
    @State private var confirmJournal = false

    var body: some View {
        Form {
            Section("What Appears keeps") {
                Text("An index of your own files, notes and Messages, and a log of which suggestions you opened or dismissed. The log has a salted fingerprint of each context, never its text. Both stay in the engine's sandbox container and are excluded from backups.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Delete the index…") { confirmIndex = true }
                    .confirmationDialog("Delete the index? Appears will read your files again from the start.", isPresented: $confirmIndex) {
                        Button("Delete", role: .destructive) { Task { await model.engine.send(.deleteIndex) } }
                    }
                Button("Delete the suggestion log…") { confirmJournal = true }
                    .confirmationDialog("Delete the log of suggestions and what you did with them?", isPresented: $confirmJournal) {
                        Button("Delete", role: .destructive) { Task { await model.engine.send(.deleteJournal) } }
                    }
            }
            Section("Network") {
                LabeledContent("Engine") { Text("Sandboxed, no network entitlement: macOS blocks it") }
                LabeledContent("This app") { Text("No networking code (it can't be sandboxed: Accessibility isn't allowed there)") }
                Text("Check the engine yourself: codesign -d --entitlements - /Applications/Appears.app/Contents/XPCServices/AppearsEngine.xpc")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Apps Appears never reads") {
                Text("Password managers, Keychain Access, System Settings and secure text fields, always.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.settings.excludedApps, id: \.self) { bundle in
                    HStack {
                        Text(appName(bundle))
                        Spacer()
                        Button { model.settings.excludedApps.removeAll { $0 == bundle } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu("Add Running App") {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier!) {
                            if let bundle = app.bundleIdentifier, !model.settings.excludedApps.contains(bundle) { model.settings.excludedApps.append(bundle) }
                        }
                    }
                }
            }
            #if DEBUG
            Section("Development") {
                Toggle("Keep context snippets in the log for 14 days (dogfooding only)", isOn: $model.settings.keepDebugContext)
            }
            #endif
        }
        .formStyle(.grouped)
    }

    private func appName(_ bundle: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return bundle }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private struct StatsPane: View {
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
            }
            if let stats {
                Section("What Appears has shown you") {
                    row("Useful a day", String(format: "%.1f", stats.usefulPerDay))
                    row("Asked (pulls)", "\(stats.pulls)")
                    row("Suggested on its own", "\(stats.ambient)")
                    row("Logged only (shadow)", "\(stats.shadow)")
                    row("Before meetings", "\(stats.calendar)")
                    row("Opened, previewed or dragged", "\(stats.useful)")
                    row("Dismissed", "\(stats.dismissed)")
                    row("Ignored", "\(stats.ignored)")
                }
                Section("Precision") {
                    row("First result used, when asked", percent(stats.pullPrecisionAt1))
                    row("Any result used, when asked", percent(stats.pullPrecisionAt3))
                    row("Used, when suggested", percent(stats.ambientPrecision))
                    row("Shadow pick matched a later ask", percent(stats.shadowPrecision))
                    row("Used, before meetings", percent(stats.calendarPrecision))
                }
            } else {
                Text("No numbers yet.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: days) { stats = await model.engine.stats(days: days) }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospacedDigit() }
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
    }
}
