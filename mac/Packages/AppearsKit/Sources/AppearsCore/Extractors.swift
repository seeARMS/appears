import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// What an item's content turns into before embedding: text chunks to embed as documents,
/// and images to embed as images. Each carries the text that goes in the full-text index.
public struct Extraction: Sendable {
    public var texts: [(locator: Locator, text: String)] = []
    public var images: [(locator: Locator, image: CGImage, text: String)] = []

    public init() {}

    public var isEmpty: Bool { texts.isEmpty && images.isEmpty }
}

public enum Extractor {
    /// About 400 tokens.
    public static let chunkCharacters = 1_600
    /// Long documents are indexed from the start (about 5,000 tokens): enough to recognize
    /// them by. Every chunk is a pass through the model, so this bounds the cost of a file.
    public static let maxChunks = 12
    static let maxPages = 24
    static let chunksPerPage = 2

    /// Reads a file's content. Returns nil if it can't be read.
    public static func extract(_ item: Item) async -> Extraction? {
        let url = URL(filePath: item.path)
        if item.metadataOnly {
            var extraction = Extraction()
            extraction.texts = [(.whole, metadataText(item))]
            return extraction
        }
        switch item.kind {
        case .document:
            guard let text = readText(url) else { return nil }
            var extraction = Extraction()
            // Numbers and punctuation (CSV, logs, exported data): index by name only.
            if looksLikeData(text) {
                extraction.texts = [(.whole, metadataText(item))]
                return extraction
            }
            extraction.texts = chunks(text).enumerated().map { (.chunk($0.offset), $0.element) }
            if extraction.texts.isEmpty { extraction.texts = [(.whole, metadataText(item))] }
            return extraction
        case .pdf:
            return await extractPDF(url, item: item)
        case .image:
            guard let image = loadImage(url), isWorthIndexing(image) else { return nil }
            let text = await recognizeText(in: image)
            var extraction = Extraction()
            extraction.images = [(.whole, image, text)]
            // Screenshots of text are found best by their words.
            if text.count >= 80 { extraction.texts = [(.whole, String(text.prefix(chunkCharacters * 2)))] }
            return extraction
        case .note, .message:
            return nil
        }
    }

    /// A note's text as an extraction.
    public static func extract(noteText: String, title: String) -> Extraction {
        var extraction = Extraction()
        extraction.texts = chunks(noteText).enumerated().map { (.chunk($0.offset), $0.element) }
        if extraction.texts.isEmpty { extraction.texts = [(.whole, title)] }
        return extraction
    }

    /// Whether text is mostly not words: fewer than half its visible characters are letters.
    static func looksLikeData(_ text: String) -> Bool {
        var letters = 0, visible = 0
        for character in text.prefix(4_000) where !character.isWhitespace {
            visible += 1
            if character.isLetter { letters += 1 }
        }
        return visible > 200 && Double(letters) / Double(visible) < 0.5
    }

    static func metadataText(_ item: Item) -> String {
        let folder = (item.folder as NSString).lastPathComponent
        return "\(item.title) in \(folder)"
    }

    // MARK: - Text

    static func readText(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "txt", "md", "markdown":
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
            var encoding = String.Encoding.utf8
            return try? String(contentsOf: url, usedEncoding: &encoding)
        case "html", "htm":
            guard let data = try? Data(contentsOf: url) else { return nil }
            return stripHTML(String(decoding: data, as: UTF8.self))
        case "rtf":
            return try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
        case "docx":
            return try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
        case "doc":
            return try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.docFormat], documentAttributes: nil).string
        case "odt":
            return try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.openDocument], documentAttributes: nil).string
        default:
            return nil
        }
    }

    /// Text without tags, scripts or styles. (NSAttributedString's HTML reader needs the main
    /// thread and WebKit; this doesn't.)
    static func stripHTML(_ html: String) -> String {
        var text = html
        for pattern in ["(?is)<script.*?</script>", "(?is)<style.*?</style>", "(?s)<!--.*?-->", "<[^>]+>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        for (entity, character) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }

    /// Splits text at paragraph (then sentence) boundaries into chunks of about
    /// `chunkCharacters`, dropping empty ones.
    public static func chunks(_ text: String, size: Int = chunkCharacters, limit: Int = maxChunks) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        var chunks: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 3 { chunks.append(trimmed) }
            current = ""
        }
        for paragraph in normalized.components(separatedBy: "\n\n") {
            if chunks.count >= limit { break }
            if current.count + paragraph.count + 2 <= size {
                current += (current.isEmpty ? "" : "\n\n") + paragraph
                continue
            }
            flush()
            if paragraph.count <= size {
                current = paragraph
            } else {
                // One long paragraph: cut at sentence ends, or hard at the size.
                var rest = Substring(paragraph)
                while !rest.isEmpty, chunks.count < limit {
                    var cut = rest.index(rest.startIndex, offsetBy: min(size, rest.count))
                    if cut < rest.endIndex, let period = rest[..<cut].lastIndex(where: { ".!?\n".contains($0) }),
                       rest.distance(from: rest.startIndex, to: period) > size / 2 {
                        cut = rest.index(after: period)
                    }
                    current = String(rest[..<cut])
                    flush()
                    rest = rest[cut...]
                }
            }
        }
        if chunks.count < limit { flush() }
        return Array(chunks.prefix(limit))
    }

    // MARK: - PDF

    static func extractPDF(_ url: URL, item: Item) async -> Extraction? {
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        var extraction = Extraction()
        for index in 0..<min(document.pageCount, maxPages) {
            guard let page = document.page(at: index) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let number = index + 1
            if text.count >= 200 {
                for chunk in chunks(text, limit: chunksPerPage) { extraction.texts.append((.page(number), chunk)) }
            } else if let image = render(page) {
                // A scan, or a page that's mostly a picture.
                let ocr = await recognizeText(in: image)
                extraction.images.append((.page(number), image, ocr.isEmpty ? text : ocr))
                if ocr.count >= 80 { extraction.texts.append((.page(number), ocr)) }
            }
        }
        if extraction.isEmpty { extraction.texts = [(.whole, metadataText(item))] }
        return extraction
    }

    static func render(_ page: PDFPage, maxPixels: CGFloat = 1024) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = maxPixels / max(bounds.width, bounds.height)
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - Images

    /// Decodes an image scaled so its longest side is at most `maxPixels`, EXIF orientation applied.
    public static func loadImage(_ url: URL, maxPixels: Int = 1024) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Icons, emoji and UI assets aren't worth indexing.
    static func isWorthIndexing(_ image: CGImage) -> Bool {
        max(image.width, image.height) >= 240 && min(image.width, image.height) >= 120
    }

    /// The text in an image, one line per recognized line, with Vision's on-device OCR.
    public static func recognizeText(in image: CGImage) async -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: image) else { return "" }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
