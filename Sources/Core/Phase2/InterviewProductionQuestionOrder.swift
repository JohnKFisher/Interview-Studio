import Foundation

/// The current production sequence for the standard yearly interview.
///
/// Matching is intentionally based on normalized display text so that legacy
/// manifests may vary in capitalization, punctuation, or apostrophe style
/// without changing the stable question keys.
public enum InterviewProductionQuestionOrder {
    public static let displayTexts: [String] = [
        "What's Your Name",
        "How old are you?",
        "What's your favorite color?",
        "What's your favorite food?",
        "What's your favorite book?",
        "What's your favorite movie?",
        "What's your favorite tv show?",
        "What's your favorite song?",
        "What's your favorite animal?",
        "What's your favorite game?",
        "What do you like to play with?",
        "Who do you like to play with?",
        "Who is your best friend?",
        "Where do you like to go",
        "What are you good at?",
        "What do you want to be when you grow up?",
        "What makes you happy?",
        "What makes you sad?",
        "Do you like school?",
        "Favorite part of school?",
        "What do you want to tell me?"
    ]

    private static let rankByQuestionKey: [String: Int] = [
        "what-is-your-name": 0,
        "whats-your-favorite-part-of-school": 19,
        "is-there-anything-you-want-to-tell-me": 20
    ]

    private static let rankByNormalizedText: [String: Int] = Dictionary(
        uniqueKeysWithValues: displayTexts.enumerated().map { index, text in
            (normalize(text), index)
        }
        + [
            // These are established labels in existing packages. Keep their
            // display text stable while assigning them the production rank.
            (normalize("What is Your Name?"), 0),
            (normalize("What's your favorite part of school?"), 19),
            (normalize("Is there anything you want to tell me?"), 20)
        ]
    )

    public static func rank(for question: InterviewQuestion) -> Int? {
        rankByQuestionKey[normalizeKey(question.questionKey)]
            ?? rankByNormalizedText[normalize(question.displayText)]
    }

    public static func ordered(_ questions: [InterviewQuestion]) -> [InterviewQuestion] {
        var active = questions.filter(\.isActive)
        var inactive = questions.filter { !$0.isActive }

        active = active.enumerated().sorted { left, right in
            let leftRank = rank(for: left.element) ?? Int.max
            let rightRank = rank(for: right.element) ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            if left.element.order != right.element.order {
                return left.element.order < right.element.order
            }
            return left.offset < right.offset
        }.map(\.element)

        for index in active.indices {
            active[index].order = index
        }
        for index in inactive.indices {
            inactive[index].order = active.count + index
        }
        return active + inactive
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "’", with: "'")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func normalizeKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
