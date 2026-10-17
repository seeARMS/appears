import AppKit
import AppearsCore

/// Exercise the native Related panel through the same toggle used by the status item.
/// A controlled late reply verifies that closing during a lookup cannot reopen it.
@MainActor
func verifyRelatedPanel(_ app: AppModel) async {
    var replies: [CheckedContinuation<Void, Never>] = []
    let controller = StatusController(model: app, pull: {
        await withCheckedContinuation { replies.append($0) }
        app.onShow?(true)
    })
    func wait(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("The controlled Related panel did not settle")
    }
    controller.togglePull()
    await wait { replies.count == 1 }
    controller.close()
    replies.removeFirst().resume()
    await Task.yield()
    precondition(!controller.isVisible, "A cancelled lookup cannot reopen Related")
    controller.togglePull()
    await wait { replies.count == 1 }
    replies.removeFirst().resume()
    await wait { controller.isVisible }
    // No timer or hover owns the panel: it stays until another deliberate toggle.
    try? await Task.sleep(for: .seconds(1))
    precondition(controller.isVisible)
    controller.togglePull()
    precondition(!controller.isVisible, "A second status-item toggle closes Related")
    app.onShow = nil
    print("Verified Related stays open, toggles closed, and rejects a late reply after closing")
}

@MainActor
private final class SearchFixture {
    var calls: [String] = []
    var replies: [CheckedContinuation<RecallResponse, any Error>] = []
    var opens: [CheckedContinuation<Bool, Never>] = []
    func open(_ item: Item) async -> Bool {
        await withCheckedContinuation { opens.append($0) }
    }
    func search(_ request: SearchRequest) async throws -> RecallResponse {
        calls.append(request.text)
        return try await withCheckedThrowingContinuation { replies.append($0) }
    }
    func fail() { replies.removeFirst().resume(throwing: EngineClient.EngineError(message: "Synthetic search failure")) }
    func respond(_ suggestions: [Suggestion], at index: Int = 0) {
        let encoded = String(decoding: try! JSONEncoder().encode(suggestions), as: UTF8.self)
        let json = "{\"suggestions\":\(encoded),\"query\":{\"entities\":[],\"rareTerms\":[],\"denseCharacters\":20},\"milliseconds\":1}"
        replies.remove(at: index).resume(returning: try! JSONDecoder().decode(RecallResponse.self, from: Data(json.utf8)))
    }
}

/// Behavioral UI checks use made-up results and a controlled backend, never XPC or files.
@MainActor
func verifySearchUpdates(_ app: AppModel, suggestions: [Suggestion]) async {
    let fixture = SearchFixture()
    let model = SearchModel(app: app, search: fixture.search, openItem: fixture.open)
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
    let openedDuringUpdate = await model.open(suggestions[0])
    precondition(model.isSearching && !openedDuringUpdate, "An old result must not open during an update")
    await wait { fixture.calls.count == 2 }
    model.query = "kitchen permit"
    // The replacement must dispatch while the previous backend call is still suspended.
    await wait { fixture.calls.count == 3 }
    precondition(model.results == suggestions && model.isSearching)
    fixture.respond(Array(suggestions.reversed()), at: 1)
    await wait { !model.isSearching }
    precondition(model.selected?.id == selected, "Selection follows the same item across reordering")
    fixture.respond([suggestions[0]]) // A late, superseded reply must not replace newer results.
    await Task.yield()
    precondition(model.results == Array(suggestions.reversed()) && !model.isSearching)
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
    precondition(model.query.isEmpty && model.results.isEmpty && model.sourcePreview == nil)
    model.begin()
    model.query = "retry"
    await wait { fixture.calls.count == 7 }
    fixture.respond(suggestions, at: 1)
    await wait { !model.isSearching }
    fixture.respond([]) // A previous window session cannot clear the reopened window.
    await Task.yield()
    precondition(model.results == suggestions && !model.isSearching)
    model.query = "failed update"
    await wait { fixture.calls.count == 8 }
    fixture.fail()
    await wait { !model.isSearching }
    precondition(model.error != nil && model.results.isEmpty, "A failed update must not leave an old query actionable")
    model.clear()
    let before = fixture.calls.count
    model.begin()
    model.query = "first draft"
    model.query = "second draft"
    model.query = "final draft"
    await wait { fixture.calls.count == before + 1 }
    precondition(fixture.calls.last == "final draft", "Typing inside the debounce sends only the latest query")
    fixture.respond(suggestions)
    await wait { !model.isSearching }
    for reopen in [false, true] {
        let pendingOpen = Task { await model.open(suggestions[0]) }
        await wait { fixture.opens.count == 1 }
        if reopen { model.clear(); model.begin() }
        let calls = fixture.calls.count
        model.query = reopen ? "reopened query" : "newer query"
        fixture.opens.removeFirst().resume(returning: true)
        let shouldClose = await pendingOpen.value
        precondition(!shouldClose && model.hasQuery, "A stale open completion must not close a newer search or reopened window")
        await wait { fixture.calls.count == calls + 1 }
        fixture.respond(suggestions)
        await wait { !model.isSearching }
    }
    for success in [false, true] {
        let pendingOpen = Task { await model.open(suggestions[0]) }
        await wait { fixture.opens.count == 1 }
        fixture.opens.removeFirst().resume(returning: success)
        let shouldClose = await pendingOpen.value
        precondition(shouldClose == success, "Only a successful open in the current search should close it")
    }
    model.clear()
    await verifyXPCCancellation()
    print("Verified debounce, query replacement, stale replies and open completions, clear/reopen, selection, source changes, failures and XPC cancellation races")
}

/// Exercise the actual reply bridge without starting the engine or touching user files.
private func verifyXPCCancellation() async {
    let cancelled = XPCReply()
    cancelled.finish(.failure(CancellationError()))
    do {
        let _: Data = try await withCheckedThrowingContinuation { continuation in
            precondition(!cancelled.install(continuation))
        }
        preconditionFailure("Cancellation before installation must resume the waiter")
    } catch { precondition(error is CancellationError) }
    let racing = XPCReply()
    do {
        let _: Data = try await withCheckedThrowingContinuation { continuation in
            precondition(racing.install(continuation))
            racing.finish(.failure(CancellationError()))
            racing.finish(.success(Data()))
            racing.finish(.failure(EngineClient.EngineError(message: "Late synthetic XPC error")))
        }
        preconditionFailure("A late reply cannot replace cancellation")
    } catch { precondition(error is CancellationError) }
    await verifyXPCRoundTripCancellation()
}

private actor XPCSearchFixture {
    typealias Reply = @Sendable (Data?, String?) -> Void
    var requests: [SearchToken] = []
    var cancellations: [SearchToken] = []
    private var pending: [(SearchToken, Reply)] = []

    func receive(_ method: String, payload: Data, reply: @escaping Reply) {
        if method == EngineMethod.search.rawValue {
            let request = try! JSONDecoder().decode(SearchRequest.self, from: payload)
            requests.append(request.token!)
            pending.append((request.token!, reply))
        } else if method == EngineMethod.cancelSearch.rawValue {
            cancellations.append(try! JSONDecoder().decode(SearchToken.self, from: payload))
            reply(Data("{}".utf8), nil)
        } else { reply(nil, "Unexpected fixture method") }
    }

    func respond(_ token: SearchToken) {
        let index = pending.firstIndex { $0.0 == token }!
        let (_, reply) = pending.remove(at: index)
        reply(Data("{\"suggestions\":[],\"query\":{\"entities\":[],\"rareTerms\":[],\"denseCharacters\":20},\"milliseconds\":1}".utf8), nil)
    }
}

private final class XPCSearchService: NSObject, EngineXPC, NSXPCListenerDelegate, @unchecked Sendable {
    let state = XPCSearchFixture()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: EngineXPC.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func call(_ method: String, payload: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        Task { await state.receive(method, payload: payload, reply: reply) }
    }
}

/// Real XPC messages with a deliberately delayed service, separate from the installed app.
private func verifyXPCRoundTripCancellation() async {
    let service = XPCSearchService()
    let listener = NSXPCListener.anonymous()
    listener.delegate = service
    listener.resume()
    defer { listener.invalidate() }
    let endpoint = listener.endpoint
    let client = EngineClient(makeConnection: { NSXPCConnection(listenerEndpoint: endpoint) })
    func wait(_ condition: () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("The controlled XPC request did not settle")
    }
    let session = UUID()
    let first = SearchToken(session: session, revision: 1)
    let second = SearchToken(session: session, revision: 2)
    let old = Task { try await client.search(SearchRequest(text: "synthetic first query", token: first)) }
    await wait { await service.state.requests == [first] }
    old.cancel()
    await wait { await service.state.cancellations == [first] }
    do { _ = try await old.value; preconditionFailure("XPC cancellation must resume without a service reply") }
    catch { precondition(error is CancellationError) }
    let latest = Task { try await client.search(SearchRequest(text: "synthetic replacement query", token: second)) }
    await wait { await service.state.requests == [first, second] }
    await service.state.respond(second)
    do { _ = try await latest.value } catch { preconditionFailure("The replacement XPC request must complete: \(error)") }
    await service.state.respond(first) // The old reply races the already cancelled continuation.
    print("Verified cancellation messages and independent replacements over a real XPC connection")
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

/// Open the real Settings window (invisibly) and check every tab: the window is titled after
/// the tab, and the pane fills the area under the toolbar instead of being centered and
/// clipped inside a smaller one.
@MainActor
func verifySettingsWindow(_ model: AppModel, out: URL) {
    let window = SettingsTabsController.makeWindow(model: model)
    let tabs = window.contentViewController as! SettingsTabsController
    window.alphaValue = 0
    window.orderFront(nil)
    defer { window.close() }
    for tab in [SettingsTab.general, .suggestions, .sources, .privacy, .activity] {
        tabs.select(tab)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let content = window.contentLayoutRect.size
        let pane = tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController!.view
        let paneRect = pane.convert(pane.bounds, to: nil)
        precondition(window.title == tab.title, "Settings window must be titled \(tab.title), not \(window.title)")
        precondition(abs(content.width - SettingsTabsController.size.width) < 1 && abs(content.height - SettingsTabsController.size.height) < 1,
                     "Settings content area is \(content), expected \(SettingsTabsController.size)")
        precondition(window.contentLayoutRect.insetBy(dx: -1, dy: -1).contains(paneRect) && abs(paneRect.width - content.width) < 1 && abs(paneRect.height - content.height) < 1,
                     "\(tab.title) pane is \(paneRect), expected to fill \(window.contentLayoutRect)")
        if tab == .general, let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "settings-window.png"))
        }
    }
    print("Verified the Settings window's size, titles and pane layout for every tab")
}
