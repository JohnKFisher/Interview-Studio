import Foundation

public enum TitleCaseFormatter {
    private static let smallWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "en", "for", "if", "in",
        "of", "on", "or", "per", "the", "to", "v", "via", "vs"
    ]

    public static func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let whitespaceSeparated = trimmed.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let words = whitespaceSeparated.enumerated().filter { !$0.element.isEmpty }
        let lastWordIndex = words.last?.offset

        return whitespaceSeparated.enumerated().map { index, token in
            guard !token.isEmpty else { return token }
            return transformToken(token, isFirstWord: index == words.first?.offset, isLastWord: index == lastWordIndex)
        }.joined(separator: " ")
    }

    private static func transformToken(_ token: String, isFirstWord: Bool, isLastWord: Bool) -> String {
        let coreRange = token.rangeOfCharacter(from: .alphanumerics).flatMap { first in
            token.rangeOfCharacter(from: .alphanumerics, options: .backwards).map { last in
                first.lowerBound ..< token.index(after: last.lowerBound)
            }
        }

        guard let coreRange else { return token }

        let prefix = String(token[..<coreRange.lowerBound])
        let core = String(token[coreRange])
        let suffix = String(token[coreRange.upperBound...])
        let transformedCore = transformCore(core, isFirstWord: isFirstWord, isLastWord: isLastWord)
        return prefix + transformedCore + suffix
    }

    private static func transformCore(_ core: String, isFirstWord: Bool, isLastWord: Bool) -> String {
        if core.contains("-") {
            return core.split(separator: "-", omittingEmptySubsequences: false).enumerated().map { index, part in
                transformSimpleWord(String(part), isFirstWord: isFirstWord && index == 0, isLastWord: isLastWord && index == core.split(separator: "-", omittingEmptySubsequences: false).count - 1, forceCapitalize: true)
            }.joined(separator: "-")
        }
        return transformSimpleWord(core, isFirstWord: isFirstWord, isLastWord: isLastWord, forceCapitalize: false)
    }

    private static func transformSimpleWord(
        _ word: String,
        isFirstWord: Bool,
        isLastWord: Bool,
        forceCapitalize: Bool
    ) -> String {
        guard !word.isEmpty else { return word }
        if shouldPreserveOriginal(word) {
            return word
        }

        let lowered = word.lowercased()
        if !forceCapitalize, !isFirstWord, !isLastWord, smallWords.contains(lowered) {
            return lowered
        }

        let first = lowered.prefix(1).uppercased()
        let rest = lowered.dropFirst()
        return first + rest
    }

    private static func shouldPreserveOriginal(_ word: String) -> Bool {
        if word == word.uppercased(), word.rangeOfCharacter(from: .letters) != nil {
            return true
        }

        let scalars = Array(word.unicodeScalars)
        for index in scalars.indices.dropFirst() {
            if CharacterSet.uppercaseLetters.contains(scalars[index]) {
                return true
            }
        }
        return false
    }
}
