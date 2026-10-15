import AppKit
import AppearsContext
import AppearsCore
import KeyboardShortcuts
import SwiftUI

/// Setup, one honest step at a time: what Appears reads, what it never keeps, and the
/// permissions, each with its reason. Only Accessibility is required.
struct OnboardingView: View {
    @Bindable var model: AppModel
    let done: () -> Void
    @State private var step = 0
    @State private var trusted = ContextReader.isTrusted
    @State private var screen = ScreenText.isAllowed
    @State private var notes = NotesReader.isReadable
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mark.padding(.bottom, 22)
            Group {
                switch step {
                case 0: intro
                case 1: accessibility
                case 2: fullDisk
                default: finish
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 16)
            HStack {
                if step > 0 { Button("Back") { step -= 1 }.buttonStyle(OutlineButtonStyle()) }
                Spacer()
                Button(step == 3 ? "Start" : "Continue") { advance() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
                    .opacity(step == 1 && !trusted ? 0.5 : 1)
                    .disabled(step == 1 && !trusted)
            }
        }
        .padding(36)
        .frame(width: 520, height: 560)
        .background(Theme.background)
        .onReceive(timer) { _ in
            trusted = ContextReader.isTrusted
            screen = ScreenText.isAllowed
            notes = NotesReader.isReadable
        }
    }

    private func advance() {
        if step == 3 {
            model.settings.onboarded = true
            Task { await model.engine.send(.settings, model.engineSources); await model.engine.send(.rescan) }
            done()
        } else {
            step += 1
        }
    }

    private var mark: some View {
        HStack(spacing: 10) {
            Mark(size: 36)
            Text("appears").font(.system(size: 22, weight: .bold)).tracking(-0.8).foregroundStyle(Theme.foreground)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 22, weight: .semibold)).tracking(-0.4).foregroundStyle(Theme.foreground).padding(.bottom, 10)
    }

    private func body(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.mutedForeground).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("What you already have, when it matters.")
            body("Appears notices what you're working on and quietly shows related things you already have: an old screenshot, a photo of a quote, a PDF from two years ago.")
            body("Most of the time it shows nothing. When it has something worth seeing, the ring in the menu bar gets a dot. Look when you like. Or press \(shortcutText) to ask.")
            VStack(alignment: .leading, spacing: 8) {
                promise("Reads the window you're in, in memory, and throws it away.")
                promise("Keeps an index of your own files and notes, on this Mac.")
                promise("The part that reads your files can't use the network: macOS blocks it. The menu bar app has no networking code, and it's open source so you can check.")
            }
            .padding(.top, 8)
        }
    }

    private var shortcutText: String {
        KeyboardShortcuts.getShortcut(for: .pull)?.description ?? "the shortcut"
    }

    private func promise(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.foreground)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.mutedForeground).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Let Appears read the window you're in")
            body("macOS calls this Accessibility. Appears uses it to read the title, the text and the selection of the frontmost window when it changes. It skips password fields, password managers and private browser windows.")
            permission(granted: trusted, label: "Accessibility", button: "Open Settings") {
                ContextReader.requestTrust()
            }
            if !trusted {
                Text("Turn on Appears in the list, then come back. If you rebuilt the app, remove the old entry and add it again.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.mutedForeground).padding(.top, 8)
            }
        }
    }

    private var fullDisk: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Your files and notes")
            body("Appears indexes what's in your home folder (Documents, Desktop, Downloads, iCloud Drive, screenshots) and skips app data, code and caches. You can include or exclude folders in Settings.")
            body("Full Disk Access is optional. It lets Appears read Apple Notes, and saves you a permission prompt for each of Desktop, Documents and Downloads.")
            permission(granted: notes, label: "Full Disk Access", button: "Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            .padding(.bottom, 14)
            body("Screen Recording is optional too. When you ask and a window has no readable text (Google Docs, some apps), Appears reads the window's words with on-device OCR, then drops the image. macOS asks again about once a month.")
            permission(granted: screen, label: "Screen Recording", button: "Allow") {
                ScreenText.requestAccess()
            }
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Ready")
            body("Appears will read your files in the background. The first pass takes a while (images are the slow part) and pauses in Low Power Mode.")
            HStack {
                Text("Ask Appears").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.foreground)
                Spacer()
                KeyboardShortcuts.Recorder(for: .pull)
            }
            .padding(.vertical, 8)
            Toggle(isOn: Binding(get: { model.settings.ambientMode == .on }, set: { model.setAmbientMode($0 ? .on : .shadow) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggest on its own").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.foreground)
                    Text("Only when it's confident, never more than a few times an hour, and only a dot in the menu bar.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.mutedForeground)
                }
            }
            .toggleStyle(.switch)
            .padding(.vertical, 8)
        }
    }

    private func permission(granted: Bool, label: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Theme.accent : Theme.mutedForeground)
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.foreground)
            Spacer()
            if !granted { Button(button, action: action).buttonStyle(OutlineButtonStyle()) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }
}
