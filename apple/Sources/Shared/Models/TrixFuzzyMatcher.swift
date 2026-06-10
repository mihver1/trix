import Foundation

/// Pure fuzzy matcher used by the macOS quick switcher to rank chats by name.
///
/// Matching is case- and diacritic-insensitive. Scores fall into
/// non-overlapping tiers so ordering rules stay predictable (`nil` = no match):
///
/// - exact match: 1000
/// - candidate prefix: 801...899 (longer candidates score slightly lower)
/// - prefix of a later word: 701...800 (earlier words score higher)
/// - every query token is a prefix of a distinct word: 601...700
/// - character subsequence: 1...600 (bonuses for word-boundary hits and
///   consecutive runs, penalties for gaps and late first match)
enum TrixFuzzyMatcher {
    static func score(query: String, candidate: String) -> Int? {
        let query = normalized(query)
        let candidate = normalized(candidate)
        guard !query.isEmpty, !candidate.isEmpty else {
            return nil
        }

        if candidate == query {
            return 1000
        }

        if candidate.hasPrefix(query) {
            return 900 - min(lengthPenalty(query: query, candidate: candidate), 99)
        }

        let words = words(in: candidate)
        if let wordIndex = words.firstIndex(where: { $0.hasPrefix(query) }) {
            let penalty = min(wordIndex * 10 + lengthPenalty(query: query, candidate: candidate), 99)
            return 800 - penalty
        }

        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.count > 1, matchesDistinctWordPrefixes(tokens: tokens, words: words) {
            return 700 - min(lengthPenalty(query: query, candidate: candidate), 99)
        }

        return subsequenceScore(query: query, candidate: candidate)
    }

    /// Returns `elements` that match `query`, best score first. Ties keep the
    /// input order, so callers can pass recency-sorted lists. An empty query
    /// returns the input unchanged.
    static func ranked<Element>(
        _ elements: [Element],
        query: String,
        names: (Element) -> [String]
    ) -> [Element] {
        guard !normalized(query).isEmpty else {
            return elements
        }

        return elements.enumerated()
            .compactMap { index, element -> (score: Int, index: Int, element: Element)? in
                guard let score = bestScore(query: query, candidates: names(element)) else {
                    return nil
                }

                return (score, index, element)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }

                return lhs.index < rhs.index
            }
            .map(\.element)
    }

    /// Best score across several aliases of the same item (for example a chat
    /// name and the underlying address handle).
    static func bestScore(query: String, candidates: [String]) -> Int? {
        candidates
            .compactMap { score(query: query, candidate: $0) }
            .max()
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
    }

    private static func words(in candidate: String) -> [String] {
        candidate
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func matchesDistinctWordPrefixes(tokens: [String], words: [String]) -> Bool {
        var usedWordIndices = Set<Int>()
        for token in tokens {
            guard let wordIndex = words.indices.first(where: { index in
                !usedWordIndices.contains(index) && words[index].hasPrefix(token)
            }) else {
                return false
            }

            usedWordIndices.insert(wordIndex)
        }

        return true
    }

    private static func subsequenceScore(query: String, candidate: String) -> Int? {
        let queryChars = Array(query.filter { !$0.isWhitespace })
        let candidateChars = Array(candidate)
        guard !queryChars.isEmpty else {
            return nil
        }

        var score = 400
        var queryIndex = 0
        var firstMatchIndex: Int?
        var previousMatchIndex: Int?

        for (index, character) in candidateChars.enumerated() where queryIndex < queryChars.count {
            guard character == queryChars[queryIndex] else {
                continue
            }

            if firstMatchIndex == nil {
                firstMatchIndex = index
            }

            if let previousMatchIndex {
                if index == previousMatchIndex + 1 {
                    score += 8
                } else {
                    score -= min(index - previousMatchIndex - 1, 10)
                }
            }

            var isWordBoundary = index == 0
            if !isWordBoundary {
                let previous = candidateChars[index - 1]
                isWordBoundary = !previous.isLetter && !previous.isNumber
            }
            if isWordBoundary {
                score += 12
            }

            previousMatchIndex = index
            queryIndex += 1
        }

        guard queryIndex == queryChars.count else {
            return nil
        }

        score -= min(firstMatchIndex ?? 0, 30)
        return min(max(score, 1), 600)
    }

    private static func lengthPenalty(query: String, candidate: String) -> Int {
        max(candidate.count - query.count, 0)
    }
}
