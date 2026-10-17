import AppKit
import AppearsCore
import SwiftUI

/// The source passage already returned by the engine. No temporary files or extra
/// permissions; closing the enclosing panel drops the preview with its results.
struct SourcePreviewView: View {
    let suggestion: Suggestion
    var title: String? = nil
    var contacts: ContactDirectory? = nil
    let back: () -> Void
    let open: () -> Void

    private var passage: String {
        if suggestion.unit.text.isEmpty { return contacts?.displaySnippet(for: suggestion) ?? suggestion.snippet }
        return contacts?.displayText(suggestion.unit.text, for: suggestion.item) ?? suggestion.unit.text
    }
    private var source: String { suggestion.item.source == .messages ? "Messages" : "Apple Notes" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: back) { Label("Results", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Theme.mutedForeground)
                Spacer()
                Text(source).foregroundStyle(Theme.mutedForeground)
            }
            .font(.system(size: 12)).padding(.bottom, 14)
            Text(title ?? suggestion.item.title)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.foreground)
                .lineLimit(2)
            Text("Match from \(suggestion.item.created.formatted(date: .abbreviated, time: suggestion.item.source == .messages ? .shortened : .omitted))")
                .font(.system(size: 11)).foregroundStyle(Theme.mutedForeground).padding(.top, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let line = suggestion.line { QuotedLine(line: contacts?.displayLine(line, for: suggestion.item) ?? line) }
                    Text(passage.isEmpty ? "No readable passage is available. Open the original to view it." : passage)
                        .font(.system(size: 13)).lineSpacing(4).foregroundStyle(Theme.foreground)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 14)
            }
            .frame(maxHeight: .infinity)
            Text(suggestion.item.source == .messages ? "Indexed conversation around the match" : "Indexed passage from this note")
                .font(.system(size: 11)).foregroundStyle(Theme.mutedForeground).padding(.bottom, 10)
            HStack {
                Button("Copy passage") { copyPassage() }.buttonStyle(OutlineButtonStyle()).disabled(passage.isEmpty)
                Spacer()
                Button("Open in \(source)", action: open).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 350)
        .background(Theme.card)
        .onExitCommand(perform: back)
    }

    func copyPassage() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(passage, forType: .string)
        board.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
    }
}
