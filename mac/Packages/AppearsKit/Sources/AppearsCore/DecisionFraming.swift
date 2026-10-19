import Foundation

/// How a lookup is put to the decision model: what the person is doing (the record), what
/// Appears needs to know (the question), and the candidates as options, plus "none". Only the
/// active question decides when there is one; the surrounding screen is context for it.
enum DecisionFraming {
    /// Candidates per decision; the model decides best with up to about 16 options, and one
    /// of them is "none".
    static let candidates = DecisionPrompt.maximumOptions - 1
    static let none = "none"

    enum Kind: Equatable {
        /// A question in the draft or selection: which item states its answer.
        case question
        /// Writing or selecting something that isn't a question: which item it's about.
        case writing
        /// Only looking: which item would help with what's on screen.
        case looking
        /// A meeting coming up: which item would help prepare for it.
        case meeting
    }

    static func kind(_ context: ContextSnapshot, plan: RetrievalPlan, query: Query) -> Kind {
        if context.origin == .calendar { return .meeting }
        guard plan.hasActiveText else { return .looking }
        let active = plan.primary.selection
        let asks = query.recallIntent || Question(plan.primary) != nil
            || active.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        return asks ? .question : .writing
    }

    static func request(_ context: ContextSnapshot, plan: RetrievalPlan, query: Query, candidates: [Suggestion],
                        openConversations: Set<Int64> = [], texts: [Int64: String] = [:]) -> DecisionRequest {
        let kind = kind(context, plan: plan, query: query)
        let active = clip(QueryBuilder.clean(plan.primary.selection), 1_500)
        let verb = QueryBuilder.clean(context.selection).isEmpty ? "is typing" : "selected"
        let question: String
        let noneText: String
        switch kind {
        case .question:
            question = "The person \(verb): “\(active)”. Which of their own items states the answer?"
            noneText = "None of these items states the answer"
        case .writing:
            question = "The person \(verb): “\(active)”. Which of their own items would they want in front of them for this?"
            noneText = "None of these items is about this"
        case .looking:
            question = "Which of the person's own items would help them with what is on their screen right now?"
            noneText = "None of these items would help with this right now"
        case .meeting:
            question = "The person has this meeting soon. Which of their own items would help them prepare for it?"
            noneText = "None of these items would help with this meeting"
        }
        let options = candidates.enumerated().map { index, candidate in
            DecisionOption(name: "i\(index + 1)", description: describe(candidate, openConversations: openConversations,
                                                                           text: texts[candidate.id]))
        } + [DecisionOption(name: none, description: noneText)]
        return DecisionRequest(record: record(context, kind: kind, conversation: !openConversations.isEmpty),
                               question: question, options: options)
    }

    /// What the person is doing. For a question or a draft, just where they are: the screen
    /// around it can discover candidates but must not decide for them. When only looking,
    /// the window itself is the record.
    static func record(_ context: ContextSnapshot, kind: Kind, conversation: Bool = false) -> String {
        var place = context.appName.isEmpty ? "The person's Mac" : "The person is in \(context.appName)"
        let title = QueryBuilder.cleanTitle(context.windowTitle, app: context.appName)
        if !title.isEmpty { place += ", in “\(clip(title, 200))”" }
        if !context.recipients.isEmpty { place += ", writing to \(clip(context.recipients.joined(separator: ", "), 200))" }
        if kind == .meeting {
            // A meeting's snapshot carries its title, attendees, place and notes.
            let details = clip(QueryBuilder.clean(context.visibleText), 2_000)
            var meeting = "The person has a meeting soon: “\(clip(title, 200))”"
            if !context.recipients.isEmpty { meeting += " with \(clip(context.recipients.joined(separator: ", "), 200))" }
            return meeting + ". Appears found these items in their own files, notes and messages."
                + (details.isEmpty ? "" : "\nEvent details:\n" + details)
        }
        var found = "\(place). Appears found these items in their own files, notes and messages."
        if conversation { found += " Messages marked “in the open conversation” are from the conversation they are in now." }
        guard kind == .looking else { return found }
        let visible = clip(QueryBuilder.clean(context.visibleText), 2_000)
        return visible.isEmpty ? found : found + "\nOn screen:\n" + visible
    }

    /// "Messages · Rowan Ellis · March 2026: the passage". The quoted text is `text` when the
    /// caller has a fuller view of the item (a picture's recognized text, the paragraph around
    /// a short passage), else the verified passage, else the matched unit's text. A message from
    /// the conversation the person has open says so: only the app knows which one that is.
    static func describe(_ candidate: Suggestion, openConversations: Set<Int64> = [], text: String? = nil) -> String {
        let item = candidate.item
        var source: String
        switch item.source {
        case .messages: source = item.kind == .image ? "Photo in Messages" : "Messages"
        case .notes: source = "Note"
        case .file: source = item.kind.label
        }
        if let chat = item.message?.chatID, openConversations.contains(chat) { source += ", in the open conversation" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM yyyy"
        let text = text ?? candidate.evidence?.text ?? (candidate.unit.text.isEmpty ? candidate.snippet : candidate.unit.text)
        let flat = text.replacingOccurrences(of: "\\s*\\n\\s*", with: " / ", options: .regularExpression)
        let body = flat.isEmpty ? (item.kind == .image ? "a picture with no readable text" : "no text") : clip(flat, 500)
        return "\(source) · \(clip(item.title, 120)) · \(formatter.string(from: item.modified)): \(body)"
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
