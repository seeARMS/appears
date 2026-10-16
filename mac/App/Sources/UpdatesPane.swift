import SwiftUI

struct UpdatesPane: View {
    @Bindable var updater: Updater

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updater.checksAutomatically)
                Text("Checks once a day while Appears is running. You choose when to download and install an update. A new app version downloads its required model automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Installed version", value: updater.currentVersion)
                if let version = updater.availableVersion {
                    Text("Version \(version) is available! You have version \(updater.currentVersion).")
                        .font(.callout.weight(.medium))
                    Button("View Changelog and Update…") { updater.checkNow() }
                        .disabled(!updater.canCheck)
                } else {
                    Button("Check for Updates…") { updater.checkNow() }
                        .disabled(!updater.canCheck)
                }
                if let date = updater.lastChecked {
                    LabeledContent("Last checked") { Text(date, format: .dateTime.month().day().hour().minute()) }
                }
                if let error = updater.configurationError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Changelog") {
                Text("See what's changed in each GitHub release before installing. Update checks never include your files or screen content.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
