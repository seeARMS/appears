import AppKit
import AppearsContext
import AppearsCore
import KeyboardShortcuts
import SwiftUI

/// Setup in four short pages, each led by an illustration of what you get. Only
/// Accessibility is required; the rest is optional and can be changed in Settings.
struct OnboardingView: View {
    @Bindable var model: AppModel
    let done: () -> Void
    /// Remembered, so a relaunch (System Settings asks for one after granting Full Disk
    /// Access) comes back to the same page.
    @AppStorage("onboardingStep") private var step = 0
    @State private var trusted = ContextReader.isTrusted
    @State private var screen = ScreenText.isAllowed
    @State private var fullDisk = FullDiskAccessGuide.isGranted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let pages = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Illustration(scene: [.moment, .notice, .gather, .ready][min(step, pages - 1)])
                .id(step)
                .padding(.bottom, 24)
            Group {
                switch step {
                case 0: welcome
                case 1: accessibility
                case 2: yourStuff
                default: ready
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? Theme.foreground : Theme.border)
                            .frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: step)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 }.buttonStyle(OutlineButtonStyle()) }
                Button(primaryLabel) { advance() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
                    .opacity(step == 1 && !trusted ? 0.5 : 1)
                    .disabled(step == 1 && !trusted)
            }
        }
        .padding(32)
        .frame(width: 560, height: 640)
        .background(Theme.background)
        .onReceive(timer) { _ in
            trusted = ContextReader.isTrusted
            screen = ScreenText.isAllowed
            fullDisk = FullDiskAccessGuide.isGranted
        }
    }

    private var primaryLabel: String {
        switch step {
        case 0: "Get started"
        case 3: "Start using Appears"
        default: "Continue"
        }
    }

    private func advance() {
        if step >= pages - 1 {
            model.settings.onboarded = true
            step = 0
            Task { await model.engine.send(.settings, model.engineSources); await model.engine.send(.rescan) }
            done()
        } else {
            step += 1
        }
    }

    // MARK: - Pieces

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 24, weight: .semibold)).tracking(-0.5).foregroundStyle(Theme.foreground).padding(.bottom, 8)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).font(.system(size: 13.5)).lineSpacing(2).foregroundStyle(Theme.mutedForeground)
            .fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
    }

    private func highlight(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.foreground)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.muted))
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.foreground)
        }
    }

    private var shortcutText: String {
        KeyboardShortcuts.getShortcut(for: .pull)?.description ?? "your shortcut"
    }

    // MARK: - Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("The right file, right when you need it")
            paragraph("Writing to your contractor? Appears brings back the photo of their quote. Planning a trip? There's the itinerary from last time. It finds what you already have, so you never have to go digging.")
            VStack(alignment: .leading, spacing: 9) {
                highlight("photo.on.rectangle.angled", "Finds photos, PDFs, screenshots and notes by what's in them")
                highlight("moon.zzz", "Stays out of your way until it has something good")
                highlight("command", "Ask anytime with \(shortcutText)")
            }
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Let Appears see what you're working on")
            paragraph("To know what's related, Appears looks at the window in front of you, like the email you're writing or the page you're reading. It skips passwords and private windows, and nothing leaves your Mac.")
            permission(
                granted: trusted, label: "Accessibility", detail: "Lets Appears read the window you're in",
                button: "Allow…", action: { ContextReader.requestTrust() }
            )
            if !trusted {
                Text("Turn on Appears in the list that opens, then come back here.")
                    .font(.system(size: 12)).foregroundStyle(Theme.mutedForeground).padding(.top, 8)
            }
        }
    }

    private var yourStuff: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Bring in more of your stuff")
            paragraph("Appears already looks through the files in your home folder. These two are optional extras.")
            VStack(spacing: 8) {
                permission(
                    granted: fullDisk, label: "Full Disk Access", detail: "Adds your Apple Notes, with fewer prompts along the way",
                    button: "Add…", action: { FullDiskAccessGuide.open() }
                )
                permission(
                    granted: screen, label: "Screen Recording", detail: "Helps in apps like Google Docs that hide their text",
                    button: "Allow…", action: { FullDiskAccessGuide.openScreenRecording() }
                )
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("You're all set")
            paragraph("Appears is getting to know your files now; the first pass takes a little while. Keep working, and when something useful turns up, a dot appears in the menu bar.")
            VStack(spacing: 0) {
                HStack {
                    Text("Ask anytime").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.foreground)
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .pull)
                }
                .padding(.vertical, 10)
                Rectangle().fill(Theme.border).frame(height: 1)
                Toggle(isOn: Binding(get: { model.settings.ambientMode == .on }, set: { model.setAmbientMode($0 ? .on : .shadow) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggest things on its own").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.foreground)
                        Text("Only when it's sure, and never more than a few times an hour.")
                            .font(.system(size: 12)).foregroundStyle(Theme.mutedForeground)
                    }
                }
                .toggleStyle(.switch)
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
        }
    }

    private func permission(granted: Bool, label: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(granted ? Theme.accent : Theme.border)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.foreground)
                Text(granted ? "On" : detail).font(.system(size: 12)).foregroundStyle(Theme.mutedForeground)
            }
            Spacer()
            if !granted { Button(button, action: action).buttonStyle(OutlineButtonStyle()) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }
}
