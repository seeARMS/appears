import AppKit
import AppearsContext
import AppearsCore

// appears-context: prints what Appears would read from the frontmost window, every three
// seconds, to check coverage app by app. Grant the terminal Accessibility first. Ctrl-C to stop.

guard ContextReader.isTrusted else {
    ContextReader.requestTrust()
    print("Give this terminal the Accessibility permission (System Settings → Privacy & Security → Accessibility), then run again.")
    exit(1)
}

@MainActor func dump() {
    let reader = ContextReader()
    guard let captured = reader.capture() else { print("(nothing readable)"); return }
    let s = captured.snapshot
    let query = QueryBuilder.build(s)
    print("""
        ── \(s.appName) (\(s.bundleID))  \(Date().formatted(date: .omitted, time: .standard))
        title:     \(s.windowTitle)
        document:  \(s.documentPath ?? "–")
        url:       \(s.url ?? "–")\(captured.isPrivate ? "  [PRIVATE]" : "")\(captured.privacyUnknown ? "  [privacy unknown]" : "")\(captured.isSecure ? "  [SECURE FIELD]" : "")
        selection: \(s.selection.prefix(120).replacingOccurrences(of: "\n", with: " ⏎ "))
        focused:   \(s.focusedText.count) chars: \(s.focusedText.prefix(160).replacingOccurrences(of: "\n", with: " ⏎ "))
        visible:   \(s.visibleText.count) chars: \(s.visibleText.prefix(240).replacingOccurrences(of: "\n", with: " ⏎ "))
        recipients: \(s.recipients)
        entities:  \(query.entities)  identifiers: \(query.identifiers)
        """)
}

Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in MainActor.assumeIsolated { dump() } }
MainActor.assumeIsolated { dump() }
RunLoop.main.run()
