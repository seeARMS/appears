import AppearsCore
import SwiftUI

/// Appears during onboarding and stays available from the panel and Settings.
/// It never disables onboarding or asks for an extra permission.
struct ModelDownloadView: View {
    let status: ModelDownloadStatus
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                if status.phase == .failed { Button("Retry", action: retry).buttonStyle(OutlineButtonStyle()) }
                else if status.phase == .downloading { Text("\(Int(status.fraction * 100))%").monospacedDigit().font(.system(size: 11)) }
            }
            .foregroundStyle(Theme.foreground)
            if status.phase == .downloading {
                ProgressView(value: status.fraction).tint(Theme.accent)
                Text("\(ByteCountFormatter.string(fromByteCount: status.received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: status.total, countStyle: .file)) · You can keep setting up.")
                    .font(.system(size: 11)).foregroundStyle(Theme.mutedForeground)
            } else {
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.muted))
    }
    private var title: String {
        switch status.phase {
        case .waiting: "Preparing the on-device model"
        case .downloading: "Downloading the on-device model"
        case .verifying: "Checking the on-device model"
        case .ready: "On-device model ready"
        case .failed: "Model download paused"
        }
    }
    private var detail: String {
        switch status.phase {
        case .failed: status.error ?? "Check your internet connection, then retry."
        case .ready: "The model stays on this Mac. Future launches work offline."
        default: "Keep setting up. Appears will start reading your files when the model is ready."
        }
    }
}
