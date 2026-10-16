import AppKit
import AppearsCore

@MainActor
private final class SearchFixture {
    var calls: [String] = []
    var replies: [CheckedContinuation<RecallResponse, any Error>] = []
    func search(_ text: String) async throws -> RecallResponse {
        calls.append(text)
        return try await withCheckedThrowingContinuation { replies.append($0) }
    }
    func fail() { replies.removeFirst().resume(throwing: EngineClient.EngineError(message: "Synthetic search failure")) }
    func respond(_ suggestions: [Suggestion]) {
        let encoded = String(decoding: try! JSONEncoder().encode(suggestions), as: UTF8.self)
        let json = "{\"suggestions\":\(encoded),\"query\":{\"entities\":[],\"rareTerms\":[],\"denseCharacters\":20},\"milliseconds\":1}"
        replies.removeFirst().resume(returning: try! JSONDecoder().decode(RecallResponse.self, from: Data(json.utf8)))
    }
}

/// Behavioral UI checks use made-up results and a controlled backend, never XPC or files.
@MainActor
func verifySearchUpdates(_ app: AppModel, suggestions: [Suggestion]) async {
    let fixture = SearchFixture()
    let model = SearchModel(app: app, search: fixture.search)
    func wait(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("The controlled search request did not settle")
    }
    model.begin()
    model.query = "kitchen"
    await wait { fixture.calls.count == 1 }
    fixture.respond(suggestions)
    await wait { !model.isSearching }
    model.moveSelection(1)
    let selected = model.selected!.id
    model.query = "kitchen quote"
    precondition(model.results == suggestions && model.selected?.id == selected)
    precondition(model.isSearching && !model.open(suggestions[0]), "An old result must not open during an update")
    await wait { fixture.calls.count == 2 }
    model.query = "kitchen permit"
    fixture.respond([suggestions[0]]) // This older response must never replace the list.
    await wait { fixture.calls.count == 3 }
    precondition(model.results == suggestions && model.isSearching)
    fixture.respond(Array(suggestions.reversed()))
    await wait { !model.isSearching }
    precondition(model.selected?.id == selected, "Selection follows the same item across reordering")
    model.query = "another query"
    await wait { fixture.calls.count == 4 }
    model.query = ""
    precondition(model.results.isEmpty && !model.isSearching)
    fixture.respond(suggestions)
    await Task.yield()
    precondition(model.results.isEmpty, "An in-flight reply must not restore a cleared query")
    model.query = "private source"
    await wait { fixture.calls.count == 5 }
    fixture.respond(suggestions)
    await wait { !model.isSearching }
    model.refresh(clearResults: true)
    precondition(model.results.isEmpty, "Source changes clear old content immediately")
    await wait { fixture.calls.count == 6 }
    model.clear()
    fixture.respond(suggestions)
    await Task.yield()
    precondition(model.query.isEmpty && model.results.isEmpty && model.sourcePreview == nil)
    model.begin()
    model.query = "retry"
    await wait { fixture.calls.count == 7 }
    fixture.respond(suggestions)
    await wait { !model.isSearching }
    model.query = "failed update"
    await wait { fixture.calls.count == 8 }
    fixture.fail()
    await wait { !model.isSearching }
    precondition(model.error != nil && model.results.isEmpty, "A failed update must not leave an old query actionable")
    model.clear()
    print("Verified stable search results, preserved selection, stale replies, cleared queries, source changes and failed updates")
}

@MainActor
func verifyLaunchBehavior() {
    func event(_ id: AEEventID = AEEventID(kAEOpenApplication)) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: id,
                               targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }
    precondition(!LaunchBehavior.isBackground(event: nil))
    precondition(LaunchBehavior.isBackground(event: nil, isDefaultLaunch: false))
    precondition(!LaunchBehavior.isBackground(event: nil, isDefaultLaunch: true))
    precondition(!LaunchBehavior.isBackground(event: event()))
    let login = event()
    login.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
    precondition(LaunchBehavior.isBackground(event: login))
    let restore = event()
    restore.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: AEKeyword(keyAERestoreAppState))
    precondition(LaunchBehavior.isBackground(event: restore))
    precondition(!LaunchBehavior.isBackground(event: event(AEEventID(kAEReopenApplication))))
    print("Verified quiet login/restoration and deliberate reopen behavior without registering a login item")
}
