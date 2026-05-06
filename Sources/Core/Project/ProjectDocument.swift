import Foundation

public struct ProjectDocument: Codable, Hashable, Sendable {
    public var schemaVersion: String
    public var projectName: String
    public var personName: String
    public var manifestFilename: String
    public var openingTitle: String
    public var closingTitle: String
    public var questionOrder: [String]
    public var questionDisplayTexts: [String: String]
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
        self.renderSettings = renderSettings
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
