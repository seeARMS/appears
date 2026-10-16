import Foundation
import Testing
@testable import AppearsCore

@Suite struct SuggestionEvidenceTests {
    private func suggestion(_ text: String, image: Bool = false, reason: String = "Related · from April 2025 · page 3", snippet: String? = nil,
                            line: MatchedLine? = nil) -> Suggestion {
        let date = Date(timeIntervalSince1970: 0)
        return Suggestion(
            item: Item(source: .file, path: "/demo/kitchen", kind: image ? .image : .document, title: "Kitchen", size: 1,
                       created: date, modified: date, lastUsed: nil),
            unit: Unit(kind: image ? .image : .text, locator: .page(3), text: text), reason: reason, snippet: snippet ?? text,
            score: 1, confidence: 0.02,
            features: Features(cosine: 0.6, zScore: 1, agreement: false, entityHit: false, daysSinceTouched: 500, fused: 0.01, forgotten: 1, novelty: 1),
            line: line
        )
    }

    @Test func quotesTheRelevantSentenceEvenWhenTheSnippetStartsElsewhere() {
        let result = SuggestionEvidence(suggestion("Back wall measurements are on the drawing. Dana said the outlet by the window has to move for code.",
                                                  snippet: "Back wall measurements are on the drawing."), terms: ["outlet", "window"])
        #expect(result.isQuotation)
        #expect(result.segments.map(\.text).joined() == "Dana said the outlet by the window has to move for code.")
        #expect(result.segments.filter(\.emphasized).map(\.text) == ["outlet", "window"])
        #expect(result.metadata == "from April 2025 · page 3")
    }

    @Test func meaningOnlyMatchesStillShowTheRetrievedPassage() {
        let text = "Replace cabinets and countertops, relocate sink three feet."
        let result = SuggestionEvidence(suggestion(text), terms: ["renovation"])
        #expect(result.isQuotation)
        #expect(result.segments.map(\.text).joined() == text)
        #expect(result.segments.allSatisfy { !$0.emphasized })
    }

    @Test func keepsASpecificNameWhenThereIsNoReadablePassage() {
        let result = SuggestionEvidence(suggestion("", image: true, reason: "Mentions Dana Ruiz · from April 2025"))
        #expect(!result.isQuotation)
        #expect(result.segments.map(\.text).joined() == "Mentions Dana Ruiz")
        #expect(result.segments.filter(\.emphasized).map(\.text) == ["Dana Ruiz"])
    }

    @Test func imagesNeedCleanTextAndAnActualOverlap() {
        let text = "Electrical, 6 new outlets $1,650"
        let match = SuggestionEvidence(suggestion(text, image: true), terms: ["outlets"])
        #expect(match.isQuotation)
        #expect(match.segments.filter(\.emphasized).map(\.text) == ["outlets"])
        #expect(SuggestionEvidence(suggestion(text, image: true), terms: ["plumbing"]).segments.isEmpty)
        #expect(SuggestionEvidence(suggestion("01 020 300 450 678 900 outlets", image: true), terms: ["outlets"]).segments.isEmpty)
        #expect(SuggestionEvidence(suggestion("", image: true)).segments.isEmpty)
    }

    @Test func emphasizesWholeWordsAndOriginalCasing() {
        let result = SuggestionEvidence(suggestion("Dana Ruiz permitted the electrical changes."), terms: ["dana ruiz", "permit"])
        #expect(result.segments.filter(\.emphasized).map(\.text) == ["Dana Ruiz"])
    }

    @Test func longExcerptsKeepTheMatchAndWholeWords() {
        let text = String(repeating: "Measurements are recorded here and ", count: 12) + "the kitchen outlet needs to move for code " + String(repeating: "before the work starts ", count: 12)
        let result = SuggestionEvidence(suggestion(text), terms: ["outlet"])
        let excerpt = result.segments.map(\.text).joined()
        #expect(excerpt.count <= 122)
        #expect(excerpt.hasPrefix("…"))
        #expect(result.segments.filter(\.emphasized).map(\.text) == ["outlet"])
        #expect(text.contains(String(excerpt.dropFirst().dropLast())))
    }

    @Test func answerLinesKeepTheirExistingPresentationAndConcealedCopyBehavior() {
        let line = MatchedLine(segments: [.init("Password: "), .init("trout-meadow-88", emphasized: true)], concealed: true)
        let item = suggestion("Password: trout-meadow-88", image: true, line: line)
        #expect(SuggestionEvidence(item, terms: ["password"]).segments.isEmpty)
        #expect(item.line?.concealed == true)
    }
}
