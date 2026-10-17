import Foundation

/// Links that open a message or conversation in Messages.
public enum MessagesLink {
    /// The message-specific URL used by Apple's own links back from Calendar.
    /// This is undocumented; retain conversation links as a fallback for missing GUIDs.
    public static func url(messageGUID: String) -> URL? {
        guard !messageGUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "sms"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "message-guid", value: messageGUID)]
        return components.url
    }

    /// One-to-one conversation fallback. Groups without a message GUID open Messages itself.
    public static func url(for chat: Chat) -> URL? {
        guard !chat.isGroup, let address = chat.participants.first?.address ?? nonEmpty(chat.identifier) else {
            return nil
        }
        let scheme = chat.service == "iMessage" ? "imessage" : "sms"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "+@.-_")
        guard let encoded = address.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(scheme)://\(encoded)")
    }

    private static func nonEmpty(_ string: String) -> String? {
        string.isEmpty || string.hasPrefix("chat") ? nil : string
    }
}
