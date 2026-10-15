import Foundation
import Testing

@testable import AppearsCore

/// What Vision reads from demo/files/Desktop/IMG_2031.jpg.
private let cabinCard = """
    Welcome to Pine Hollow Cabin!
    WiFi: PineHollow-Guest
    Password: trout-meadow-88
    Hot tub: cover back on please
    Trash pickup Tuesday a.m.
    Emergency: Joan (530) 555-0177
    """

/// What PDFKit reads from demo/files/Documents/Car/Honda service invoice 2023-08.pdf.
private let invoice = """
    EASTSHORE HONDA — SERVICE INVOICE RO# 418820
    Service date: Aug 14, 2023
    Vehicle: 2019 Honda CR-V EX Mileage in: 42,118
    Services performed:
    Maintenance B1: oil and filter, tire rotation $189.95
    Replace cabin air filter $64.00
    Brake fluid replacement $139.00
    Recommended at next visit: rear brake pads (3mm remaining)
    Total: $392.95 Paid by card ending 5521
    """

private func question(_ focused: String, visible: String = "") -> Question? {
    Question(ContextSnapshot(appName: "Messages", windowTitle: "Joan", focusedText: focused, visibleText: visible))
}

/// The question in `text`, which must ask one.
private func asking(_ text: String) throws -> Question {
    try #require(question(text))
}

private func emphasized(_ line: MatchedLine?) -> [String] {
    (line?.segments ?? []).filter(\.emphasized).map(\.text)
}

@Suite struct QuestionTests {
    @Test func asksForAPassword() throws {
        let asked = try #require(question("Thanks Joan! What was the wifi password again?"))
        #expect(asked.words == ["wifi", "password"])
    }

    @Test func whenAsksForADate() throws {
        let asked = try #require(question("CR-V brakes grinding when stopping. When were the brakes last looked at? Call Eastshore Honda."))
        #expect(asked.kinds.contains(.date))
        #expect(asked.words.contains("brakes"))
    }

    @Test func requestsCount() {
        #expect(question("Do you have the wifi password?") != nil)
        #expect(question("I need the account number for the transfer") != nil)
        #expect(question("How much was the quote?")?.kinds.contains(.money) == true)
    }

    @Test func otherQuestionsDont() {
        // From demo/scenarios.json: a passage answers these, not a value.
        #expect(question("What did Priya say about the offsite venue options?") == nil)
        #expect(question("Hi Dana,\n\nThe 14th works. Before you start, can you confirm the quote still covers moving the outlet by the window and the quartz counters? Also, do we need the city inspection before the cabinets go in?") == nil)
        #expect(question("Did you get my email?") == nil)
        #expect(question("How do I reset the router?") == nil)
        #expect(question("Ran the tests and the API checks passed.") == nil)
    }

    @Test func readsTheWindowWhenYoureNotWriting() {
        #expect(question("", visible: "Joan: Can you send me the address of the cabin?")?.kinds.contains(.address) == true)
        // What you're writing comes first.
        #expect(question("Sounds good", visible: "Joan: What's your email?") == nil)
    }

    @Test func headingsArentQuestions() {
        let page = ContextSnapshot(appName: "Safari", windowTitle: "Where to eat in Lisbon — travel guide", visibleText: "When to go. Where to stay. What to pack.")
        #expect(Question(page) == nil)
        let subject = ContextSnapshot(appName: "Mail", windowTitle: "Re: What's the gate code?")
        #expect(Question(subject)?.words.contains("gate") == true)
    }
}

@Suite struct MatchedLineTests {
    @Test func wifiPasswordKeepsItsNetwork() throws {
        let line = try #require(MatchedLine.find(in: cabinCard, for: try asking("What was the wifi password again?")))
        #expect(line.text == "WiFi: PineHollow-Guest\nPassword: trout-meadow-88")
        #expect(emphasized(line).contains("trout-meadow-88"))
        #expect(line.concealed)
    }

    @Test func serviceDateForWhen() throws {
        let asked = try #require(question("When were the brakes last looked at?"))
        let line = try #require(MatchedLine.find(in: invoice, for: asked, terms: ["eastshore honda"]))
        #expect(line.text == "Service date: Aug 14, 2023")
        #expect(emphasized(line) == ["Aug 14, 2023"])
        #expect(!line.concealed)
    }

    @Test func amountsAndPhoneNumbers() throws {
        let total = MatchedLine.find(in: invoice, for: try asking("How much was the total?"))
        #expect(total?.text == "Total: $392.95 Paid by card ending 5521")
        #expect(emphasized(total) == ["$392.95"])

        let phone = MatchedLine.find(in: cabinCard, for: try asking("What's Joan's phone number?"))
        #expect(phone?.text == "Emergency: Joan (530) 555-0177")
        #expect(emphasized(phone) == ["(530) 555-0177"])
    }

    @Test func inlineLabels() throws {
        let line = MatchedLine.find(in: invoice, for: try asking("What was the mileage?"))
        #expect(line?.text == "Vehicle: 2019 Honda CR-V EX Mileage in: 42,118")
        #expect(emphasized(line) == ["42,118"])
    }

    @Test func labelOnItsOwnLine() throws {
        let text = "Check-in after 4pm\nGate code:\n4417#\nCheckout: 11am"
        let line = MatchedLine.find(in: text, for: try asking("What's the gate code?"))
        #expect(line?.text == "Gate code: 4417#")
        #expect(line?.concealed == true)
    }

    @Test func networkAndPasswordStayTogether() throws {
        let text = "House notes\nNetwork: Hollow5G\nPassword: maple-77\nCheckout: 11am"
        let line = MatchedLine.find(in: text, for: try asking("Do you have the wifi password?"))
        #expect(line?.text == "Network: Hollow5G\nPassword: maple-77")
    }

    @Test func nothingWhenNoLineAnswers() throws {
        // A date was asked for, and there's none.
        #expect(MatchedLine.find(in: cabinCard.replacingOccurrences(of: "Trash pickup Tuesday a.m.\n", with: ""), for: try asking("When did we last stay there?")) == nil)
        #expect(MatchedLine.find(in: "Grandma Ruth's lemon cake\n2 cups flour, 1 cup sugar", for: try asking("What was the wifi password?")) == nil)
    }

    @Test func longParagraphsQuoteOneSentence() throws {
        let filler = String(repeating: "We talked about the schedule and the budget for a while. ", count: 4)
        let text = filler + "The alarm code is 2580 and the spare key is under the planter. " + filler
        let line = try #require(MatchedLine.find(in: text, for: try asking("What's the alarm code?")))
        #expect(line.text == "The alarm code is 2580 and the spare key is under the planter.")
        #expect(emphasized(line) == ["2580"])
    }

    @Test func cutsLongLinesAroundTheAnswer() throws {
        let text = String(repeating: "word ", count: 60) + "Password: trout-meadow-88 " + String(repeating: "word ", count: 60)
        let line = try #require(MatchedLine.find(in: text.replacingOccurrences(of: "\n", with: " "), for: try asking("What was the wifi password?")))
        #expect(line.text.count <= MatchedLine.displayLimit + 2)
        #expect(line.text.hasPrefix("…") && line.text.hasSuffix("…"))
        #expect(line.text.contains("trout-meadow-88"))
    }
}

@Suite struct RecallLineTests {
    @Test func suggestionCarriesTheLine() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let embedder = HashingEmbedder()
        let vectors = VectorIndex(dimension: embedder.dimension)
        let indexer = Indexer(store: store, vectors: vectors, embedder: embedder, settings: SourceSettings())
        let old = Date().addingTimeInterval(-400 * 86_400)
        for (name, text) in [("cabin card.txt", cabinCard), ("invoice.txt", invoice), ("notes.txt", "Pine Hollow trip ideas: hike to the lake, bring the kayak.")] {
            let path = folder.appending(path: name).path
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
            let item = Item(source: .file, path: path, kind: .document, title: name, size: Int64(text.count), created: old, modified: old, lastUsed: nil)
            var stored = item
            stored.id = try store.record(item, signature: "x").0
            try await indexer.index(stored)
        }
        let recall = Recall(store: store, vectors: vectors, embedder: embedder)

        let asked = try await recall.run(RecallRequest(context: .text("Thanks Joan! What was the Pine Hollow wifi password again?"), trigger: .pull))
        let card = try #require(asked.suggestions.first { $0.item.title == "cabin card.txt" })
        #expect(card.line?.text == "WiFi: PineHollow-Guest\nPassword: trout-meadow-88")

        // Not a question: the snippet, no line.
        let told = try await recall.run(RecallRequest(context: .text("Booked Pine Hollow cabin with Joan for the long weekend, wifi included."), trigger: .pull))
        #expect(told.suggestions.allSatisfy { $0.line == nil })
    }
}
