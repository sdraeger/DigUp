import Foundation

/// A question asked of your files ("when does my lease end?"): Apple's on-device model answers it from the passages of
/// the search's best results and cites them as [1], [2]. Here: what makes a query a question, what the model is told,
/// and the citations read back (the app asks the model: `Answering`).
public enum Question {
    /// A query that asks: it ends with "?".
    public static func isQuestion(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
    }

    /// A passage to answer from: "lease.pdf, page 3" and its text.
    public struct Source: Sendable, Equatable {
        public let title: String
        public let text: String

        public init(title: String, text: String) {
            self.title = title
            self.text = text
        }
    }

    public static let instructions = """
        You answer questions about the user's own files. Answer only from the numbered sources that come with the \
        question, in one to three sentences, in the question's language. Cite the source of each fact as [1], [2]. \
        If the sources don't answer the question, say only: I couldn't find that in your files.
        """

    /// Sources a question gets, and the most text each gives: the on-device model reads about 4,000 tokens, the
    /// question and its answer included.
    public static let maxSources = 4
    static let passageLimit = 1_500

    public static func prompt(_ question: String, sources: [Source]) -> String {
        "Question: \(question)\n\nSources:\n\n" + sources.enumerated().map { index, source in
            "[\(index + 1)] \(source.title): \(source.text)"
        }.joined(separator: "\n\n")
    }

    /// `text` with its spaces collapsed, cut to `passageLimit` around the first of `terms` it has: the part of a long
    /// page that matters.
    public static func passage(_ text: String, terms: [String]) -> String {
        let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.count > passageLimit else { return text }
        let found = terms.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
            .min { $0.lowerBound < $1.lowerBound }
        let at = found.map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
        let start = text.index(text.startIndex, offsetBy: max(0, min(at - passageLimit / 3, text.count - passageLimit)))
        let end = text.index(start, offsetBy: passageLimit)
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }

    /// The sources `answer` cites (0-based, of `count`), in the order it first cites them.
    public static func citations(in answer: String, count: Int) -> [Int] {
        var cited: [Int] = []
        for match in answer.matches(of: /\[(\d+)\]/) {
            guard let number = Int(match.output.1), (1...count).contains(number), !cited.contains(number - 1)
            else { continue }
            cited.append(number - 1)
        }
        return cited
    }
}
