import Foundation

/// Links that open a conversation in Messages.
///
/// Apple doesn't document a link that opens Messages at a specific message, so these open
/// the conversation and Appears shows the matching passage in its result. One-to-one
/// chats open with `imessage:` or `sms:` and the other person's address. Group chats have
/// no documented link, so for those this returns nil and the caller just opens Messages.
public enum MessagesLink {
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
