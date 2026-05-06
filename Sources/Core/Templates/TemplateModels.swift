import Foundation

public struct CardSet: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var backgroundHex: String
    public var foregroundHex: String
    public var accentHex: String
    public var subtitleHex: String
    public var titleFontName: String
}

public struct OverlayStyle: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var alignment: String
    public var foregroundHex: String
    public var backgroundHex: String
    public var questionForegroundHex: String
}

public enum BuiltInTemplates {
    public static let cardSets: [CardSet] = [
        .init(id: "documentary-paper", name: "Documentary Paper", backgroundHex: "#F5F0E6", foregroundHex: "#1F1A17", accentHex: "#8D6E63", subtitleHex: "#6D5C54", titleFontName: "NewYork"),
        .init(id: "midnight-archive", name: "Midnight Archive", backgroundHex: "#0E1824", foregroundHex: "#F8F0D8", accentHex: "#D6A85F", subtitleHex: "#D8C7A4", titleFontName: "Georgia"),
        .init(id: "autumn-film", name: "Autumn Film", backgroundHex: "#23170F", foregroundHex: "#F8ECDD", accentHex: "#C9783A", subtitleHex: "#D3B89C", titleFontName: "Palatino"),
        .init(id: "soft-linen", name: "Soft Linen", backgroundHex: "#EAE3D4", foregroundHex: "#2E2823", accentHex: "#A57558", subtitleHex: "#5F5147", titleFontName: "Times New Roman"),
        .init(id: "sunlit-home", name: "Sunlit Home", backgroundHex: "#F7F4EF", foregroundHex: "#312A24", accentHex: "#B97A56", subtitleHex: "#6E6157", titleFontName: "Avenir Next")
    ]

    public static let overlayStyles: [OverlayStyle] = [
        .init(id: "age-lower-third-soft", name: "Soft Lower Third", alignment: "bottomTrailing", foregroundHex: "#F8F4ED", backgroundHex: "#4D3B31CC", questionForegroundHex: "#F5E7D2"),
        .init(id: "age-bottom-band", name: "Bottom Band", alignment: "bottomLeading", foregroundHex: "#FAF5EF", backgroundHex: "#2A2520CC", questionForegroundHex: "#F1DDC2"),
        .init(id: "age-top-chip", name: "Top Chip", alignment: "topLeading", foregroundHex: "#FFF7EF", backgroundHex: "#433129CC", questionForegroundHex: "#F6E1C5"),
        .init(id: "age-corner-glass", name: "Corner Glass", alignment: "topTrailing", foregroundHex: "#FFF7EF", backgroundHex: "#2A201AC9", questionForegroundHex: "#F3E2CC"),
        .init(id: "age-minimal-ribbon", name: "Minimal Ribbon", alignment: "bottomTrailing", foregroundHex: "#FFFFFF", backgroundHex: "#725B4ECC", questionForegroundHex: "#F2E0C8")
    ]

    public static func cardSet(id: String) -> CardSet {
        cardSets.first(where: { $0.id == id }) ?? cardSets[0]
    }

    public static func overlayStyle(id: String) -> OverlayStyle {
        overlayStyles.first(where: { $0.id == id }) ?? overlayStyles[0]
    }
}
