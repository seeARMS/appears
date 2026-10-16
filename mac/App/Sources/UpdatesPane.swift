import SwiftUI

/// The Updates section of Settings' General pane. Kept free of the app's other types so
/// `mac/scripts/test-updates.sh` can build it alone with `Updater`.
struct UpdatesSection: View {
    @Bindable var updater: Updater

    var body: some View {
        Section("Updates") {
            LabeledContent {
                if updater.availableVersion != nil {
                    Button("Update…") { updater.checkNow() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!updater.canCheck)
                } else {
                    Button("Check Now") { updater.checkNow() }
                        .disabled(!updater.canCheck)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if let version = updater.availableVersion {
                        Text("Version \(version) is available")
                        Text("You have \(updater.currentVersion).").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Appears \(updater.currentVersion)")
                        if let error = updater.configurationError {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                        } else if let date = updater.lastChecked {
                            Text("Last checked \(date.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                                .help(date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
            }
            Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
        }
    }
}
