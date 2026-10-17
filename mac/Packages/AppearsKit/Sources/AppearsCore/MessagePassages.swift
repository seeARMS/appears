import AppearsMessages
import Foundation

/// A discussion assembled from original messages, in memory, after retrieving a small
/// passage. No generated summaries, persistent context or new embedding model is needed.
struct MessagePassage {
    var text: String
    var messageIDs: Set<Int64>

    static func overlaps(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let left = Set(a.split(separator: "\n").map(String.init).filter { $0.count >= 18 })
        let right = Set(b.split(separator: "\n").map(String.init).filter { $0.count >= 18 })
        let common = left.intersection(right).count
        return common >= 2 && Double(common) / Double(max(1, min(left.count, right.count))) >= 0.65
    }

    /// Speaker addresses identify the conversation, not its subject. In legacy indexed
    /// windows they must not connect every nearby message through the same phone number.
    static func indexedIdentifiers(_ text: String) -> Set<String> {
        let body = text.split(separator: "\n").map { line -> String in
            guard let colon = line.firstIndex(of: ":") else { return String(line) }
            let speaker = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let phone = speaker.filter(\.isNumber).count >= 7
                && speaker.allSatisfy { $0.isNumber || "+()-. ".contains($0) }
            if speaker == "Me" || speaker == "Sender" || phone || speaker.contains("@") {
                return String(line[line.index(after: colon)...])
            }
            return String(line)
        }.joined(separator: "\n")
        return Set(SearchQuery.tokens(body).filter(isIdentifier))
    }

    static func discussion(anchor: Message, messages: [Message], handles: [Int64: Handle]) -> Self {
        let eligible = messages.filter {
            $0.chatID == anchor.chatID && $0.isSearchable && $0.text != nil
                && (abs($0.date.timeIntervalSince(anchor.date)) <= 3 * 86_400 || anchor.replyToGUID == $0.guid)
        }
        let anchorWords = topicWords(anchor.text ?? "")
        var selected = eligible.filter { message in
            let distance = abs(message.date.timeIntervalSince(anchor.date))
            let shared = anchorWords.intersection(topicWords(message.text ?? ""))
            let reply = message.replyToGUID == anchor.guid || anchor.replyToGUID == message.guid
                || (anchor.replyToGUID != nil && anchor.replyToGUID == message.replyToGUID)
            return message.rowID == anchor.rowID || distance <= 5 * 60 || reply
                || (distance <= 6 * 3_600 && shared.count >= 2) || shared.contains(where: isIdentifier)
        }
        // Short acknowledgements inherit the subject of a nearby substantive message.
        let contextWords = selected.reduce(into: anchorWords) { $0.formUnion(topicWords($1.text ?? "")) }
        for message in eligible where !selected.contains(where: { $0.rowID == message.rowID }) {
            let shared = contextWords.intersection(topicWords(message.text ?? ""))
            if (abs(message.date.timeIntervalSince(anchor.date)) <= 6 * 3_600 && shared.count >= 2)
                || shared.contains(where: isIdentifier) { selected.append(message) }
        }
        selected.sort {
            if $0.rowID == $1.rowID { return false }
            if $0.rowID == anchor.rowID { return true }
            if $1.rowID == anchor.rowID { return false }
            return abs($0.date.timeIntervalSince(anchor.date)) < abs($1.date.timeIntervalSince(anchor.date))
        }
        var retained: [Message] = []
        var characters = 0
        for message in selected {
            let length = min(message.text?.count ?? 0, 1_600) + 80
            if retained.isEmpty || characters + length <= 6_000 {
                retained.append(message)
                characters += length
            }
        }
        retained.sort { $0.date == $1.date ? $0.rowID < $1.rowID : $0.date < $1.date }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let text: String = retained.map { message -> String in
            let speaker = message.isFromMe ? "Me" : handles[message.handleID]?.address ?? "Sender"
            return "[\(formatter.string(from: message.date))] \(speaker): \(String((message.text ?? "").prefix(1_600)))"
        }.joined(separator: "\n")
        return Self(text: text, messageIDs: Set(retained.map(\.rowID)))
    }

    private static func topicWords(_ text: String) -> Set<String> {
        Set(SearchQuery.tokens(text).filter { ($0.count >= 4 || isIdentifier($0)) && !SearchQuery.filler.contains($0) })
            .subtracting(["that", "this", "there", "here", "just", "will", "would", "yeah", "okay", "sure", "thanks", "think", "about", "really", "some", "from", "then", "also", "good", "great", "looks", "look", "sounds", "sound", "thing", "things", "like", "know", "want", "need"])
    }

    private static func isIdentifier(_ word: String) -> Bool { word.count >= 3 && word.contains(where: \.isNumber) }
}

extension MessagesReader {
    /// One bounded read transaction for all candidate anchors. Validate identities against
    /// the source so deletions, unsends and ROWID reuse cannot restore stale source text.
    func searchPassages(for items: [Item], excluding rowIDs: Set<Int64> = [], excludes: [String] = []) throws -> [Int64: MessagePassage] {
        let contexts = try database.messagesWithThreads(rowIDs: items.compactMap { $0.message?.rowID }, before: 24, after: 24, includeReplies: true)
        let handles = try database.handles()
        var result: [Int64: MessagePassage] = [:]
        for item in items {
            guard let reference = item.message, let context = contexts[reference.rowID],
                  context.message.guid == reference.guid, context.message.chatID == reference.chatID,
                  context.message.isSearchable, context.message.text != nil else { continue }
            result[item.id] = .discussion(anchor: context.message,
                messages: context.thread.filter { message in
                    !rowIDs.contains(message.rowID) && !excludes.contains(where: { path in
                        let key = Self.path(message.rowID)
                        return key == path || key.hasPrefix(path.hasSuffix("/") ? path : path + "/")
                    })
                }, handles: handles)
        }
        return result
    }
}
