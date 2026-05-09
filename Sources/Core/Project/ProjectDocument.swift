import Foundation

public struct PlexMetadataInput: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var show: String
    public var season: String
    public var episode: String
    public var episodeTitle: String
    public var summary: String

    public init(
        isEnabled: Bool = true,
        show: String = "",
        season: String = "",
        episode: String = "",
        episodeTitle: String = "",
        summary: String = ""
    ) {
        self.isEnabled = isEnabled
        self.show = show
        self.season = season
        self.episode = episode
        self.episodeTitle = episodeTitle
        self.summary = summary
    }
}

public struct ProjectDocument: Codable, Hashable, Sendable {
    public var schemaVersion: String
    public var projectName: String
    public var personName: String
    public var manifestFilename: String
    public var openingTitle: String
    public var closingTitle: String
    public var questionOrder: [String]
    public var questionDisplayTexts: [String: String]
    public var titleCaseQuestions: Bool
    public var plexMetadata: PlexMetadataInput
    public var renderSettings: RenderSettings

    public init(
        schemaVersion: String = "1.0",
        projectName: String,
        personName: String,
        manifestFilename: String,
        openingTitle: String,
        closingTitle: String,
        questionOrder: [String],
        questionDisplayTexts: [String: String],
        titleCaseQuestions: Bool = true,
        plexMetadata: PlexMetadataInput = .init(),
        renderSettings: RenderSettings
    ) {
        self.schemaVersion = schemaVersion
        self.projectName = projectName
        self.personName = personName
        self.manifestFilename = manifestFilename
        self.openingTitle = openingTitle
        self.closingTitle = closingTitle
        self.questionOrder = questionOrder
        self.questionDisplayTexts = questionDisplayTexts
        self.titleCaseQuestions = titleCaseQuestions
        self.plexMetadata = plexMetadata
        self.renderSettings = renderSettings
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projectName
        case personName
        case manifestFilename
        case openingTitle
        case closingTitle
        case questionOrder
        case questionDisplayTexts
        case titleCaseQuestions
        case plexMetadata
        case renderSettings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "1.0"
        projectName = try container.decode(String.self, forKey: .projectName)
        personName = try container.decode(String.self, forKey: .personName)
        manifestFilename = try container.decode(String.self, forKey: .manifestFilename)
        openingTitle = try container.decode(String.self, forKey: .openingTitle)
        closingTitle = try container.decode(String.self, forKey: .closingTitle)
        questionOrder = try container.decode([String].self, forKey: .questionOrder)
        questionDisplayTexts = try container.decode([String: String].self, forKey: .questionDisplayTexts)
        titleCaseQuestions = try container.decodeIfPresent(Bool.self, forKey: .titleCaseQuestions) ?? true
        plexMetadata = try container.decodeIfPresent(PlexMetadataInput.self, forKey: .plexMetadata) ?? .init()
        renderSettings = try container.decodeIfPresent(RenderSettings.self, forKey: .renderSettings) ?? .default
    }

    public static func sidecarURL(for manifestURL: URL) -> URL {
        manifestURL.deletingLastPathComponent().appendingPathComponent("yearly_interview_studio_project.json")
    }

    public static func makeDefault(for project: LoadedManifestProject) -> ProjectDocument {
        let highestAge = project.questions
            .flatMap(\.clips)
            .max(by: { ($0.row.ageSortKey ?? 0) < ($1.row.ageSortKey ?? 0) })?
            .row
        let highestAgeText = highestAge.map { ageRow -> String in
            if let value = ageRow.ageSortKey {
                let formatted = value == floor(value) ? String(Int(value)) : String(value)
                return "Age \(formatted)"
            }
            return ageRow.age
        } ?? ""

        let questionTexts = Dictionary(uniqueKeysWithValues: project.questions.map { ($0.questionKey, $0.displayText) })

        return ProjectDocument(
            projectName: project.projectName,
            personName: project.personName,
            manifestFilename: project.manifestURL.lastPathComponent,
            openingTitle: "\(project.personName) - Yearly Interview - \(highestAgeText)",
            closingTitle: "Happy Birthday, \(project.personName)!",
            questionOrder: project.questions.map(\.questionKey),
            questionDisplayTexts: questionTexts,
            titleCaseQuestions: true,
            plexMetadata: .init(),
            renderSettings: .default
        )
    }

    public func merged(with project: LoadedManifestProject) -> ProjectDocument {
        let validKeys = Set(project.questions.map(\.questionKey))
        let mergedTexts = questionDisplayTexts.filter { validKeys.contains($0.key) }.merging(
            Dictionary(uniqueKeysWithValues: project.questions.map { ($0.questionKey, $0.displayText) }),
            uniquingKeysWith: { existing, _ in existing }
        )

        let preservedOrder = questionOrder.filter(validKeys.contains)
        let missingOrder = project.questions.map(\.questionKey).filter { !preservedOrder.contains($0) }

        var copy = self
        copy.projectName = project.projectName
        copy.personName = project.personName
        copy.manifestFilename = project.manifestURL.lastPathComponent
        copy.questionDisplayTexts = mergedTexts
        copy.questionOrder = preservedOrder + missingOrder
        return copy
    }
}
