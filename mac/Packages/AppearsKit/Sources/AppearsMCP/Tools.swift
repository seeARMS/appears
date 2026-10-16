import AppearsCore
import Foundation

/// The tools `appears mcp` offers. Both only read the index; neither changes anything.
enum Tools {
    static let names = ["related", "related_to_file"]

    /// Advisory confidence label in MCP output; the panel shows confidence with an Orbit ring.
    static let likely = 0.15

    private static let limit: JSONValue = [
        "type": "integer", "minimum": 1, "maximum": 20, "default": 5,
        "description": "How many results, at most (1–20).",
    ]

    private static let preferForgotten: JSONValue = [
        "type": "boolean", "default": false,
        "description": "Rank as the menu bar does: favour what the user hasn't opened in months, and rank anything opened or changed in the last 3 days lower. Off by default, so recent files come back too.",
    ]

    private static let output: JSONValue = [
        "type": "object",
        "properties": [
            "results": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "A file path, notes:<id>, or messages:<id>."],
                        "url": ["type": "string", "description": "Opens the file, note or Messages conversation."],
                        "title": ["type": "string"],
                        "kind": ["type": "string", "enum": ["document", "pdf", "image", "note", "message"]],
                        "reason": ["type": "string", "description": "Why it matched, in one line."],
                        "snippet": ["type": "string", "description": "The matching text (OCR text for an image)."],
                        "lastOpened": ["type": ["string", "null"], "description": "When the user last opened it (from Spotlight, or Appears seeing it on screen), ISO 8601; null if unknown."],
                        "modified": ["type": "string", "description": "ISO 8601."],
                        "page": ["type": "integer", "description": "The matching page, for PDFs."],
                        "confidence": ["type": "number", "description": "0–1. Under 0.15 is a less likely match."],
                    ],
                    "required": ["path", "url", "title", "kind", "reason", "snippet", "lastOpened", "modified", "confidence"],
                ],
            ],
        ],
        "required": ["results"],
    ]

    private static let annotations: JSONValue = [
        "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false,
    ]

    static let list: [JSONValue] = [
        [
            "name": "related",
            "title": "Find what the user already has",
            "description": "Search the user's own files on this Mac (documents, PDFs, images and screenshots, Apple Notes, Messages and their local photos) for anything about some text: a question, a topic, people's names, or a passage you're working on. Matches by meaning and by names, numbers and rare words, so it finds a photo of a wifi card from \"what's the cabin wifi password\". Each result has its path, why it matched, the matching text and when it was last opened.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "What to look for, in a few words or a few paragraphs."],
                    "limit": limit,
                    "prefer_forgotten": preferForgotten,
                ],
                "required": ["text"],
                "additionalProperties": false,
            ],
            "outputSchema": output,
            "annotations": .object(annotations.object!.merging(["title": "Find what the user already has"]) { $1 }),
        ],
        [
            "name": "related_to_file",
            "title": "Find what relates to a file",
            "description": "Find the user's other indexed items that relate to one file Appears has indexed, using that file's own index entry. Give an absolute path, or ~/ for the home folder.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "The file's path."],
                    "limit": limit,
                    "prefer_forgotten": preferForgotten,
                ],
                "required": ["path"],
                "additionalProperties": false,
            ],
            "outputSchema": output,
            "annotations": .object(annotations.object!.merging(["title": "Find what relates to a file"]) { $1 }),
        ],
    ]

    /// A tool's answer: a short text for the model, the same results as structured content,
    /// and whether it failed in a way the model can act on.
    struct Answer {
        var text: String
        var structured: JSONValue?
        var isError = false

        var json: JSONValue {
            var result: [String: JSONValue] = ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
            if let structured { result["structuredContent"] = structured }
            return .object(result)
        }
    }

    static func call(_ name: String, arguments: [String: JSONValue], index: AgentIndex) async -> Answer {
        let limit = min(max(arguments["limit"]?.int ?? Int(arguments["limit"]?.string ?? "") ?? 5, 1), 20)
        let preferForgotten = arguments["prefer_forgotten"]?.bool ?? false
        do {
            switch name {
            case "related":
                guard let text = arguments["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    return Answer(text: "related needs `text`: what to look for, such as a question, a topic or names.", isError: true)
                }
                let found = try await index.related(text: String(text.prefix(20_000)), limit: limit, preferForgotten: preferForgotten)
                return answer(found, heading: "about this")
            default:
                guard let raw = arguments["path"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                    return Answer(text: "related_to_file needs `path`: the file's absolute path.", isError: true)
                }
                let (item, found) = try await index.related(toFile: path(raw), limit: limit, preferForgotten: preferForgotten)
                return answer(found, heading: "related to \(item.title)")
            }
        } catch let failure as AgentIndex.Failure {
            return Answer(text: failure.description, isError: true)
        } catch {
            return Answer(text: "Appears couldn't search its index: \(error.localizedDescription)", isError: true)
        }
    }

    /// An absolute path from what an agent sent: `~/…`, a file URL, or a path. Notes pass through.
    static func path(_ raw: String) -> String {
        if raw.hasPrefix("notes:") || raw.hasPrefix("messages:") { return raw }
        if let url = URL(string: raw), url.isFileURL { return url.standardizedFileURL.path }
        let expanded = raw.hasPrefix("~") ? FileScanner.realHome + raw.dropFirst() : raw
        return URL(filePath: expanded).standardizedFileURL.path
    }

    static func answer(_ suggestions: [Suggestion], heading: String) -> Answer {
        let results = suggestions.map(result)
        guard !suggestions.isEmpty else {
            return Answer(text: "Appears found nothing in the user's files \(heading). More words, or names and numbers, give it more to go on.", structured: ["results": []])
        }
        var lines = ["\(suggestions.count) of the user's own indexed items \(heading), best first:"]
        for (number, suggestion) in suggestions.enumerated() {
            let item = suggestion.item
            lines.append("")
            lines.append("\(number + 1). \(item.title) (\(item.kind.label.lowercased())\(suggestion.confidence < likely ? ", less likely" : ""))")
            lines.append("   \(item.path)")
            lines.append("   \(suggestion.reason)")
            if !suggestion.snippet.isEmpty { lines.append("   “\(suggestion.snippet)”") }
        }
        return Answer(text: lines.joined(separator: "\n"), structured: ["results": .array(results)])
    }

    static func result(_ suggestion: Suggestion) -> JSONValue {
        let item = suggestion.item
        let dates = ISO8601DateFormatter()
        var result: [String: JSONValue] = [
            "path": .string(item.path),
            "url": .string(item.openURL?.absoluteString ?? item.path),
            "title": .string(item.title),
            "kind": .string(item.kind.rawValue),
            "reason": .string(suggestion.reason),
            "snippet": .string(suggestion.snippet),
            "lastOpened": item.lastUsed.map { .string(dates.string(from: $0)) } ?? .null,
            "modified": .string(dates.string(from: item.modified)),
            "confidence": .double((suggestion.confidence * 100).rounded() / 100),
        ]
        if item.kind == .pdf, let page = suggestion.unit.locator.page { result["page"] = .int(page) }
        return .object(result)
    }
}
